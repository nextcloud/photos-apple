// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosDomain
import Synchronization
import Testing

@testable import PhotosCore
@testable import PhotosModel
@testable import PhotosNetworking

/// `.nextcloud-photos/album-covers.json` on a pretend server: ETags, `If-Match` and `If-None-Match: *` as Nextcloud does.
final class FakeLookServer: Sendable {
    struct State {
        var file: Data?
        var version = 0
        var writes = 0
        var offline = false
    }

    let state = Mutex(State())

    var remote: AlbumLookRemote {
        AlbumLookRemote(
            fetch: { [self] in
                try state.withLock { state in
                    if state.offline { throw NetworkError.offline }
                    guard let file = state.file else { return nil }
                    return (file, "v\(state.version)")
                }
            },
            store: { [self] data, ifMatch in
                try state.withLock { state in
                    if state.offline { throw NetworkError.offline }
                    if let ifMatch {
                        guard state.file != nil, ifMatch == "v\(state.version)" else { throw NetworkError.preconditionFailed }
                    } else if state.file != nil {
                        throw NetworkError.preconditionFailed
                    }
                    state.file = data
                    state.version += 1
                    state.writes += 1
                    return "v\(state.version)"
                }
            })
    }

    var book: AlbumLookBook? { state.withLock { $0.file }.flatMap { try? AlbumLookBook.decode($0) } }

    /// Another device writes behind the app's back.
    func write(_ book: AlbumLookBook) throws {
        let data = try book.encoded()
        state.withLock { state in
            state.file = data
            state.version += 1
        }
    }
}

@MainActor
@Suite struct AlbumLookStoreTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "look-store-\(UUID().uuidString)")
    let server = FakeLookServer()
    let album = Album(kind: .own, name: "Lisbon", lastPhotoFileId: 100)

    func store(_ name: String = "a") -> AlbumLookStore {
        AlbumLookStore(localFile: directory.appending(path: "\(name)/album-covers.json"), remote: server.remote)
    }

    @Test func aChoiceIsKeptLocallyAndInTheUsersFiles() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let phone = store("phone")
        #expect(phone.coverFileId(for: album) == 100)
        #expect(phone.effect(for: album) == .automatic)
        await phone.set(cover: 7, effect: .depth, for: album)
        #expect(phone.coverFileId(for: album) == 7)
        #expect(phone.effect(for: album) == .depth)
        #expect(server.book?.look(for: album.id)?.coverFileId == 7)
        // Read back from the device at the next launch, before any network.
        #expect(store("phone").look(for: album)?.effect == .depth)
        // Another device picks it up.
        let mac = store("mac")
        await mac.refresh()
        #expect(mac.look(for: album)?.coverFileId == 7)
    }

    @Test func twoDevicesWritingAtOnceKeepBothChoices() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let phone = store("phone")
        await phone.refresh()
        // Meanwhile the Mac chose a cover for another album.
        var theirs = AlbumLookBook()
        theirs.set(AlbumLook(coverFileId: 55, effect: .still), for: "own:Porto")
        try server.write(theirs)
        await phone.set(cover: 7, effect: .depth, for: album)
        let book = try #require(server.book)
        #expect(book.look(for: "own:Porto")?.coverFileId == 55)
        #expect(book.look(for: album.id)?.coverFileId == 7)
        #expect(phone.book.look(for: "own:Porto")?.effect == .still)
    }

    @Test func offlineChoicesGoUpLater() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        server.state.withLock { $0.offline = true }
        let phone = store("phone")
        await phone.set(cover: nil, effect: .still, for: album)
        #expect(phone.effect(for: album) == .still)
        #expect(server.book == nil)
        server.state.withLock { $0.offline = false }
        await phone.refresh()
        #expect(server.book?.look(for: album.id)?.effect == .still)
    }

    @Test func refreshIsThrottledUnlessForced() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let phone = store("phone")
        let now = Date()
        await phone.refresh(now: now)
        var theirs = AlbumLookBook()
        theirs.set(AlbumLook(coverFileId: 3, effect: .depth), for: album.id)
        try server.write(theirs)
        await phone.refresh(now: now.addingTimeInterval(10))
        #expect(phone.look(for: album) == nil)
        await phone.refresh(force: true, now: now.addingTimeInterval(20))
        #expect(phone.look(for: album)?.coverFileId == 3)
    }

    @Test func renamedAlbumsKeepTheirCover() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let phone = store("phone")
        await phone.set(cover: 9, effect: .depth, for: album)
        await phone.renamed(album, to: "Lisboa")
        let renamed = Album(kind: .own, name: "Lisboa", lastPhotoFileId: 100)
        #expect(phone.coverFileId(for: renamed) == 9)
        #expect(phone.look(for: album) == nil)
        #expect(server.book?.look(for: renamed.id)?.effect == .depth)
    }

    @Test func nothingIsWrittenWhenNothingWasChosen() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let phone = store("phone")
        await phone.refresh()
        #expect(server.state.withLock { $0.writes } == 0)
    }
}

