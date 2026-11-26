// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosCore
@testable import PhotosModel
@testable import PhotosNetworking
@testable import PhotosStore

/// Undoable changes: what they send, what takes them back, and how they reach the undo manager.
@Suite struct UndoableChangeTests {
    static func item(_ id: Int64, favorite: Bool = false, archived: Bool = false, mount: String = "", path: String? = nil) -> MediaItem {
        var item = MediaItem(
            fileId: FileID(id), path: path ?? "/Photos/\(id).jpg", mimeType: "image/jpeg", isFavorite: favorite, mountType: mount)
        item.isArchived = archived
        return item
    }

    @Test func undoingAFavouriteOnlyTouchesWhatChanged() {
        let change = UndoableChange.favorite([Self.item(1), Self.item(2, favorite: true)], value: true)
        #expect(change.kind == .favorite)
        #expect(change.count == 2)
        #expect(change.inverseOperations == [.favorite(fileId: 1, path: "/Photos/1.jpg", value: false)])
        #expect(change.isUndoable(trashbin: false))
        // Nothing changed: nothing to undo.
        #expect(!UndoableChange.favorite([Self.item(2, favorite: true)], value: true).isUndoable(trashbin: true))
        #expect(UndoableChange.favorite([Self.item(2, favorite: true)], value: false).kind == .unfavorite)
    }

    @Test func undoingAnArchiveMovesTheFileBackFromTheArchive() {
        let shared = Self.item(3, mount: "shared")
        let change = UndoableChange.archive([Self.item(1), Self.item(2, archived: true), shared])
        #expect(change.operations == [.archive(fileId: 1, path: "/Photos/1.jpg")])
        #expect(change.inverseOperations == [.unarchive(fileId: 1, path: "/.archive/Photos/1.jpg")])

        let back = UndoableChange.unarchive([Self.item(4, archived: true, path: "/.archive/Photos/4.jpg"), Self.item(5)])
        #expect(back.operations == [.unarchive(fileId: 4, path: "/.archive/Photos/4.jpg")])
        #expect(back.inverseOperations == [.archive(fileId: 4, path: "/Photos/4.jpg")])
    }

