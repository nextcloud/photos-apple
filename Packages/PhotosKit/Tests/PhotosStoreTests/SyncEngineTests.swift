// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import Testing

@testable import PhotosModel
@testable import PhotosNetworking
@testable import PhotosStore

/// The sync engine against a stubbed DAV layer (`FakeDAVServer`).
@Suite struct SyncEngineTests {
    let server = FakeDAVServer()
    let database: AccountDatabase
    let library: LibraryStore
    let engine: SyncEngine

    init() throws {
        database = try AccountDatabase.temporary()
        library = LibraryStore(database: database)
        engine = SyncEngine(
            api: server.api, database: database, features: ServerFeatures(serverVersion: ServerVersion(major: 36), enabled: [.captions]),
            reconcileInterval: 0)
        server.put(
            file(1, "/Photos/a.jpg", time: 1000), file(2, "/Photos/b.jpg", time: 2000), file(3, "/Photos/2026/c.jpg", time: 3000))
    }

    func file(_ id: FileID, _ path: String, time: Double) -> FakeDAVServer.File {
        FakeDAVServer.File(id: id, path: path, etag: "e\(id)", modified: time, captured: time)
    }

    /// First sync (index + the reconciliation that follows it); the request log starts empty afterwards.
    func initialSync() async throws {
        await engine.sync()
        #expect(try library.count() == 3)
        server.clearRequests()
    }

    /// The file ids of each by-id fetch the server saw.
    var fetchedIds: [[FileID]] {
        server.requests.compactMap { request -> [FileID]? in
            if case .byIds(let ids) = request.kind { return ids.sorted() }
            return nil
        }
    }

    /// How often the library was walked: the first page of a walk has no cursor (the walk ends with an empty page).
    var reconcileWalks: Int {
        server.requests(.indexByModified).filter { !$0.body.contains("<d:lt>") && !$0.body.contains("<d:gte>") }.count
    }

    func ids() throws -> [FileID] { try library.gridItems(.all).map(\.fileId).sorted() }

    // MARK: Favourites, place, caption (9)

    @Test func favouriteSetElsewhereArrivesAlthoughNoETagChanged() async throws {
        try await initialSync()
        server.setFavorite(2, true)

        await engine.sync()
        #expect(try library.item(2)?.isFavorite == true)
        #expect(try library.gridItems(.favorites).map(\.fileId) == [2])
        // Cheap: the root ETag check and one favourites SEARCH, no walk through the library.
        #expect(server.requests(.favorites).count == 1)
        #expect(server.requests(.indexByModified).isEmpty)
        #expect(server.requests(.changed).isEmpty)

        server.setFavorite(2, false)
        await engine.sync()
        #expect(try library.item(2)?.isFavorite == false)
    }

    @Test func reconciliationPicksUpFavouritePlaceAndCaptionWithUnchangedETags() async throws {
        try await initialSync()
        server.setFavorite(1, true)
        server.setMetadata(3, place: "Berlin", caption: "A cat on a sofa")

        await engine.sync(forceReconcile: true)
        #expect(try library.item(1)?.isFavorite == true)
        #expect(try library.item(3)?.place == "Berlin")
        #expect(try library.item(3)?.caption == "A cat on a sofa")
        // Only the two changed rows were fetched again.
        #expect(fetchedIds == [[1, 3]])

        // Nothing differs any more: the next reconciliation fetches nothing.
        server.clearRequests()
        await engine.sync(forceReconcile: true)
        #expect(fetchedIds.isEmpty)
    }

    @Test func latePlaceOfARecentUploadArrivesWithoutETagChange() async throws {
        var recent = file(4, "/Photos/new.jpg", time: 4000)
        recent.uploaded = Date().timeIntervalSince1970 - 60
        server.put(recent)
        await engine.sync()
        #expect(try library.item(4)?.place == nil)

        server.setMetadata(4, place: "Lisbon", caption: nil)
        await engine.sync()
        #expect(try library.item(4)?.place == "Lisbon")
    }

    // MARK: Deletes and moves (10)

    @Test func deleteAndMoveAreDetectedWhenTheRootETagChanged() async throws {
        try await initialSync()
        server.delete(1)
        server.move(3, to: "/Photos/Trips/c.jpg")

        await engine.sync()
        #expect(try ids() == [2, 3])
        #expect(try library.item(3)?.path == "/Photos/Trips/c.jpg")
        #expect(reconcileWalks == 1)
    }

    @Test func refreshReconcilesEvenIfTheRootETagLooksUnchanged() async throws {
        try await initialSync()
        server.delete(1, changingRootETag: false)

        await engine.sync()
        #expect(try ids() == [1, 2, 3])  // a plain sync trusts the ETag
        await engine.sync(forceReconcile: true)  // pull-to-refresh, "Sync now"
        #expect(try ids() == [2, 3])
    }

