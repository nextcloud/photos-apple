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
@Suite struct OutboxTests {
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
            let seen = Mutex<[Bool]>([])
            let observation = Task {
                for try await item in library.observeItem(id) { seen.withLock { $0.append(item?.isFavorite ?? false) } }
            }
            defer { observation.cancel() }
            #expect(await eventually { seen.withLock { $0 } == [false] })
            try await outbox.enqueue([.favorite(fileId: id, path: "/x.jpg", value: true)])
            #expect(await eventually(timeout: 2) { seen.withLock { $0 } == [false, true] }, "file \(id)")
            #expect(try library.item(id)?.isFavorite == true)
            try await outbox.enqueue([.favorite(fileId: id, path: "/x.jpg", value: false)])
            #expect(await eventually(timeout: 2) { seen.withLock { $0 } == [false, true, false] }, "file \(id)")
        }
    }

    @Test func operationInBackoffIsNotOvertaken() async throws {
        let outbox = outbox(retryDelay: 3600)
        server.setOffline(true)
        try await outbox.enqueue([
            .favorite(fileId: 1, path: "/Photos/a.jpg", value: true), .favorite(fileId: 1, path: "/Photos/a.jpg", value: false),
            .favorite(fileId: 2, path: "/Photos/b.jpg", value: true),
        ])
        #expect(await eventually { try await outbox.nextRetryDate() != nil })
        #expect(favouriteWrites == ["/Photos/a.jpg=1"])
        #expect(try attempts() == [1, 0, 0])

        // The network is back, but the first operation is not due yet: a kick (as after a sync) must not run the
        // later ones ahead of it — the final state on the server would be "favourite" although the user undid it.
        server.setOffline(false)
        server.clearRequests()
        await outbox.kick()
        try await Task.sleep(for: .milliseconds(200))
        #expect(favouriteWrites.isEmpty)
        #expect(try await outbox.pendingCount() == 3)

        await outbox.kickNow()
        #expect(await eventually { try await outbox.pendingCount() == 0 })
        #expect(favouriteWrites == ["/Photos/a.jpg=1", "/Photos/a.jpg=0", "/Photos/b.jpg=1"])
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
        #expect(await eventually { try await outbox.nextRetryDate() != nil })
        let retry = try #require(try await outbox.nextRetryDate())
        #expect(retry.timeIntervalSince(enqueued) >= 0.3)
        server.setOffline(false)

        // Nobody kicks: the outbox's own timer does.
        #expect(await eventually { try await outbox.pendingCount() == 0 })
        #expect(Date() >= retry)
        #expect(favouriteWrites == ["/Photos/a.jpg=1", "/Photos/a.jpg=1", "/Photos/b.jpg=1"])
        #expect(try await outbox.nextRetryDate() == nil)
    }

    @Test func shutdownStopsTheRetryTimer() async throws {
        let outbox = outbox(retryDelay: 0.2)
        server.setOffline(true)
        try await outbox.enqueue([.favorite(fileId: 1, path: "/Photos/a.jpg", value: true)])
        #expect(await eventually { try await outbox.nextRetryDate() != nil })
        await outbox.shutdown()
        server.setOffline(false)
        server.clearRequests()

        // The retry would be due now; an outbox that was shut down does not wake itself up, and the operation stays pending.
        try await Task.sleep(for: .milliseconds(500))
        #expect(favouriteWrites.isEmpty)
        #expect(try await outbox.pendingCount() == 1)

        // It is not dead: an explicit kick runs it again.
        await outbox.kickNow()
        #expect(await eventually { try await outbox.pendingCount() == 0 })
    }

    @Test func keepsBackingOffWhileTheErrorPersists() async throws {
        let outbox = outbox(retryDelay: 0.05)
        server.setOffline(true)
        try await outbox.enqueue([.favorite(fileId: 1, path: "/Photos/a.jpg", value: true)])
        #expect(await eventually { (try attempts().first ?? 0) >= 3 })
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
        #expect(await eventually { try await outbox.nextRetryDate() != nil })
        server.setOffline(false)

        // The path monitor's first report of a working connection is not a change.
        await outbox.networkChanged(satisfied: true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await outbox.pendingCount() == 1)

        await outbox.networkChanged(satisfied: false)
        await outbox.networkChanged(satisfied: true)
        #expect(await eventually { try await outbox.pendingCount() == 0 })
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
        #expect(await eventually { try await outbox.pendingCount() == 0 })
        #expect(server.file(2)?.favorite == true)
        #expect(try await outbox.failedOperations().map(\.operation) == [.favorite(fileId: 9, path: "/Photos/gone.jpg", value: true)])
        #expect(
            try await database.writer.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM operation WHERE state = 'failed'") } == 2
        )
    }
}