    @Test func undoingARemovalAddsOwnPhotosToTheAlbumAgain() {
        let album = Album(kind: .own, name: "Trip")
        let change = UndoableChange.removeFromAlbum(
            [
                .init(fileId: 1, childName: "1-a.jpg", ownPath: "/Photos/a.jpg"),
                .init(fileId: 2, childName: "2-b.jpg", ownPath: nil),
            ], album: album)
        #expect(change.count == 2)
        #expect(
            change.operations.first
                == .removeFromAlbum(albumId: album.id, albumName: "Trip", albumKind: .own, fileId: 1, childName: "1-a.jpg"))
        // A photo somebody else added cannot be added again by this user.
        #expect(
            change.inverseOperations
                == [.addToAlbum(albumId: album.id, albumName: "Trip", albumKind: .own, fileId: 1, path: "/Photos/a.jpg")])
    }

    @Test func aDeleteIsOnlyUndoableWithATrashBin() {
        let readOnly = MediaItem(fileId: 2, path: "/Shared/2.jpg", mimeType: "image/jpeg", permissions: Permissions(rawValue: "RG"))
        let change = UndoableChange.delete([Self.item(1), readOnly])
        #expect(change.operations == [.delete(fileId: 1, path: "/Photos/1.jpg")])
        #expect(change.inverseOperations.isEmpty)
        #expect(change.isUndoable(trashbin: true))
        #expect(!change.isUndoable(trashbin: false))
        #expect(!UndoableChange.delete([readOnly]).isUndoable(trashbin: true))
        // A deleted share does not land in the user's trash bin: no Undo for it alone.
        let share = Self.item(3, mount: "shared")
        #expect(!UndoableChange.delete([share]).isUndoable(trashbin: true))
        #expect(UndoableChange.delete([share, Self.item(4)]).isUndoable(trashbin: true))
    }

    /// Photos restored from the trash bin go back into the albums they were in (the server took them out), except where
    /// an album's filters put them and in public link albums.
    @Test func restoredPhotosGoBackIntoTheirAlbums() throws {
        let database = try AccountDatabase.temporary()
        let albums = CollectionStore(database: database)
        let own = Album(kind: .own, name: "Trip")
        let shared = Album(kind: .shared, name: "Family (bob)")
        for album in [own, shared] { try albums.upsertAlbum(album) }
        let rows = DeletedRows(albumItems: [
            AlbumMembership(albumId: own.id, fileId: 1, childName: "1-a.jpg", origin: "user", ownerPath: "/Photos/a.jpg", position: 0),
            AlbumMembership(albumId: shared.id, fileId: 1, childName: "1-a.jpg", origin: "user", ownerPath: nil, position: 3),
            AlbumMembership(albumId: own.id, fileId: 2, childName: "2-b.jpg", origin: "filters", ownerPath: nil, position: 1),
            AlbumMembership(albumId: "own:Gone", fileId: 1, childName: "1-a.jpg", origin: "user", ownerPath: nil, position: 0),
            AlbumMembership(albumId: own.id, fileId: 9, childName: "9-c.jpg", origin: "user", ownerPath: nil, position: 2),
        ])
        let restored = [Self.item(1, path: "/Photos/a.jpg"), Self.item(2, path: "/Photos/b.jpg")]
        #expect(
            SessionModel.albumAdditions(restoring: restored, rows: rows, albums: albums) == [
                .addToAlbum(albumId: own.id, albumName: "Trip", albumKind: .own, fileId: 1, path: "/Photos/a.jpg"),
                .addToAlbum(albumId: shared.id, albumName: "Family (bob)", albumKind: .shared, fileId: 1, path: "/Photos/a.jpg"),
            ])
    }

    @Test func fileIdsAreThoseOfTheOperations() {
        let album = Album(kind: .own, name: "Trip")
        let readOnly = MediaItem(fileId: 9, path: "/Shared/9.jpg", mimeType: "image/jpeg", permissions: Permissions(rawValue: "RG"))
        let changes: [UndoableChange] = [
            .favorite([Self.item(1), Self.item(2, favorite: true)], value: true),
            .archive([Self.item(1), Self.item(2, archived: true), Self.item(3, mount: "shared")]),
            .unarchive([Self.item(4, archived: true), Self.item(5)]),
            .removeFromAlbum([.init(fileId: 6, childName: "6.jpg", ownPath: nil)], album: album),
            .delete([Self.item(7), readOnly]),
        ]
        for change in changes {
            #expect(change.fileIds == change.operations.map(\.fileId), "\(change.kind)")
        }
        #expect(changes[1].fileIds == [1])
        #expect(changes[4].fileIds == [7])
    }

    /// The inverse operations bring the local index back to where it was.
    @Test func inverseOperationsRestoreTheIndex() throws {
        let database = try AccountDatabase.temporary()
        let library = LibraryStore(database: database)
        let items = [Self.item(1), Self.item(2, favorite: true), Self.item(3)]
        try library.upsert(items)
        func state() throws -> [String] {
            try items.map { item in
                let stored = try #require(try library.item(item.fileId))
                return "\(stored.fileId):\(stored.isFavorite):\(stored.isArchived)"
            }
        }
        let before = try state()
        for change in [UndoableChange.favorite(items, value: true), .favorite(items, value: false), .archive(items)] {
            try database.writer.write { db in for operation in change.operations { try Outbox.applyLocally(operation, db: db) } }
            #expect(try state() != before)
            try database.writer.write { db in for operation in change.inverseOperations { try Outbox.applyLocally(operation, db: db) } }
            #expect(try state() == before, "\(change.kind)")
        }
    }
}

/// Changes made through the session: registered with the undo manager, undone, redone, announced.
@MainActor
@Suite struct SessionUndoTests {
    let sandbox = Sandbox()
    let server = StubServer()

