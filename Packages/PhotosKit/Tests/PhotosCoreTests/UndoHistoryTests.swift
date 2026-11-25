// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosCore
@testable import PhotosMedia
@testable import PhotosModel
@testable import PhotosStore

/// Edits and album additions as undoable changes (SPEC §16.3).
@Suite struct EditChangeTests {
    static func recipe(rotation: Int) -> EditRecipe {
        var recipe = EditRecipe()
        recipe.edits.rotation = rotation
        return recipe
    }

    @Test func editsAreChangesOfTheirOwn() {
        let change = UndoableChange.edit(
            [
                EditChange(fileId: 1, name: "a.jpg", before: nil, after: Self.recipe(rotation: 1)),
                EditChange(fileId: 2, name: "b.jpg", before: Self.recipe(rotation: 3), after: nil),
            ], action: .rotate)
        #expect(change.kind == .rotate)
        #expect(change.count == 2)
        #expect(change.fileIds == [1, 2])
        // Made through the edit library, not the outbox.
        #expect(change.operations.isEmpty && change.inverseOperations.isEmpty)
        #expect(change.isUndoable(trashbin: false))
        #expect(UndoableChange.edit([], action: .edit).count == 0)
        #expect(UndoableChange.edit([], action: .revert).kind == .revertEdit)
    }

    @Test func anAlbumAdditionIsUndoneForOwnPhotos() {
        let album = Album(kind: .own, name: "Summer")
        let shared = UndoableChangeTests.item(3, mount: "shared")
        let change = UndoableChange.addToAlbum([UndoableChangeTests.item(1), shared], album: album)
        #expect(change.kind == .addToAlbum)
        #expect(
            change.operations == [.addToAlbum(albumId: album.id, albumName: "Summer", albumKind: .own, fileId: 1, path: "/Photos/1.jpg")])
        #expect(change.fileIds == [1])
        #expect(change.isUndoable(trashbin: false))
        #expect(!UndoableChange.addToAlbum([shared], album: album).isUndoable(trashbin: true))
    }

    @Test func sameEditIgnoresWhenItWasSaved() {
        var a = Self.recipe(rotation: 1)
        var b = a
        b.updatedAt = Date(timeIntervalSince1970: 5)
        #expect(SessionModel.sameEdit(a, b))
        #expect(SessionModel.sameEdit(nil, nil))
        #expect(!SessionModel.sameEdit(a, nil))
        a.edits.rotation = 2
        #expect(!SessionModel.sameEdit(a, b))
    }
}

/// The undo history (SPEC §16.3.4): every change, newest first, each undoable on its own while it still can be.
@MainActor
@Suite struct UndoHistoryTests {
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

    func undoManager() -> UndoManager {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }

    func perform(_ change: UndoableChange, in session: SessionModel, undoManager: UndoManager) async {
        undoManager.beginUndoGrouping()
        await session.perform(change, undoManager: undoManager)
        undoManager.endUndoGrouping()
    }

    /// Undoing an older change from the history takes back only that one; the later change stays, and stays on top
    /// of the undo stack.
    @Test func anOlderChangeIsUndoneOnItsOwn() async throws {
        defer { sandbox.remove() }
        let (app, session) = try await makeSession()
        let library = try #require(session.services).library
        let items = [UndoableChangeTests.item(1), UndoableChangeTests.item(2)]
        try library.upsert(items)
        let manager = undoManager()
        await perform(.favorite([items[0]], value: true), in: session, undoManager: manager)
        await perform(.archive([items[1]]), in: session, undoManager: manager)
        #expect(session.history.map(\.change.kind) == [.archive, .favorite])

        let older = session.history[1]
        #expect(session.revertProblem(older) == nil)
        await session.revertHistoryEntry(older.id)
        #expect(try library.item(1)?.isFavorite == false)
        #expect(try library.item(2)?.isArchived == true)
        #expect(session.history[1].isReverted)
        #expect(session.revertProblem(session.history[1]) == .reverted)
        // Edit › Undo still takes back the archive, and only once the favourite.
        #expect(manager.undoActionName == UndoableChange.archive([items[1]]).actionName)
        manager.undo()
        #expect(await waitUntil { (try? library.item(2))??.isArchived == false })
        #expect(await waitUntil { session.history[0].isReverted })
        manager.undo()  // the favourite's registration: consumed, does nothing
        try await Task.sleep(for: .milliseconds(50))
        #expect(try library.item(1)?.isFavorite == false)
        await app.session?.shutdown(closeDatabase: true)
    }

    /// A rotate is an edit: shown at once, undone from the history; an edit replaced by a later one says so.
    @Test func rotationsAreEditsInTheHistory() async throws {
        defer { sandbox.remove() }
        let (app, session) = try await makeSession()
        let services = try #require(session.services)
        let photo = UndoableChangeTests.item(5)
        try services.library.upsert([photo])
        await session.rotate([photo], clockwise: true, undoManager: nil)
        #expect(services.edits.recipe(for: 5)?.edits.rotation == 1)
        #expect(session.isEdited(5))
        let first = try #require(session.history.first)
        #expect(first.change.kind == .rotate)

        await session.rotate([photo], clockwise: true, undoManager: nil)
        #expect(services.edits.recipe(for: 5)?.edits.rotation == 2)
        // The first turn was built on by the second: it cannot be taken back alone.
        #expect(session.revertProblem(session.history[1]) == .editedLater)
        await session.revertHistoryEntry(session.history[0].id)
        #expect(services.edits.recipe(for: 5)?.edits.rotation == 1)
        #expect(session.revertProblem(session.history[1]) == nil)

        await session.revertToOriginal([photo], undoManager: nil)
        #expect(services.edits.recipe(for: 5) == nil)
        #expect(session.history.first?.change.kind == .revertEdit)
        await session.undo(try #require(session.lastChange))
        #expect(services.edits.recipe(for: 5)?.edits.rotation == 1)
        await app.session?.shutdown(closeDatabase: true)
    }

    @Test func historyIsBounded() async throws {
        defer { sandbox.remove() }
        let (app, session) = try await makeSession()
        let library = try #require(session.services).library
        let photo = UndoableChangeTests.item(1)
        try library.upsert([photo])
        for index in 0..<(ChangeHistoryEntry.limit + 5) {
            await session.perform(.favorite([photo], value: index % 2 == 0), undoManager: nil)
        }
        #expect(session.history.count == ChangeHistoryEntry.limit)
        await app.session?.shutdown(closeDatabase: true)
    }
}