    @Test func reconcileRequestedDuringARunningSyncIsNotDropped() async throws {
        try await initialSync()
        // Hold the first request of the running sync until the forced one has been requested.
        let (released, release) = AsyncStream<Void>.makeStream()
        let held = Mutex(false)
        server.gate.withLock {
            $0 = { _ in
                guard
                    held.withLock({
                        let first = !$0; $0 = true; return first
                    })
                else { return }
                for await _ in released { break }
            }
        }
        let engine = self.engine
        let plain = Task { await engine.sync() }
        #expect(await eventually { !server.requests.isEmpty })
        server.delete(1, changingRootETag: false)
        let forced = Task { await engine.sync(forceReconcile: true) }
        try await Task.sleep(for: .milliseconds(100))  // let it join the running sync
        release.yield()
        await plain.value
        await forced.value

        #expect(try ids() == [2, 3])
        #expect(reconcileWalks == 1)
    }

    // MARK: Boundary ETag (12)

    @Test func changeWhileSyncingIsPickedUpByTheNextSync() async throws {
        try await initialSync()
        var lateFile = file(5, "/Photos/late.jpg", time: 500)  // old mtime, so only the delta's upload time finds it
        lateFile.uploaded = Date().timeIntervalSince1970
        let late = lateFile
        server.put(file(4, "/Photos/d.jpg", time: Date().timeIntervalSince1970))
        // A file appears on the server right after the sync's last look at the library.
        let added = Mutex(false)
        server.afterResponse.withLock {
            $0 = { request, state in
                // The page after the last item is the walk's last look.
                guard request.kind == .indexByModified, request.body.contains("<d:lt>"), !request.body.contains("<d:gte>"),
                    added.withLock({
                        let first = !$0; $0 = true; return first
                    })
                else { return }
                state.files[late.id] = late
                FakeDAVServer.bumpRoot(&state)
            }
        }

        await engine.sync()
        #expect(try ids() == [1, 2, 3, 4])
        // One PROPFIND per existing root, before anything is fetched.
        #expect(server.requests(.propfind).filter { $0.path == "/Photos" }.count == 1)
        #expect(server.requests.first?.kind == .propfind)

        // The stored ETag is the one read before fetching, so the root still counts as changed.
        await engine.sync()
        #expect(try ids() == [1, 2, 3, 4, 5])
    }

    // MARK: Cancellation (8b)

    @Test func cancellingTheCallerCancelsTheSync() async throws {
        try await initialSync()
        let statuses = Mutex<[SyncStatus]>([])
        await engine.setStatusHandler { status in statuses.withLock { $0.append(status) } }
        server.delete(1, changingRootETag: false)
        // The reconciliation walk never answers.
        server.gate.withLock {
            $0 = { request in
                if request.kind == .indexByModified { try? await Task.sleep(for: .seconds(60)) }
            }
        }
        let engine = self.engine
        let started = Date()
        let task = Task { await engine.sync(forceReconcile: true) }
        #expect(await eventually { !server.requests(.indexByModified).isEmpty })
        task.cancel()
        await task.value
        #expect(Date().timeIntervalSince(started) < 10)
        // Cancelled is not an error to show.
        #expect(statuses.withLock { $0.last } == .idle(lastSync: await engine.lastSyncDate))
        #expect(statuses.withLock { $0 }.allSatisfy { if case .failed = $0 { false } else { true } })
        #expect(try ids() == [1, 2, 3])

        // The interrupted reconciliation is still due: the next ordinary sync runs it.
        server.gate.withLock { $0 = nil }
        await engine.sync()
        #expect(try ids() == [2, 3])
    }

    @Test func alreadyCancelledCallerDoesNotStartASync() async throws {
        try await initialSync()
        let engine = self.engine
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await engine.sync()
        }
        await task.value
        #expect(server.requests.isEmpty)
    }

    // MARK: Outbox and sync (SPEC §5.4.5)

    @Test func syncKeepsOptimisticStateOfQueuedOperations() async throws {
        try await initialSync()
        server.setOffline(true)
        let outbox = Outbox(api: server.api, database: database, retryDelay: { _ in 3600 })
        try await outbox.enqueue([
            .favorite(fileId: 2, path: "/Photos/b.jpg", value: true), .delete(fileId: 1, path: "/Photos/a.jpg"),
        ])
        #expect(await eventually { !server.requests(.proppatch).isEmpty })
        #expect(await eventually { try await outbox.nextRetryDate() != nil })
        server.setOffline(false)

        // The server still has the old state; a reconciliation must not undo what the user did.
        await engine.sync(forceReconcile: true)
        #expect(try library.item(2)?.isFavorite == true)
        #expect(try ids() == [2, 3])

        await outbox.kickNow()
        #expect(await eventually { try await outbox.pendingCount() == 0 })
        #expect(server.file(2)?.favorite == true)
        #expect(server.file(1) == nil)
    }
}
