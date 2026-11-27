// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosNetworking
import Synchronization
import Testing

/// Settings shared by the user's devices through `/.nextcloud-photos/<kind>.json` (SPEC §22.5): the merge rules of the
/// document, and two devices syncing through an in-memory WebDAV server.
@Suite struct SyncedSettingsDocumentTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func laterChangeOfAKeyWinsAndOtherKeysAreKept() {
        var a = SyncedSettingsDocument(kind: "settings")
        var b = SyncedSettingsDocument(kind: "settings")
        a.set(.bool(true), for: "squareTiles", now: t0)
        b.set(.bool(false), for: "squareTiles", now: t0.addingTimeInterval(5))
        a.set(.string("stories"), for: "memoriesStyle", now: t0.addingTimeInterval(9))
        let ab = a.merged(with: b, now: t0)
        let ba = b.merged(with: a, now: t0)
        #expect(ab == ba)
        #expect(ab.value("squareTiles") == .bool(false))
        #expect(ab.value("memoriesStyle") == .string("stories"))
    }

    @Test func aRemovalReachesOtherDevicesAndExpiresAfterNinetyDays() {
        var a = SyncedSettingsDocument(kind: "family")
        a.set(.string("dismissed"), for: "decision/7", now: t0)
        var b = a
        b.set(nil, for: "decision/7", now: t0.addingTimeInterval(1))
        let merged = a.merged(with: b, now: t0)
        #expect(merged.value("decision/7") == nil)
        #expect(merged.entries["decision/7"]?.isDeleted == true)
        // The offline device does not bring it back.
        #expect(merged.merged(with: a, now: t0).value("decision/7") == nil)
        let later = merged.merged(with: SyncedSettingsDocument(kind: "family"), now: t0.addingTimeInterval(91 * 86_400))
        #expect(later.entries["decision/7"] == nil)
    }

    /// Two devices name the same person at the same time: the later name wins, the other is kept, never lost.
    @Test func aNameGivenAtTheSameTimeElsewhereIsKept() throws {
        var mac = SyncedSettingsDocument(kind: "people")
        var phone = SyncedSettingsDocument(kind: "people")
        mac.set(.string("Anna"), for: "person/c1", now: t0)
        phone.set(.string("Anne"), for: "person/c1", now: t0.addingTimeInterval(2))
        let merged = mac.merged(with: phone, now: t0)
        #expect(merged.value("person/c1") == .string("Anne"))
        #expect(merged.entries["person/c1"]?.replaced == [.string("Anna")])
        #expect(phone.merged(with: mac, now: t0) == merged)
        // Merging again changes nothing (idempotent), and a rename made over the merged version is no race.
        #expect(merged.merged(with: mac, now: t0) == merged)
        var renamed = merged
        renamed.set(.string("Anna Maria"), for: "person/c1", now: t0.addingTimeInterval(10))
        let after = renamed.merged(with: merged, now: t0)
        #expect(after.value("person/c1") == .string("Anna Maria"))
        #expect(after.entries["person/c1"]?.replaced?.contains(.string("Anna")) == true)
        #expect(after.entries["person/c1"]?.replaced?.contains(.string("Anne")) != true)
        // A tie in time: every device picks the same.
        var x = SyncedSettingsDocument(kind: "people")
        var y = SyncedSettingsDocument(kind: "people")
        x.set(.string("Ben"), for: "person/c2", now: t0)
        y.set(.string("Benjamin"), for: "person/c2", now: t0)
        #expect(x.merged(with: y, now: t0) == y.merged(with: x, now: t0))
    }

    @Test func aChangeIsStampedAfterWhatItChangesWhenTheClockIsBehind() {
        var document = SyncedSettingsDocument(kind: "settings")
        document.set(.number(3), for: "slideshowInterval", now: t0)
        document.set(.number(5), for: "slideshowInterval", now: t0.addingTimeInterval(-60))
        let entry = document.entries["slideshowInterval"]
        #expect(entry?.value == .number(5))
        #expect(entry.map { $0.modifiedAt > t0 } == true)
        #expect(entry?.base == t0)
        // Setting the same value again is no change.
        let changed = document.set(.number(5), for: "slideshowInterval", now: t0.addingTimeInterval(100))
        #expect(!changed)
    }

    @Test func fileRoundTripsWithMillisecondsAndSkipsBrokenEntries() throws {
        var document = SyncedSettingsDocument(kind: "settings")
        document.set(.object(["style": .string("calm")]), for: "films/trip-2024", now: t0.addingTimeInterval(0.123))
        document.set(nil, for: "gone", now: t0)
        document.set(.string("x"), for: "gone", now: t0)
        document.set(nil, for: "gone", now: t0.addingTimeInterval(1))
        let data = try document.encoded()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"format\" : \"nextcloud-photos-settings\""))
        #expect(text.contains(".123Z"))
        #expect(text.contains("\"deleted\" : true"))
        #expect(SyncedSettingsDocument.decoded(data) == document)
        let broken = Data(
            #"{"format":"nextcloud-photos-settings","version":1,"kind":"settings","entries":{"a":{"value":1,"modifiedAt":"2027-01-15T08:00:00.000Z"},"b":{"value":2},"c":{"value":true,"modifiedAt":"2027-01-15T08:00:00Z","future":1}}}"#
                .utf8)
        let decoded = try #require(SyncedSettingsDocument.decoded(broken))
        #expect(decoded.value("a") == .number(1))
        #expect(decoded.entries["b"] == nil)
        #expect(decoded.value("c") == .bool(true))
        #expect(SyncedSettingsDocument.decoded(Data(#"{"format":"other","entries":{}}"#.utf8)) == nil)
    }

    @Test func typedValues() {
        struct Choice: Codable, Equatable {
            var style: String
            var music: Bool
        }
        var document = SyncedSettingsDocument(kind: "settings")
        document.set(encoding: Choice(style: "calm", music: true), for: "films/x", now: t0)
        #expect(document.value("films/x", as: Choice.self) == Choice(style: "calm", music: true))
        #expect(document.value("films/x", as: Int.self) == nil)
        document.set(.string("y"), for: "other", now: t0)
        #expect(document.values(prefix: "films/").keys.sorted() == ["films/x"])
    }
}

