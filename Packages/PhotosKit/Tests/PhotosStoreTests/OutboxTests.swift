// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import Synchronization
import Testing

@testable import PhotosModel
@testable import PhotosNetworking
@testable import PhotosStore

/// The outbox against a stubbed DAV layer (`FakeDAVServer`).
///
/// The tests wait for the outbox (`waitUntilIdle`) and for observed values instead of polling against the clock: the
/// other tests of the bundle run in parallel and can keep this one waiting for many seconds (iOS Simulator in CI). The time limit only stops a hang.
@Suite(.timeLimit(.minutes(5))) struct OutboxTests {
    let server = FakeDAVServer()
    let database: AccountDatabase
    let library: LibraryStore

    init() throws {
        database = try AccountDatabase.temporary()
        library = LibraryStore(database: database)
        for (id, path) in [(FileID(1), "/Photos/a.jpg"), (2, "/Photos/b.jpg")] {
            server.put(FakeDAVServer.File(id: id, path: path, etag: "e\(id)", modified: 1000, captured: 1000))
            try library.upsert([MediaItem(fileId: id, path: path, mimeType: "image/jpeg", etag: "e\(id)")])
        }
    }

    func outbox(retryDelay: TimeInterval) -> Outbox {
        Outbox(api: server.api, database: database, retryDelay: { _ in retryDelay })
    }

    /// The next value of an observation, skipping none.
    func next(_ values: inout AsyncThrowingStream<MediaItem?, any Error>.Iterator) async throws -> Bool? {
        guard let item = try await values.next() else { return nil }
        return item?.isFavorite ?? false
    }

    /// The favourite values the server was asked to set, in order.
    var favouriteWrites: [String] {
        server.requests(.proppatch).map { $0.body.contains("<oc:favorite>1</oc:favorite>") ? "\($0.path)=1" : "\($0.path)=0" }
    }

    func attempts() throws -> [Int] {
        try database.writer.read { db in try Int.fetchAll(db, sql: "SELECT attempts FROM operation ORDER BY id") }
    }

    /// The viewer observes the row of the photo shown: a favourite toggle must reach it, also for a photo that is
    /// only in `collectionMedia` (an album shared with the user), so the heart flips and the next toggle sends the
    /// opposite value.
    @Test func favouriteToggleReachesTheObservedItem() async throws {
        let shared = MediaItem(fileId: 77, path: "/Shared/c.jpg", mimeType: "image/jpeg", etag: "e77")
        try await database.writer.write { db in try CollectionMediaRecord(fileId: 77, item: shared).insert(db) }
        let outbox = outbox(retryDelay: 3600)
        server.setOffline(true)

        for id in [FileID(1), 77] {
            // Duplicates are removed: each change arrives as exactly one value.
            var values = library.observeItem(id).makeAsyncIterator()
            #expect(try await next(&values) == false, "file \(id)")
            try await outbox.enqueue([.favorite(fileId: id, path: "/x.jpg", value: true)])
            #expect(try await next(&values) == true, "file \(id)")
            #expect(try library.item(id)?.isFavorite == true)
            try await outbox.enqueue([.favorite(fileId: id, path: "/x.jpg", value: false)])
            #expect(try await next(&values) == false, "file \(id)")
        }
    }

    @Test func operationInBackoffIsNotOvertaken() async throws {
        let outbox = outbox(retryDelay: 3600)
        server.setOffline(true)
        try await outbox.enqueue([
            .favorite(fileId: 1, path: "/Photos/a.jpg", value: true), .favorite(fileId: 1, path: "/Photos/a.jpg", value: false),
            .favorite(fileId: 2, path: "/Photos/b.jpg", value: true),
        ])
        await outbox.waitUntilIdle()
        #expect(try await outbox.nextRetryDate() != nil)
        // The two files were tried side by side; the second operation for file 1 waits behind the first.
        #expect(Set(favouriteWrites) == ["/Photos/a.jpg=1", "/Photos/b.jpg=1"])
        #expect(try attempts() == [1, 0, 1])

        // The network is back, but no retry is due yet: a kick (as after a sync) runs nothing — above all not the later
        // operation for file 1 ahead of the first: the final state on the server would be "favourite" although the user
        // undid it.
        server.setOffline(false)
        server.clearRequests()
        await outbox.kick()
        await outbox.waitUntilIdle()
        #expect(favouriteWrites.isEmpty)
        #expect(try await outbox.pendingCount() == 3)

        await outbox.kickNow()
        await outbox.waitUntilIdle()
        #expect(try await outbox.pendingCount() == 0)
        #expect(favouriteWrites.filter { $0.hasPrefix("/Photos/a.jpg") } == ["/Photos/a.jpg=1", "/Photos/a.jpg=0"])
        #expect(favouriteWrites.count == 3)
        #expect(server.file(1)?.favorite == false)
        #expect(server.file(2)?.favorite == true)
    }

    @Test func wakesItselfUpWhenTheRetryIsDue() async throws {
        let outbox = outbox(retryDelay: 0.3)
        server.setOffline(true)
        let enqueued = Date()
        try await outbox.enqueue([
            .favorite(fileId: 1, path: "/Photos/a.jpg", value: true), .favorite(fileId: 2, path: "/Photos/b.jpg", value: true),
        ])
        await outbox.waitUntilIdle()
        let retry = try #require(try await outbox.nextRetryDate())
        #expect(retry.timeIntervalSince(enqueued) >= 0.3)
        server.setOffline(false)

        // Nobody kicks: the outbox's own timer does (waiting does not kick, it only waits for the timer).
        await outbox.waitUntilIdle(retriesDueWithin: 60)
        #expect(try await outbox.pendingCount() == 0)
        #expect(Date() >= retry)
        // Both were tried at once, and both again when the retry was due. On a slow machine the timer can fire once
        // more before the test goes back online, so either may have been tried offline more than once.
        let writes = favouriteWrites
        #expect(Set(writes) == ["/Photos/a.jpg=1", "/Photos/b.jpg=1"])
        #expect(writes.filter { $0 == "/Photos/a.jpg=1" }.count >= 2)
        #expect(writes.filter { $0 == "/Photos/b.jpg=1" }.count >= 2)
        #expect(server.file(1)?.favorite == true)
        #expect(server.file(2)?.favorite == true)
        #expect(try await outbox.nextRetryDate() == nil)
    }

    @Test func shutdownStopsTheRetryTimer() async throws {
        let outbox = outbox(retryDelay: 0.2)
        server.setOffline(true)
        try await outbox.enqueue([.favorite(fileId: 1, path: "/Photos/a.jpg", value: true)])
        await outbox.waitUntilIdle()
        #expect(try await outbox.nextRetryDate() != nil)
        await outbox.shutdown()
        server.setOffline(false)
        server.clearRequests()

        // The retry would be due now; an outbox that was shut down does not wake itself up, and the operation stays pending.
        try await Task.sleep(for: .milliseconds(500))
        #expect(favouriteWrites.isEmpty)
        #expect(try await outbox.pendingCount() == 1)

        // It is not dead: an explicit kick runs it again.
        await outbox.kickNow()
        await outbox.waitUntilIdle()
        #expect(try await outbox.pendingCount() == 0)
    }

    @Test func keepsBackingOffWhileTheErrorPersists() async throws {
        // Retried at once for longer than a locked file would be, then a long wait.
        let quickRetries = Outbox.maxLockedAttempts + 2
        let delaysAsked = Mutex<[Int]>([])
        let outbox = Outbox(
            api: server.api, database: database,
            retryDelay: { attempts in
                delaysAsked.withLock { $0.append(attempts) }
                return attempts < quickRetries ? 0 : 3600
            })
        server.setOffline(true)
        try await outbox.enqueue([.favorite(fileId: 1, path: "/Photos/a.jpg", value: true)])
        await outbox.waitUntilIdle()
        #expect(delaysAsked.withLock { $0 } == Array(0...quickRetries))
        #expect(try attempts() == [quickRetries + 1])
        #expect(try await outbox.nextRetryDate() != nil)
        #expect(try await outbox.pendingCount() == 1)
        #expect(try await outbox.failedOperations().isEmpty)

        #expect(Outbox.defaultRetryDelay(attempts: 0) == 10)
        #expect(Outbox.defaultRetryDelay(attempts: 1) == 20)
        #expect(Outbox.defaultRetryDelay(attempts: 3) == 80)
        #expect(Outbox.defaultRetryDelay(attempts: 50) == 3600)
    }

    @Test func retriesWhenTheNetworkComesBack() async throws {
        let outbox = outbox(retryDelay: 3600)
        server.setOffline(true)
        try await outbox.enqueue([.favorite(fileId: 1, path: "/Photos/a.jpg", value: true)])
        await outbox.waitUntilIdle()
        #expect(try await outbox.nextRetryDate() != nil)
        server.setOffline(false)

        // The path monitor's first report of a working connection is not a change.
        await outbox.networkChanged(satisfied: true)
        await outbox.waitUntilIdle()
        #expect(try await outbox.pendingCount() == 1)

        await outbox.networkChanged(satisfied: false)
        await outbox.networkChanged(satisfied: true)
        await outbox.waitUntilIdle()
        #expect(try await outbox.pendingCount() == 0)
        #expect(server.file(1)?.favorite == true)
    }

    @Test func permanentFailureDoesNotBlockLaterOperations() async throws {
        let outbox = outbox(retryDelay: 3600)
        try await database.writer.write { db in
            try db.execute(
                sql: "INSERT INTO operation(kind, payload, state, createdAt) VALUES ('future', '{\"future\":{}}', 'pending', 0)")
        }
        try await outbox.enqueue([
            .favorite(fileId: 9, path: "/Photos/gone.jpg", value: true),  // 404: not transient
            .favorite(fileId: 2, path: "/Photos/b.jpg", value: true),
        ])
        await outbox.waitUntilIdle()
        #expect(try await outbox.pendingCount() == 0)
        #expect(server.file(2)?.favorite == true)
        #expect(try await outbox.failedOperations().map(\.operation) == [.favorite(fileId: 9, path: "/Photos/gone.jpg", value: true)])
        #expect(
            try await database.writer.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM operation WHERE state = 'failed'") } == 2
        )
    }
}