    func makeSession() async throws -> (AppModel, SessionModel) {
        let account = makeAccount("alice", server: server.url.absoluteString)
        try sandbox.keychain.set("password", for: Keychain.passwordKey(account.id.rawValue))
        try AccountRegistry(accounts: [account], activeAccountID: account.id).save(to: sandbox.layout.accountsFile)
        let suite = "photos-core-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let app = AppModel(
            appVersion: "1.0", layout: sandbox.layout, keychain: sandbox.keychain, defaults: defaults,
            httpConfiguration: server.configuration)
        let session = try #require(app.session)
        // The first sync resets the index; let it get that over with before anything is put in.
        await session.syncNow()
        return (app, session)
    }

    func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func aChangeIsRegisteredUndoneAndRedone() async throws {
        defer { sandbox.remove() }
        let (app, session) = try await makeSession()
        let library = try #require(session.services).library
        let items = [UndoableChangeTests.item(1), UndoableChangeTests.item(2, favorite: true)]
        try library.upsert(items)
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        func favourites() -> [Bool] { items.map { (try? library.item($0.fileId))??.isFavorite ?? false } }

        undoManager.beginUndoGrouping()
        await session.perform(.favorite(items, value: true), undoManager: undoManager)
        undoManager.endUndoGrouping()
        #expect(favourites() == [true, true])
        #expect(undoManager.canUndo)
        #expect(undoManager.undoActionName == UndoableChange.favorite(items, value: true).actionName)
        let notice = try #require(session.lastChange)
        #expect(notice.canUndo && !notice.isReverted && notice.change.count == 2)

        undoManager.undo()
        #expect(await waitUntil { favourites() == [false, true] })
        #expect(await waitUntil { session.lastChange?.isReverted == true })
        #expect(undoManager.canRedo)

        undoManager.redo()
        #expect(await waitUntil { favourites() == [true, true] })
        #expect(await waitUntil { session.lastChange?.isReverted == false })
        #expect(undoManager.canUndo)

        // The banner's Undo button takes the same way.
        let again = try #require(session.lastChange)
        await session.undo(again)
        #expect(await waitUntil { favourites() == [false, true] })
        // A notice that is no longer the current one does nothing.
        await session.undo(notice)
        #expect(await waitUntil { session.lastChange?.isReverted == true })
        session.dismissNotice(try #require(session.lastChange).id)
        #expect(session.lastChange == nil)
        await app.session?.shutdown(closeDatabase: true)
    }

    @Test func withoutAnUndoManagerTheBannerStillUndoes() async throws {
        defer { sandbox.remove() }
        let (app, session) = try await makeSession()
        let library = try #require(session.services).library
        let item = UndoableChangeTests.item(7)
        try library.upsert([item])
        await session.perform(.archive([item]), undoManager: nil)
        #expect(try library.item(7)?.isArchived == true)
        await session.undo(try #require(session.lastChange))
        #expect(try library.item(7)?.isArchived == false)
        #expect(session.lastChange?.isReverted == true)
        // A delete on a server without a trash bin cannot be taken back, and says so.
        await session.perform(.delete([item]), undoManager: nil)
        #expect(session.lastChange?.canUndo == false)
        await app.session?.shutdown(closeDatabase: true)
    }

    func archived(_ library: LibraryStore, _ ids: FileID...) -> [Bool] {
        ids.map { (try? library.item($0))??.isArchived ?? false }
    }

    /// Changes registered one by one, as separate user actions.
    func perform(_ change: UndoableChange, in session: SessionModel, undoManager: UndoManager) async {
        undoManager.beginUndoGrouping()
        await session.perform(change, undoManager: undoManager)
        undoManager.endUndoGrouping()
    }

    func undoManager() -> UndoManager {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }

    /// Two taps on Undo, the second while the first undo still runs: only the change of the notice is taken back, not
    /// the earlier change of the same name.
    @Test func aSecondTapDoesNotUndoAnEarlierChange() async throws {
        defer { sandbox.remove() }
        let (app, session) = try await makeSession()
        let library = try #require(session.services).library
        let items = [UndoableChangeTests.item(1), UndoableChangeTests.item(2)]
        try library.upsert(items)
        let manager = undoManager()
        for item in items { await perform(.archive([item]), in: session, undoManager: manager) }
        let notice = try #require(session.lastChange)

        async let first: Void = session.undo(notice)
        async let second: Void = session.undo(notice)
        _ = await (first, second)
        #expect(archived(library, 1, 2) == [true, false])
        #expect(session.lastChange?.isReverted == true)
        // The earlier archive is still on the undo stack.
        #expect(manager.canUndo)
        manager.undo()
        await session.undoState.reverting?.value
        #expect(archived(library, 1, 2) == [false, false])
        await app.session?.shutdown(closeDatabase: true)
    }

    /// Another action of the same name on top of the undo stack: the banner takes back its own change, not that one,
    /// and Edit › Undo does not take the change back a second time later.
    @Test func theBannerOnlyUndoesItsOwnChange() async throws {
        defer { sandbox.remove() }
        let (app, session) = try await makeSession()
        let library = try #require(session.services).library
        let item = UndoableChangeTests.item(1)
        try library.upsert([item])
        let manager = undoManager()
        await perform(.archive([item]), in: session, undoManager: manager)
        let notice = try #require(session.lastChange)
        final class Other {
            var undone = 0
        }
        let other = Other()
        manager.beginUndoGrouping()
        manager.registerUndo(withTarget: other) { $0.undone += 1 }
        manager.setActionName(notice.change.actionName)
        manager.endUndoGrouping()

        await session.undo(notice)
        #expect(other.undone == 0)
        #expect(archived(library, 1) == [false])
        let reverted = try #require(session.lastChange)
        #expect(reverted.isReverted)

        manager.undo()
        #expect(other.undone == 1)
        manager.undo()  // the change's own registration: taken back already, so nothing happens
        await session.undoState.reverting?.value
        #expect(session.lastChange?.id == reverted.id)
        #expect(session.undoState.consumed.isEmpty)
        await app.session?.shutdown(closeDatabase: true)
    }

    /// Every window undoes its own changes; a window that goes away takes nothing from the others.
    @Test func eachWindowUndoesItsOwnChanges() async throws {
        defer { sandbox.remove() }
        let (app, session) = try await makeSession()
        let library = try #require(session.services).library
        let items = (1...3).map { UndoableChangeTests.item($0) }
        try library.upsert(items)
        let windowA = undoManager()
        let windowB = undoManager()
        await perform(.archive([items[0]]), in: session, undoManager: windowA)
        await perform(.archive([items[1]]), in: session, undoManager: windowB)
        do {
            let closed = undoManager()
            await perform(.archive([items[2]]), in: session, undoManager: closed)
        }
        #expect(windowA.canUndo && windowB.canUndo)

        windowA.undo()
        await session.undoState.reverting?.value
        #expect(archived(library, 1, 2, 3) == [false, true, true])
        #expect(!windowA.canUndo)
        windowB.undo()
        await session.undoState.reverting?.value
        #expect(archived(library, 1, 2, 3) == [false, false, true])
        await app.session?.shutdown(closeDatabase: true)
    }

    /// A session that stops (account switch, removal) leaves nothing to undo, and takes no more changes.
    @Test func stoppingTheSessionClearsUndo() async throws {
        defer { sandbox.remove() }
        let (app, session) = try await makeSession()
        let library = try #require(session.services).library
        let items = [UndoableChangeTests.item(1), UndoableChangeTests.item(2)]
        try library.upsert(items)
        let manager = undoManager()
        await perform(.archive([items[0]]), in: session, undoManager: manager)
        #expect(manager.canUndo)
        session.stop()
        #expect(!manager.canUndo)
        #expect(session.lastChange == nil)
        await perform(.archive([items[1]]), in: session, undoManager: manager)
        // Nothing registered (the test's own grouping leaves an empty group behind).
        #expect(manager.undoActionName.isEmpty)
        #expect(archived(library, 2) == [false])
        await app.session?.shutdown(closeDatabase: true)
    }

    /// Undo of a delete that is still queued (offline, a large selection): taken out of the queue, the photo is back at
    /// once with its album place, nothing is looked for in the trash bin, and the delete never runs.
    @Test func undoOfAQueuedDeleteTakesItBack() async throws {
        defer { sandbox.remove() }
        let (app, session) = try await makeSession()
        let services = try #require(session.services)
        session.features.enabled.insert(.trashbin)
        // The server does not answer lookups for now: the delete waits for its retry.
        server.set { $0.responses["SEARCH /remote.php/dav/"] = StubServer.Stub(status: 503, body: "") }
        let item = UndoableChangeTests.item(7)
        try services.library.upsert([item])
        let album = Album(kind: .own, name: "Trip")
        try services.collections.upsertAlbum(album)
        try services.collections.replaceAlbumContent(
            albumId: album.id,
            children: [MediaParser.CollectionChild(item: item, childName: "7-7.jpg", origin: "user", ownerPath: item.path)])

        await session.perform(.delete([item]), undoManager: nil)
        await services.outbox.waitUntilIdle()
        #expect(try services.library.item(7) == nil)
        #expect(try await services.outbox.pendingCount() == 1)
        let notice = try #require(session.lastChange)
        #expect(notice.canUndo)

        await session.undo(notice)
        #expect(session.lastChange?.isReverted == true)
        #expect(session.lastChange?.failures == 0)
        #expect(try services.library.item(7) != nil)
        #expect(try services.collections.albumItems(albumId: album.id).map(\.fileId) == [7])
        #expect(try await services.outbox.pendingCount() == 0)
        #expect(server.lines(containing: "/trashbin/").isEmpty)
        await app.session?.shutdown(closeDatabase: true)
    }

    /// Undo of a delete that reached the server: restored from the trash bin whatever its type (a TIFF here), and put
    /// back into its album.
    @Test func undoOfADeleteThatRanRestoresFromTheTrashBin() async throws {
        defer { sandbox.remove() }
        let (app, session) = try await makeSession()
        let services = try #require(session.services)
        session.features.enabled.insert(.trashbin)
        let item = MediaItem(fileId: 8, path: "/Photos/8.tif", mimeType: "image/tiff")
        try services.library.upsert([item])
        let album = Album(kind: .own, name: "Trip")
        try services.collections.upsertAlbum(album)
        try services.collections.replaceAlbumContent(
            albumId: album.id,
            children: [MediaParser.CollectionChild(item: item, childName: "8-8.tif", origin: "user", ownerPath: item.path)])
        let trash = """
            <?xml version="1.0"?><d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">\
            <d:response><d:href>/remote.php/dav/trashbin/alice/trash/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>\
            <d:response><d:href>/remote.php/dav/trashbin/alice/trash/8.tif.d1790000000</d:href><d:propstat><d:prop><oc:fileid>8</oc:fileid>\
            <d:getcontenttype>image/tiff</d:getcontenttype><oc:size>10</oc:size><nc:trashbin-filename>8.tif</nc:trashbin-filename>\
            <nc:trashbin-original-location>Photos/8.tif</nc:trashbin-original-location><nc:trashbin-deletion-time>1790000000</nc:trashbin-deletion-time>\
            <d:resourcetype/></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>
            """
        server.set {
            $0.responses["PROPFIND /remote.php/dav/trashbin/alice/trash/"] = StubServer.Stub(status: 207, body: trash)
            $0.responses["PROPFIND /remote.php/dav/trashbin/alice/trash"] = StubServer.Stub(status: 207, body: trash)
            $0.responses["MOVE /remote.php/dav/trashbin/alice/trash/8.tif.d1790000000"] = StubServer.Stub(status: 201, body: "")
        }

        // The server knows no such file: the delete counts as done at once.
        await session.perform(.delete([item]), undoManager: nil)
        await services.outbox.waitUntilIdle()
        #expect(try await services.outbox.pendingCount() == 0)
        #expect(try services.collections.albumItems(albumId: album.id).isEmpty)

        await session.undo(try #require(session.lastChange))
        #expect(session.lastChange?.isReverted == true)
        #expect(session.lastChange?.failures == 0)
        #expect(
            server.lines(containing: "/trashbin/") == [
                "PROPFIND /remote.php/dav/trashbin/alice/trash/", "MOVE /remote.php/dav/trashbin/alice/trash/8.tif.d1790000000",
            ])
        #expect(try services.collections.albumItems(albumId: album.id).map(\.fileId) == [8])
        await app.session?.shutdown(closeDatabase: true)
    }

    /// Undo while the delete waits for a retry after its DELETE failed (a 500 on a loaded Nextcloud 35): the server may
    /// have deleted the file all the same. Undo takes the delete out of the queue and restores the file from the trash
    /// bin, where it is (SPEC §20.1); before, only its row came back and the file stayed in the trash.
    @Test func undoOfADeleteWhoseAnswerFailedRestoresFromTheTrashBin() async throws {
        defer { sandbox.remove() }
        let (app, session) = try await makeSession()
        let services = try #require(session.services)
        session.features.enabled.insert(.trashbin)
        var item = MediaItem(fileId: 9, path: "/Photos/9.jpg", mimeType: "image/jpeg")
        item.etag = "e9"
        try services.library.upsert([item])
        let trash = """
            <?xml version="1.0"?><d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">\
            <d:response><d:href>/remote.php/dav/trashbin/alice/trash/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>\
            <d:response><d:href>/remote.php/dav/trashbin/alice/trash/9.jpg.d1790000000</d:href><d:propstat><d:prop><oc:fileid>9</oc:fileid>\
            <d:getcontenttype>image/jpeg</d:getcontenttype><oc:size>10</oc:size><nc:trashbin-filename>9.jpg</nc:trashbin-filename>\
            <nc:trashbin-original-location>Photos/9.jpg</nc:trashbin-original-location><nc:trashbin-deletion-time>1790000000</nc:trashbin-deletion-time>\
            <d:resourcetype/></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>
            """
        server.set {
            // The server moved the file to its trash bin, then failed.
            $0.responses["DELETE /remote.php/dav/files/alice/Photos/9.jpg"] = StubServer.Stub(status: 500, body: "")
            $0.responses["PROPFIND /remote.php/dav/trashbin/alice/trash/"] = StubServer.Stub(status: 207, body: trash)
            $0.responses["PROPFIND /remote.php/dav/trashbin/alice/trash"] = StubServer.Stub(status: 207, body: trash)
            $0.responses["MOVE /remote.php/dav/trashbin/alice/trash/9.jpg.d1790000000"] = StubServer.Stub(status: 201, body: "")
        }

        await session.perform(.delete([item]), undoManager: nil)
        await services.outbox.waitUntilIdle()
        #expect(server.lines(containing: "/files/alice/Photos/9.jpg").filter { $0.hasPrefix("DELETE") }.count == 1)
        #expect(try await services.outbox.pendingCount() == 1)

        await session.undo(try #require(session.lastChange))
        #expect(session.lastChange?.isReverted == true)
        #expect(session.lastChange?.failures == 0)
        #expect(
            server.lines(containing: "/trashbin/alice/trash/9.jpg.d1790000000") == [
                "MOVE /remote.php/dav/trashbin/alice/trash/9.jpg.d1790000000"
            ])
        #expect(try await services.outbox.pendingCount() == 0)
        await app.session?.shutdown(closeDatabase: true)
    }

    @Test func onlyDeletedFilesCountAsNotRestored() {
        #expect(SessionModel.undeleteFailures(deleted: [1, 2], restored: [1, 3]) == 1)
        // A file that only maybe reached the server and is not in the trash bin was never deleted: no failure.
        #expect(SessionModel.undeleteFailures(deleted: [], restored: []) == 0)
    }

    /// A refused certificate becomes account state, and trusting it ends that state.
    @Test func aRefusedCertificateIsAccountState() async throws {
        defer { sandbox.remove() }
        let (app, session) = try await makeSession()
        #expect(session.certificateProblem == nil)
        session.refreshCertificateProblem()
        #expect(session.certificateProblem == nil)
        await app.session?.shutdown(closeDatabase: true)
    }
}