/// Guest Mode (SPEC §16.8.3).
@MainActor
@Suite struct GuestModeTests {
    let defaults: UserDefaults
    let suite = "guest-tests-\(UUID().uuidString)"
    let show = GuestShow(account: "anna@cloud.example", kind: .album, title: "Lisbon", items: [1, 2, 3])

    init() {
        defaults = UserDefaults(suiteName: suite)!
    }

    /// Counts the authentication prompts.
    @MainActor final class Prompts {
        var count = 0
    }

    func guest(answer: GuestMode.Authentication, asked: Prompts? = nil) -> GuestMode {
        GuestMode(defaults: defaults) { _ in
            asked?.count += 1
            return answer
        }
    }

    @Test func startsAndSurvivesARelaunch() {
        defer { defaults.removePersistentDomain(forName: suite) }
        let mode = guest(answer: .denied)
        #expect(!mode.isActive)
        mode.start(show)
        #expect(mode.isActive)
        // The app is quit and opened again: still in Guest Mode.
        let relaunched = guest(answer: .denied)
        #expect(relaunched.show == show)
    }

    @Test func endingNeedsTheDeviceOwner() async {
        defer { defaults.removePersistentDomain(forName: suite) }
        let asked = Prompts()
        let denied = guest(answer: .denied, asked: asked)
        denied.start(show)
        #expect(await denied.end(reason: "End") == false)
        #expect(denied.isActive)
        #expect(asked.count == 1)
        let granted = guest(answer: .granted)
        #expect(granted.isActive)
        #expect(await granted.end(reason: "End"))
        #expect(!granted.isActive)
        #expect(guest(answer: .denied).show == nil)
    }

    @Test func withoutAPasscodeItEndsAtOnce() async {
        defer { defaults.removePersistentDomain(forName: suite) }
        let mode = guest(answer: .unavailable)
        mode.start(show)
        #expect(await mode.end(reason: "End"))
        #expect(!mode.isActive)
    }

    @Test func emptyContentDoesNotStart() {
        defer { defaults.removePersistentDomain(forName: suite) }
        let mode = guest(answer: .granted)
        mode.start(GuestShow(account: "anna@cloud.example", kind: .memory, title: "Empty", items: []))
        #expect(!mode.isActive)
    }

    @Test func onlyThePhotosOfItsAccountAreShown() {
        defer { defaults.removePersistentDomain(forName: suite) }
        let mode = guest(answer: .granted)
        mode.start(show)
        #expect(mode.items(for: AccountID(rawValue: "anna@cloud.example")) == [1, 2, 3])
        #expect(mode.items(for: AccountID(rawValue: "ben@cloud.example")).isEmpty)
    }

    @Test func endingWhenNotActiveAsksNothing() async {
        defer { defaults.removePersistentDomain(forName: suite) }
        let asked = Prompts()
        let mode = guest(answer: .denied, asked: asked)
        #expect(await mode.end(reason: "End"))
        #expect(asked.count == 0)
    }
}
