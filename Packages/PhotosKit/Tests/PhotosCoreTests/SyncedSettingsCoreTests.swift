// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosCore
@testable import PhotosModel
@testable import PhotosNetworking
@testable import PhotosStore

/// App settings and the family library shared by the user's devices (SPEC §22.5.1, §22.5.2). Two "devices" are two
/// `UserDefaults` suites with a store each; a sync is the stores taking over each other's documents.
@Suite(.timeLimit(.minutes(1))) @MainActor struct SyncedDefaultsTests {
    let server = StubServer()

    /// One device: its own settings, journal and copy of the account's `settings.json`.
    struct Device {
        let defaults: UserDefaults
        let bridge: SyncedDefaults
        let store: SyncedSettingsStore
    }

    func device(_ name: String = UUID().uuidString) -> Device {
        let suite = "synced-tests-\(name)-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let connection = ServerConnection(serverURL: server.url, userId: "alice", loginName: "alice", appPassword: "x", userAgent: "tests")
        let dav = DAVClient(http: server.http(), connection: connection)
        // Never sent within a test: the devices exchange their documents directly.
        let store = SyncedSettingsStore(files: AppDataFiles(dav: dav), kind: .settings, localFile: nil, sendDelay: .seconds(3600))
        return Device(defaults: defaults, bridge: SyncedDefaults(defaults: defaults, file: nil), store: store)
    }

    /// Both devices sync through the server: each sends its journal, the other takes over.
    func exchange(_ a: Device, _ b: Device, account: String = "alice") async {
        await a.bridge.prepare(a.store, account: account)
        await b.bridge.prepare(b.store, account: account)
        await b.store.merge(a.store.snapshot())
        await a.store.merge(b.store.snapshot())
        a.bridge.apply(a.store, account: account)
        b.bridge.apply(b.store, account: account)
    }

    @Test func aChangeOnOneDeviceReachesTheOther() async {
        let mac = device("mac")
        let phone = device("phone")
        await exchange(mac, phone)
        mac.defaults.set(false, forKey: "squareTiles")
        mac.defaults.set("strip", forKey: "memoriesStyle")
        mac.defaults.set(5, forKey: "slideshowInterval")
        await exchange(mac, phone)
        #expect(phone.defaults.object(forKey: "squareTiles") as? Bool == false)
        #expect(phone.defaults.string(forKey: "memoriesStyle") == "strip")
        #expect(phone.defaults.integer(forKey: "slideshowInterval") == 5)
        // Back again: the phone changes it later, the Mac follows.
        phone.defaults.set(true, forKey: "squareTiles")
        await exchange(mac, phone)
        #expect(mac.defaults.object(forKey: "squareTiles") as? Bool == true)
        // Settings of this device are never sent.
        mac.defaults.set(7, forKey: "gridColumns")
        await exchange(mac, phone)
        #expect(phone.defaults.object(forKey: "gridColumns") == nil)
        #expect(mac.store.value("gridColumns") == nil)
    }

    /// A device that syncs for the first time takes over the account's settings; its own only fill in.
    @Test func theFirstSyncOfANewDeviceLetsTheAccountsSettingsWin() async {
        let mac = device("mac")
        await mac.bridge.prepare(mac.store, account: "alice")
        mac.defaults.set(false, forKey: "squareTiles")
        await mac.bridge.prepare(mac.store, account: "alice")
        let phone = device("phone")
        phone.defaults.set(true, forKey: "squareTiles")
        phone.defaults.set(true, forKey: "loupe.histogram")
        await exchange(mac, phone)
        #expect(phone.defaults.object(forKey: "squareTiles") as? Bool == false)
        #expect(mac.defaults.object(forKey: "loupe.histogram") as? Bool == true)
    }

    @Test func filmChoicesAndBirthdaysMergeEntryByEntry() async throws {
        let mac = device("mac")
        let phone = device("phone")
        await exchange(mac, phone)
        let macFilms: [String: [String: String]] = ["trip-2024-05": ["style": "calm"]]
        let phoneFilms: [String: [String: String]] = ["year-2023": ["style": "upbeat"]]
        mac.defaults.set(try JSONEncoder().encode(macFilms), forKey: "memoryFilmChoices")
        phone.defaults.set(try JSONEncoder().encode(phoneFilms), forKey: "memoryFilmChoices")
        mac.defaults.set(["Anna": 1_000_000.0], forKey: "throughTheYearsBirthdays.alice")
        phone.defaults.set(["Ben": 2_000_000.0], forKey: "throughTheYearsBirthdays.alice")
        // Another account's birthdays stay with that account.
        mac.defaults.set(["Carl": 3_000_000.0], forKey: "throughTheYearsBirthdays.bob")
        await exchange(mac, phone)
        await exchange(mac, phone)
        for device in [mac, phone] {
            let data = try #require(device.defaults.data(forKey: "memoryFilmChoices"))
            let films = try JSONDecoder().decode([String: [String: String]].self, from: data)
            #expect(films == macFilms.merging(phoneFilms) { $1 })
            let birthdays = device.defaults.dictionary(forKey: "throughTheYearsBirthdays.alice") as? [String: Double]
            #expect(birthdays == ["Anna": 1_000_000, "Ben": 2_000_000])
        }
        #expect(phone.defaults.object(forKey: "throughTheYearsBirthdays.bob") == nil)
        #expect(mac.store.values(prefix: "birthdays/").keys.sorted() == ["birthdays/Anna", "birthdays/Ben"])
        // A birthday removed on the phone is removed on the Mac.
        phone.defaults.set(["Ben": 2_000_000.0], forKey: "throughTheYearsBirthdays.alice")
        await exchange(mac, phone)
        #expect(mac.defaults.dictionary(forKey: "throughTheYearsBirthdays.alice") as? [String: Double] == ["Ben": 2_000_000])
    }

    @Test func aSettingRemovedOnOneDeviceGoesBackToItsDefaultEverywhere() async {
        let mac = device("mac")
        let phone = device("phone")
        await exchange(mac, phone)
        mac.defaults.set("Trip {counter}", forKey: "batchRenamePattern")
        await exchange(mac, phone)
        #expect(phone.defaults.string(forKey: "batchRenamePattern") == "Trip {counter}")
        mac.defaults.removeObject(forKey: "batchRenamePattern")
        await exchange(mac, phone)
        #expect(phone.defaults.object(forKey: "batchRenamePattern") == nil)
    }

    @Test func turnedOffNothingIsSentOrTakenOver() async {
        let mac = device("mac")
        let phone = device("phone")
        await exchange(mac, phone)
        phone.defaults.set(false, forKey: SyncedDefaults.enabledKey)
        mac.defaults.set(false, forKey: "lookHeaderTint")
        phone.defaults.set(false, forKey: "stackCopies")
        await exchange(mac, phone)
        #expect(phone.defaults.object(forKey: "lookHeaderTint") == nil)
        #expect(mac.defaults.object(forKey: "stackCopies") == nil)
    }

    @Test func propertyListValuesRoundTrip() {
        #expect(SyncedDefaults.json(true as NSNumber) == .bool(true))
        #expect(SyncedDefaults.json(3 as NSNumber) == .number(3))
        #expect(SyncedDefaults.json(["a": [1, 2]] as [String: Any]) == .object(["a": .array([.number(1), .number(2)])]))
        #expect(SyncedDefaults.json(Date()) == nil)
        #expect(SyncedDefaults.propertyList(.number(4)) as? Int == 4)
        #expect(SyncedDefaults.propertyList(.number(2.5)) as? Double == 2.5)
    }
}

