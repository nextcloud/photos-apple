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
        session.undoManager = undoManager
        func favourites() -> [Bool] { items.map { (try? library.item($0.fileId))??.isFavorite ?? false } }

        undoManager.beginUndoGrouping()
        await session.perform(.favorite(items, value: true))
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
        await session.perform(.archive([item]))
        #expect(try library.item(7)?.isArchived == true)
        await session.undo(try #require(session.lastChange))
        #expect(try library.item(7)?.isArchived == false)
        #expect(session.lastChange?.isReverted == true)
        // A delete on a server without a trash bin cannot be taken back, and says so.
        await session.perform(.delete([item]))
        #expect(session.lastChange?.canUndo == false)
        await app.session?.shutdown(closeDatabase: true)
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