@Suite struct SyncedSettingsStoreTests {
    let path = "/.nextcloud-photos/people.json"

    func store(_ server: EditDAVServer, file: URL? = nil) -> SyncedSettingsStore {
        SyncedSettingsStore(files: AppDataFiles(dav: server.dav), kind: .people, localFile: file, sendDelay: .milliseconds(1))
    }

    @Test func twoDevicesShareTheirChangesWithoutOverwritingEachOther() async throws {
        let server = EditDAVServer()
        let mac = store(server)
        let phone = store(server)
        await mac.set(.string("Anna"), for: "person/1")
        await phone.set(.string("Ben"), for: "person/2")
        await mac.waitUntilIdle()
        await phone.waitUntilIdle()
        // The phone wrote over the version the Mac wrote (If-Match), merged with it.
        let log = server.log.filter { $0.hasPrefix("PUT") }
        #expect(log.first?.contains("none:*") == true)
        #expect(log.contains { $0.contains("match:") })
        // Whichever wrote first, after one more sync each has both.
        await mac.sync()
        await phone.sync()
        #expect(mac.value("person/2") == .string("Ben"))
        #expect(phone.value("person/1") == .string("Anna"))
        let file = try #require(server.state.withLock { $0.files[path] })
        let onServer = try #require(SyncedSettingsDocument.decoded(file.data))
        #expect(onServer.values().count == 2)
        #expect(onServer.kind == "people")
    }

    @Test func anUnchangedFileCostsOneLookAndNothingIsWrittenForAnEmptyStore() async throws {
        let server = EditDAVServer()
        let empty = store(server)
        await empty.sync()
        #expect(server.state.withLock { $0.files[path] } == nil)
        #expect(!server.log.contains { $0.hasPrefix("PUT") })
        let device = store(server)
        await device.set(.string("Anna"), for: "person/1")
        await device.waitUntilIdle()
        let before = server.log.count
        await device.sync()
        #expect(server.log.count == before + 1)
        #expect(server.log.last?.hasPrefix("PROPFIND") == true)
    }

    @Test func offlineChangesWaitAndAreKeptOnTheDevice() async throws {
        let server = EditDAVServer()
        let file = FileManager.default.temporaryDirectory.appending(path: "synced-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        server.setOffline(true)
        let device = store(server, file: file)
        await device.set(.string("Anna"), for: "person/1")
        await device.waitUntilIdle()
        #expect(await device.hasPendingChanges())
        // The app is closed and opened again, still offline: the change is there and still waits.
        let reopened = store(server, file: file)
        #expect(reopened.value("person/1") == .string("Anna"))
        #expect(await reopened.hasPendingChanges())
        server.setOffline(false)
        await reopened.sync()
        #expect(!(await reopened.hasPendingChanges()))
        #expect(server.state.withLock { $0.files[path] } != nil)
    }

    @Test func observersHearRemoteChanges() async throws {
        let server = EditDAVServer()
        let mac = store(server)
        let phone = store(server)
        let heard = HeardKeys()
        await phone.observe { keys in heard.add(keys) }
        await mac.set(["person/1": .string("Anna"), "face/9": .string("1")])
        await mac.waitUntilIdle()
        await phone.sync()
        #expect(heard.keys == ["person/1", "face/9"])
    }

    @Test func registryListsTheFolderOnceForAllKinds() async throws {
        let server = EditDAVServer()
        let files = SyncedSettingsFiles(dav: server.dav, directory: nil)
        let people = files.store(.people)
        #expect(files.store(.people) === people)
        await people.set(.string("Anna"), for: "person/1")
        await people.waitUntilIdle()
        _ = files.store(.family)
        let before = server.log.count
        await files.syncAll()
        // One listing; the people file is unchanged and the family file does not exist and has nothing to send.
        #expect(server.log.count == before + 1)
        let other = SyncedSettingsFiles(dav: server.dav, directory: nil)
        _ = other.store(.people)
        await other.syncAll()
        #expect(other.store(.people).value("person/1") == .string("Anna"))
    }
}

final class HeardKeys: Sendable {
    private let stored = Mutex<Set<String>>([])
    func add(_ keys: Set<String>) { stored.withLock { $0.formUnion(keys) } }
    var keys: Set<String> { stored.withLock { $0 } }
}