@Suite(.timeLimit(.minutes(1))) @MainActor struct FamilySettingsSyncTests {
    let server = StubServer()
    let sandbox = Sandbox()

    func device() throws -> FamilySettingsSync {
        let connection = ServerConnection(serverURL: server.url, userId: "alice", loginName: "alice", appPassword: "x", userAgent: "tests")
        let dav = DAVClient(http: server.http(), connection: connection)
        let store = SyncedSettingsStore(files: AppDataFiles(dav: dav), kind: .family, localFile: nil, sendDelay: .seconds(3600))
        let database = try AccountDatabase(url: sandbox.root.appending(path: "\(UUID().uuidString).sqlite"))
        return FamilySettingsSync(store: store, family: FamilyStore(database: database))
    }

    @Test func decisionsAndOptionsReachTheOtherDevice() async throws {
        defer { sandbox.remove() }
        let mac = try device()
        let phone = try device()
        let folder = SharedFolder(path: "/Family", kind: .own, sharedWith: ["bob"])
        let settings = FamilyLibrarySettings(folder: folder, members: ["Anna"])
        await mac.publish(settings)
        try mac.family.record(.dismissed, for: [11, 12])
        await mac.publish(.dismissed, for: [11, 12])
        await mac.publish(.moved, for: [13])
        await phone.store.merge(mac.store.snapshot())
        #expect(try phone.takeOver(current: FamilyLibrarySettings()) == settings)
        #expect(try phone.family.decisions() == [11: .dismissed, 12: .dismissed, 13: .moved])
        #expect(try phone.takeOver(current: settings) == nil)
        // "Show dismissed again" on the phone: the Mac forgets them too.
        try phone.family.forgetDecisions()
        await phone.forgetAll()
        await mac.store.merge(phone.store.snapshot())
        _ = try mac.takeOver(current: settings)
        #expect(try mac.family.decisions().isEmpty)
    }

    /// Decisions made before decisions were synced go out once; removed ones are not brought back.
    @Test func earlierDecisionsArePublishedOnceAndRemovalsWin() async throws {
        defer { sandbox.remove() }
        let mac = try device()
        let phone = try device()
        try mac.family.record(.copied, for: [21])
        try await mac.publishUnsynced(FamilyLibrarySettings())
        #expect(mac.store.value("decision/21") == .string("copied"))
        // The phone has an old decision about 22 that the Mac removed (tombstone in the file).
        await mac.store.set(.string("dismissed"), for: "decision/22")
        await mac.store.set(nil, for: "decision/22")
        try phone.family.record(.dismissed, for: [22])
        await phone.store.merge(mac.store.snapshot())
        try await phone.publishUnsynced(FamilyLibrarySettings())
        #expect(phone.store.value("decision/22") == nil)
        _ = try phone.takeOver(current: FamilyLibrarySettings())
        #expect(try phone.family.decisions() == [21: .copied])
    }
}