/// Bulk actions (side by side, one request where the index knows the file) and the undo of deletes (queued deletes are
/// taken back, deletes being sent are waited for). Waits for the outbox and for events, never for the clock.
@Suite(.timeLimit(.minutes(5))) struct OutboxBulkAndUndoTests {
    let server = FakeDAVServer()
    let database: AccountDatabase
    let library: LibraryStore
    let collections: CollectionStore
    let album = Album(kind: .own, name: "Trip")

    init() throws {
        database = try AccountDatabase.temporary()
        library = LibraryStore(database: database)
        collections = CollectionStore(database: database)
        for id in FileID(1)...8 {
            server.put(FakeDAVServer.File(id: id, path: "/Photos/\(id).jpg", etag: "e\(id)", modified: 1000, captured: 1000))
            try library.upsert([Self.item(id)])
        }
    }

    static func item(_ id: FileID) -> MediaItem {
        MediaItem(fileId: id, path: "/Photos/\(id).jpg", mimeType: "image/jpeg", etag: "e\(id)")
    }

    static func child(_ id: FileID) -> MediaParser.CollectionChild {
        MediaParser.CollectionChild(item: item(id), childName: "\(id)-\(id).jpg", origin: "user", ownerPath: "/Photos/\(id).jpg")
    }

    func outbox(retryDelay: TimeInterval = 3600, concurrency: Int = Outbox.defaultConcurrency) -> Outbox {
        Outbox(api: server.api, database: database, retryDelay: { _ in retryDelay }, concurrency: concurrency)
    }

    func albumFiles() throws -> [FileID] { try collections.albumItems(albumId: album.id).map(\.fileId) }

    // MARK: Bulk actions

    @Test func independentOperationsRunSideBySide() async throws {
        #expect(Outbox.defaultConcurrency == 5)  // SPEC §7.3
        // Three at a time here: the stubbed URL session may allow fewer connections than the app's own.
        let barrier = Barrier(opensAt: 3)
        server.gate.withLock { $0 = { request in if request.kind == .proppatch { await barrier.enter(request.path) } } }
        server.afterResponse.withLock { $0 = { request, _ in if request.kind == .proppatch { barrier.leave(request.path) } } }
        let outbox = outbox(concurrency: 3)
        // Six files, the first with two changes: those two must not overlap, nor run out of order.
        let operations: [PendingOperation] =
            [.favorite(fileId: 1, path: "/Photos/1.jpg", value: true), .favorite(fileId: 1, path: "/Photos/1.jpg", value: false)]
            + (2...6).map { .favorite(fileId: $0, path: "/Photos/\($0).jpg", value: true) }
        try await outbox.enqueue(operations)
        await outbox.waitUntilIdle()
        #expect(try await outbox.pendingCount() == 0)
        #expect(barrier.maximum == 3)
        #expect(!barrier.overlapped)
        #expect(server.file(1)?.favorite == false)
        #expect((2...6).allSatisfy { server.file($0)?.favorite == true })
    }

    /// Where the index knows the file's ETag, a delete or a move is one request: no lookup by id first.
    @Test func aKnownFileTakesOneRequest() async throws {
        let outbox = outbox()
        try await outbox.enqueue([.delete(fileId: 1, path: "/Photos/1.jpg"), .archive(fileId: 2, path: "/Photos/2.jpg")])
        await outbox.waitUntilIdle()
        #expect(try await outbox.pendingCount() == 0)
        #expect(try await outbox.failedOperations().isEmpty)
        #expect(server.requests.count == 2)
        #expect(server.requests(.delete).map(\.path) == ["/Photos/1.jpg"])
        #expect(server.requests(.move).map(\.path) == ["/Photos/2.jpg"])
        #expect(server.file(1) == nil)
        #expect(server.file(2)?.path == "/.archive/Photos/2.jpg")
        #expect(try library.item(2)?.path == "/.archive/Photos/2.jpg")

        server.clearRequests()
        try await outbox.enqueue([.unarchive(fileId: 2, path: "/.archive/Photos/2.jpg")])
        await outbox.waitUntilIdle()
        #expect(server.requests.map(\.kind) == [.move])
        #expect(server.file(2)?.path == "/Photos/2.jpg")
        #expect(try library.item(2)?.path == "/Photos/2.jpg")
    }

    /// Only 423 answers count towards giving up on a locked file, not the attempts that failed for another reason.
    @Test func otherFailuresDoNotCountTowardsGivingUpOnALockedFile() async throws {
        let answers = Mutex([Int](repeating: 503, count: Outbox.maxLockedAttempts + 2) + [423, 423, 423])
        server.statusOverride.withLock {
            $0 = { request in
                guard request.kind == .proppatch else { return nil }
                return answers.withLock { $0.isEmpty ? nil : $0.removeFirst() }
            }
        }
        let outbox = outbox(retryDelay: 0)
        try await outbox.enqueue([.favorite(fileId: 1, path: "/Photos/1.jpg", value: true)])
        await outbox.waitUntilIdle()
        #expect(try await outbox.pendingCount() == 0)
        #expect(try await outbox.failedOperations().isEmpty)
        #expect(server.file(1)?.favorite == true)
        #expect(server.requests(.proppatch).count == Outbox.maxLockedAttempts + 2 + 3 + 1)
    }

    // MARK: Album content

    /// Album content read from the server (a failed album operation, opening the album) keeps what is still queued.
    @Test func albumContentFromTheServerKeepsQueuedChanges() async throws {
        try collections.upsertAlbum(album)
        try collections.replaceAlbumContent(albumId: album.id, children: [Self.child(1), Self.child(2), Self.child(3)])
        server.setOffline(true)
        let outbox = outbox()
        try await outbox.enqueue([
            .removeFromAlbum(albumId: album.id, albumName: "Trip", albumKind: .own, fileId: 2, childName: "2-2.jpg"),
            .addToAlbum(albumId: album.id, albumName: "Trip", albumKind: .own, fileId: 4, path: "/Photos/4.jpg"),
            .delete(fileId: 3, path: "/Photos/3.jpg"),
        ])
        await outbox.waitUntilIdle()
        #expect(try albumFiles() == [1, 4])
        #expect(try collections.album(id: album.id)?.itemCount == 2)

        try collections.replaceAlbumContent(albumId: album.id, children: [Self.child(1), Self.child(2), Self.child(3)])
        #expect(try albumFiles() == [1, 4])
        #expect(try collections.album(id: album.id)?.itemCount == 2)
    }

    // MARK: Undo of deletes

    @Test func queuedDeletesAreTakenBack() async throws {
        try collections.upsertAlbum(album)
        try collections.replaceAlbumContent(albumId: album.id, children: [Self.child(1)])
        let rows = DeletedRows(items: [Self.item(1), Self.item(2)], albumItems: try collections.memberships(of: [1, 2]))
        let outbox = outbox()
        server.setOffline(true)
        try await outbox.enqueue([.delete(fileId: 1, path: "/Photos/1.jpg"), .delete(fileId: 2, path: "/Photos/2.jpg")])
        await outbox.waitUntilIdle()
        #expect(try library.item(1) == nil)
        #expect(try albumFiles().isEmpty)

        let outcome = await outbox.withdrawDeletes(of: [1, 2], restoring: rows)
        #expect(outcome == DeleteWithdrawal(withdrawn: [1, 2]))
        #expect(try library.item(1) != nil)
        #expect(try library.item(2) != nil)
        #expect(try albumFiles() == [1])
        #expect(try collections.album(id: album.id)?.itemCount == 1)
        #expect(try await outbox.pendingCount() == 0)

        // The connection comes back: nothing is deleted after all.
        server.setOffline(false)
        server.clearRequests()
        await outbox.kickNow()
        await outbox.waitUntilIdle()
        #expect(server.requests(.delete).isEmpty)
        #expect(server.file(1) != nil)
        #expect(server.file(2) != nil)
    }

    @Test func aDeleteBeingSentIsWaitedFor() async throws {
        let (arrivals, arrived) = AsyncStream<Void>.makeStream()
        let held = Mutex<CheckedContinuation<Void, Never>?>(nil)
        server.gate.withLock {
            $0 = { request in
                guard request.kind == .delete else { return }
                await withCheckedContinuation { continuation in
                    held.withLock { $0 = continuation }
                    arrived.yield()
                }
            }
        }
        // One at a time: the delete of file 2 is still queued while the one of file 1 is on its way.
        let outbox = outbox(concurrency: 1)
        try await outbox.enqueue([.delete(fileId: 1, path: "/Photos/1.jpg"), .delete(fileId: 2, path: "/Photos/2.jpg")])
        var events = arrivals.makeAsyncIterator()
        _ = await events.next()

        let withdrawal = Task { await outbox.withdrawDeletes(of: [1, 2], restoring: DeletedRows(items: [Self.item(1), Self.item(2)])) }
        while await outbox.finishWaiterCount == 0 { await Task.yield() }
        #expect(try library.item(2) != nil)  // taken back at once
        held.withLock {
            $0?.resume()
            $0 = nil
        }
        #expect(await withdrawal.value == DeleteWithdrawal(withdrawn: [2], deleted: [1]))
        await outbox.waitUntilIdle()
        #expect(try await outbox.pendingCount() == 0)
        #expect(server.file(1) == nil)
        #expect(server.file(2) != nil)
        #expect(try library.item(1) == nil)
        #expect(server.requests(.delete).count == 1)
    }

    /// A delete the server refused never deleted anything: it is not "deleted", and it leaves the failed operations.
    @Test func aRefusedDeleteIsNotCountedAsDeleted() async throws {
        server.statusOverride.withLock { $0 = { $0.kind == .delete ? 403 : nil } }
        let outbox = outbox()
        try await outbox.enqueue([.delete(fileId: 1, path: "/Photos/1.jpg")])
        await outbox.waitUntilIdle()
        #expect(try await outbox.failedOperations().count == 1)
        #expect(await outbox.withdrawDeletes(of: [1], restoring: DeletedRows(items: [Self.item(1)])) == DeleteWithdrawal(refused: [1]))
        #expect(try await outbox.failedOperations().isEmpty)
    }
}

/// Holds requests back until `opensAt` of them wait at the same time, then lets everything through. Records how many
/// ran at the same time and whether two for the same path did.
final class Barrier: Sendable {
    struct State {
        var running: [String] = []
        var maximum = 0
        var overlapped = false
        var waiting: [CheckedContinuation<Void, Never>] = []
        var isOpen = false
    }

    let opensAt: Int
    let state = Mutex(State())

    init(opensAt: Int) { self.opensAt = opensAt }

    var maximum: Int { state.withLock { $0.maximum } }
    var overlapped: Bool { state.withLock { $0.overlapped } }

    func enter(_ path: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let released: [CheckedContinuation<Void, Never>] = state.withLock { state in
                if state.running.contains(path) { state.overlapped = true }
                state.running.append(path)
                state.maximum = max(state.maximum, state.running.count)
                if state.isOpen { return [continuation] }
                state.waiting.append(continuation)
                guard state.waiting.count >= opensAt else { return [] }
                state.isOpen = true
                defer { state.waiting = [] }
                return state.waiting
            }
            for waiter in released { waiter.resume() }
        }
    }

    func leave(_ path: String) {
        state.withLock { state in
            if let index = state.running.firstIndex(of: path) { state.running.remove(at: index) }
        }
    }
}
