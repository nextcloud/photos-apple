// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import Network
import OSLog
import PhotosModel
import PhotosNetworking

/// A user write waiting to be applied on the server (SPEC §4.3 step 4).
public enum PendingOperation: Codable, Sendable, Hashable {
    case favorite(fileId: FileID, path: String, value: Bool)
    case delete(fileId: FileID, path: String)
    case archive(fileId: FileID, path: String)
    case unarchive(fileId: FileID, path: String)
    case addToAlbum(albumId: String, albumName: String, albumKind: AlbumKind, fileId: FileID, path: String)
    case removeFromAlbum(albumId: String, albumName: String, albumKind: AlbumKind, fileId: FileID, childName: String)
    case setMetadata(fileId: FileID, path: String, capturedAt: Date?, latitude: Double?, longitude: Double?, removeLocation: Bool)
    /// Adds or removes a system tag; self-contained in `TagChange`.
    case tag(TagChange)

    var kind: String {
        switch self {
        case .favorite: "favorite"
        case .delete: "delete"
        case .archive: "archive"
        case .unarchive: "unarchive"
        case .addToAlbum: "addToAlbum"
        case .removeFromAlbum: "removeFromAlbum"
        case .setMetadata: "setMetadata"
        case .tag: "tag"
        }
    }

    /// The same operation on the file at another path (the file was moved since the operation was queued).
    func withPath(_ newPath: String) -> PendingOperation {
        switch self {
        case .favorite(let fileId, _, let value): .favorite(fileId: fileId, path: newPath, value: value)
        case .delete(let fileId, _): .delete(fileId: fileId, path: newPath)
        case .archive(let fileId, _): .archive(fileId: fileId, path: newPath)
        case .unarchive(let fileId, _): .unarchive(fileId: fileId, path: newPath)
        case .addToAlbum(let albumId, let albumName, let albumKind, let fileId, _):
            .addToAlbum(albumId: albumId, albumName: albumName, albumKind: albumKind, fileId: fileId, path: newPath)
        case .removeFromAlbum: self  // addressed by the album's child name
        case .tag: self  // addressed by file id
        case .setMetadata(let fileId, _, let capturedAt, let latitude, let longitude, let removeLocation):
            .setMetadata(
                fileId: fileId, path: newPath, capturedAt: capturedAt, latitude: latitude, longitude: longitude,
                removeLocation: removeLocation)
        }
    }

    /// The album whose content the operation changes.
    var album: Album? {
        switch self {
        case .addToAlbum(_, let name, let kind, _, _), .removeFromAlbum(_, let name, let kind, _, _): Album(kind: kind, name: name)
        default: nil
        }
    }

    /// The file the operation changes.
    var fileId: FileID {
        switch self {
        case .favorite(let fileId, _, _), .delete(let fileId, _), .archive(let fileId, _), .unarchive(let fileId, _),
            .addToAlbum(_, _, _, let fileId, _), .removeFromAlbum(_, _, _, let fileId, _), .setMetadata(let fileId, _, _, _, _, _):
            fileId
        case .tag(let change): change.fileId
        }
    }
}

public struct FailedOperation: Sendable, Identifiable, Hashable {
    public var id: Int64
    public var operation: PendingOperation
    public var error: String
}

/// What a delete takes out of the local index (`Outbox.applyLocally`), kept so that taking the delete back before it ran
/// can put it back as it was.
public struct DeletedRows: Sendable, Equatable {
    /// The index rows of the photos (a photo outside the timeline has none).
    public var items: [MediaItem]
    /// Their places in albums.
    public var albumItems: [AlbumMembership]

    public init(items: [MediaItem] = [], albumItems: [AlbumMembership] = []) {
        self.items = items
        self.albumItems = albumItems
    }

    public var isEmpty: Bool { items.isEmpty && albumItems.isEmpty }
}

/// Where the deletes of a set of files stand once they were taken back (`Outbox.withdrawDeletes(of:restoring:)`).
public struct DeleteWithdrawal: Sendable, Equatable {
    /// Taken out of the queue before they reached the server; their rows are back.
    public var withdrawn: Set<FileID> = []
    /// Refused by the server for good: the files were never deleted, and their rows came back when the delete failed.
    public var refused: Set<FileID> = []
    /// Reached the server: the files are in its trash bin (or were deleted elsewhere already).
    public var deleted: Set<FileID> = []
    /// Withdrawn after an attempt that failed with a transient error (timed out, 5xx, offline): the server may have
    /// deleted the file all the same — an answer lost, an error after the move to the trash bin. A subset of
    /// `withdrawn`; undo looks for these in the trash bin too (SPEC §20.1).
    public var maybeSent: Set<FileID> = []

    public init(withdrawn: Set<FileID> = [], refused: Set<FileID> = [], deleted: Set<FileID> = [], maybeSent: Set<FileID> = []) {
        self.withdrawn = withdrawn
        self.refused = refused
        self.deleted = deleted
        self.maybeSent = maybeSent
    }
}

/// Executes pending operations with retries. Optimistic local changes are applied when enqueuing.
///
/// Up to `concurrency` operations are sent at the same time, but never two for the same file: an operation waits for every
/// operation queued before it for its file (a later favourite must never overtake an earlier one, a delete not the archive
/// before it). A connection problem (offline, timeout, server down) pauses the whole queue until the retry is due or the
/// network comes back; a locked file (423) only holds back the operations for that file. The outbox wakes itself up when a
/// retry is due.
public actor Outbox {
    let api: PhotosAPI
    let library: LibraryStore
    let database: AccountDatabase
    private let logger = Logger(subsystem: "com.nextcloud.photos", category: "outbox")
    private var worker: Task<Void, Never>?
    /// `kick()` came while the worker was finishing: it looks for work once more before it stops.
    private var lookAgain = false
    /// The operations being sent, by id.
    private var inFlight: [Int64: PendingOperation] = [:]
    /// Waiting for an operation in flight to finish (`withdrawDeletes`).
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    /// Files whose DELETE request went out in this process (`DeleteWithdrawal.maybeSent`); cleared when their delete
    /// is done. After a relaunch a failed attempt counts as not sent: undo then only puts the row back, as before.
    private var deleteRequestsSent: Set<FileID> = []
    /// A connection problem: no operation starts before this.
    private var pausedUntil: Date?
    /// Timer that kicks the outbox when the next retry is due.
    private var wakeUp: Task<Void, Never>?
    /// When `wakeUp` fires.
    private var wakeUpDate: Date?
    private var pathMonitor: NWPathMonitor?
    private var isNetworkSatisfied: Bool?
    /// Seconds to wait before the next attempt, given the number of failed attempts so far.
    let retryDelay: @Sendable (Int) -> TimeInterval
    /// Reads the rows marked with `SyncEngine.requestRestore` from the server (`SyncEngine.restoreRows`). Without it
    /// (or when it fails) the next sync does.
    let restore: (@Sendable () async -> Void)?
    /// Operations sent at the same time (SPEC §7.3: bulk operations run with at most 5 concurrent requests).
    let concurrency: Int
    static let defaultConcurrency = 5
    static let archivePrefix = "/.archive"
    /// A locked file (423) is retried like a transient error, but not for ever: the operations for that file wait behind
    /// it. Only 423 answers count (not attempts that failed offline); with the default delays this is about 20 minutes.
    static let maxLockedAttempts = 8

    public init(api: PhotosAPI, database: AccountDatabase, restore: (@Sendable () async -> Void)? = nil) {
        self.init(api: api, database: database, retryDelay: Self.defaultRetryDelay, restore: restore)
    }

    init(
        api: PhotosAPI, database: AccountDatabase, retryDelay: @escaping @Sendable (Int) -> TimeInterval,
        concurrency: Int = Outbox.defaultConcurrency, restore: (@Sendable () async -> Void)? = nil
    ) {
        self.api = api
        self.database = database
        self.library = LibraryStore(database: database)
        self.retryDelay = retryDelay
        self.concurrency = max(1, concurrency)
        self.restore = restore
    }

    deinit {
        wakeUp?.cancel()
        pathMonitor?.cancel()
    }

    /// 10 s, 20 s, 40 s … capped at one hour.
    static func defaultRetryDelay(attempts: Int) -> TimeInterval {
        min(3600, pow(2, Double(min(attempts, 20))) * 10)
    }

    public func enqueue(_ operations: [PendingOperation]) throws {
        try database.writer.write { db in
            let encoder = JSONEncoder()
            for operation in operations {
                // Read before the optimistic change: a delete takes the row away.
                let etag = try Self.knownETag(of: operation, db: db)
                try Self.applyLocally(operation, db: db)
                let payload = String(decoding: try encoder.encode(operation), as: UTF8.self)
                try db.execute(
                    sql: "INSERT INTO operation(kind, payload, state, createdAt, fileId, etag) VALUES (?, ?, 'pending', ?, ?, ?)",
                    arguments: [operation.kind, payload, Date().timeIntervalSince1970, operation.fileId, etag])
            }
        }
        kick()
    }

    /// The ETag the index has for the file a delete or move addresses (`execute`).
    static func knownETag(of operation: PendingOperation, db: Database) throws -> String? {
        switch operation {
        case .delete, .archive, .unarchive:
            let etag = try String.fetchOne(db, sql: "SELECT etag FROM media WHERE fileId = ?", arguments: [operation.fileId])
            return etag?.isEmpty == false ? etag : nil
        default:
            return nil
        }
    }

    /// Starts processing if not already running. Operations waiting for their retry keep waiting; the outbox wakes
    /// itself up when one is due.
    public func kick() {
        guard worker == nil else {
            lookAgain = true
            return
        }
        worker = Task { await self.drain() }
    }

    /// Retries now, without waiting for the backoff: call when the network came back.
    public func kickNow() {
        pausedUntil = nil
        try? database.writer.write { db in
            try db.execute(sql: "UPDATE operation SET nextAttemptAt = NULL WHERE state = 'pending' AND nextAttemptAt IS NOT NULL")
        }
        kick()
    }

    /// Watches the network path and retries as soon as a connection is back. Stops with `stopNetworkMonitoring()` or
    /// when the outbox goes away.
    public func startNetworkMonitoring() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { await self?.networkChanged(satisfied: satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "com.nextcloud.photos.outbox.path"))
        pathMonitor = monitor
    }

    public func stopNetworkMonitoring() {
        pathMonitor?.cancel()
        pathMonitor = nil
        isNetworkSatisfied = nil
    }

    /// Kicks on a change to a usable path (not on the monitor's first report of an already working connection).
    func networkChanged(satisfied: Bool) {
        let previous = isNetworkSatisfied
        isNetworkSatisfied = satisfied
        if satisfied, previous == false { kickNow() }
    }

    /// When the next retry is due, if operations wait for one.
    public func nextRetryDate() throws -> Date? {
        try database.writer.read { db in
            try Double.fetchOne(db, sql: "SELECT min(nextAttemptAt) FROM operation WHERE state = 'pending'")
        }.map { Date(timeIntervalSince1970: $0) }
    }

    /// File ids with operations that have not reached the server yet; a sync must not overwrite their local state.
    static func pendingFileIds(_ db: Database) throws -> Set<FileID> {
        Set(try FileID.fetchAll(db, sql: "SELECT DISTINCT fileId FROM operation WHERE state = 'pending' AND fileId IS NOT NULL"))
    }

    /// Stops the worker and waits until it has stopped; an interrupted operation stays pending (account switch, removal).
    /// The retry timer and the network monitor are stopped too, so nothing kicks the outbox again by itself. An explicit
    /// `kick()` or `enqueue` afterwards starts it again.
    public func shutdown() async {
        stopNetworkMonitoring()
        cancelWakeUp()
        worker?.cancel()
        await worker?.value
        // The worker may have scheduled a retry before it saw the cancellation.
        cancelWakeUp()
    }

    /// Returns once the outbox has done everything it does by itself within `horizon` seconds: no operation is running
    /// and no retry falls due by then. The operations still pending wait for a later retry.
    ///
    /// For tests: waiting for the outbox, instead of polling it against the clock, holds however slowly the machine runs.
    func waitUntilIdle(retriesDueWithin horizon: TimeInterval = 0) async {
        while true {
            if let worker {
                await worker.value
            } else if let wakeUp, let wakeUpDate, wakeUpDate <= Date().addingTimeInterval(horizon) {
                await wakeUp.value
                // A timer that ended without kicking (cancelled) is done with.
                if self.wakeUp == wakeUp, worker == nil { return }
            } else {
                return
            }
        }
    }

    public func failedOperations() throws -> [FailedOperation] {
        try database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT id, payload, lastError FROM operation WHERE state = 'failed' ORDER BY id").compactMap { row in
                guard let data = (row["payload"] as String).data(using: .utf8),
                    let operation = try? JSONDecoder().decode(PendingOperation.self, from: data)
                else { return nil }
                return FailedOperation(id: row["id"], operation: operation, error: row["lastError"] ?? "")
            }
        }
    }

    /// Queues the failed operations again. Their optimistic changes were undone when they failed, so they are applied again.
    public func retryFailed() throws {
        try database.writer.write { db in
            for row in try Row.fetchAll(db, sql: "SELECT payload FROM operation WHERE state = 'failed' ORDER BY id") {
                guard let operation = try? JSONDecoder().decode(PendingOperation.self, from: Data((row["payload"] as String).utf8))
                else { continue }
                try Self.applyLocally(operation, db: db)
            }
            try db.execute(
                sql:
                    "UPDATE operation SET state = 'pending', attempts = 0, lockedAttempts = 0, nextAttemptAt = NULL WHERE state = 'failed'")
        }
        kick()
    }

    /// Drops the failed operations. What they had changed locally is read from the server again.
    public func discardFailed() async throws {
        let discarded: [PendingOperation] = try await database.writer.write { db in
            let operations = try String.fetchAll(db, sql: "SELECT payload FROM operation WHERE state = 'failed'").compactMap {
                try? JSONDecoder().decode(PendingOperation.self, from: Data($0.utf8))
            }
            try db.execute(sql: "DELETE FROM operation WHERE state = 'failed'")
            try SyncEngine.requestRestore(operations.map(\.fileId), db: db)
            return operations
        }
        await undoLocalChanges(of: discarded)
    }

    /// Brings back the server's state for operations that will not run: the index rows of their files and the content
    /// of their albums (with what is still queued for them applied again). Best effort; the index rows are also restored
    /// by the next sync.
    private func undoLocalChanges(of operations: [PendingOperation]) async {
        guard !operations.isEmpty else { return }
        await restore?()
        let collections = CollectionStore(database: database)
        for album in Set(operations.compactMap(\.album)) {
            guard let children = try? await api.albumContent(album) else { continue }
            try? collections.replaceAlbumContent(albumId: album.id, children: children)
        }
    }

    public func pendingCount() throws -> Int {
        try database.writer.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM operation WHERE state = 'pending'") ?? 0 }
    }

    // MARK: Undo of deletes

    /// Takes back the deletes of these files (Undo, SPEC §7.3). Deletes that have not started are taken out of the queue
    /// and the rows they removed are put back (`rows`, as they were before the delete); deletes being sent are waited
    /// for. A delete that failed for good is dropped from the failed operations: the file was never deleted.
    public func withdrawDeletes(of fileIds: Set<FileID>, restoring rows: DeletedRows) async -> DeleteWithdrawal {
        var result = DeleteWithdrawal()
        var open = fileIds
        while !open.isEmpty {
            let sending = Set(inFlight.values.filter { $0.kind == "delete" }.map(\.fileId)).intersection(open)
            do {
                let (withdrawn, refused) = try takeBackDeletes(of: open.subtracting(sending), restoring: rows)
                result.withdrawn.formUnion(withdrawn)
                result.refused.formUnion(refused)
                // Their DELETE went out before, and failed: the server may have done it all the same.
                result.maybeSent.formUnion(withdrawn.intersection(deleteRequestsSent))
                open.subtract(withdrawn.union(refused))
            } catch {
                logger.error("could not take back queued deletes: \(error.localizedDescription, privacy: .public)")
                break
            }
            // Wait for the answer to the deletes being sent, then look again: a transient error puts one back in the queue.
            guard !sending.isEmpty else { break }
            await withCheckedContinuation { finishWaiters.append($0) }
        }
        result.deleted = fileIds.subtracting(result.withdrawn).subtracting(result.refused)
        return result
    }

    /// `takeBackDeletes(of:restoring:db:)` without leaving the actor: no operation can start in between.
    private func takeBackDeletes(of fileIds: Set<FileID>, restoring rows: DeletedRows) throws -> (
        withdrawn: Set<FileID>, refused: Set<FileID>
    ) {
        try database.writer.write { db in try Self.takeBackDeletes(of: fileIds, restoring: rows, db: db) }
    }

    /// Callers of `withdrawDeletes` waiting for a delete being sent (tests).
    var finishWaiterCount: Int { finishWaiters.count }

    /// Removes the delete operations (pending or failed) of these files and puts back the rows of the pending ones.
    static func takeBackDeletes(of fileIds: Set<FileID>, restoring rows: DeletedRows, db: Database) throws -> (
        withdrawn: Set<FileID>, refused: Set<FileID>
    ) {
        var withdrawn: Set<FileID> = []
        var refused: Set<FileID> = []
        let ids = fileIds.sorted()
        for start in stride(from: 0, to: ids.count, by: 500) {
            let chunk = Array(ids[start..<min(start + 500, ids.count)])
            let rows = try Row.fetchAll(
                db,
                sql:
                    "SELECT id, fileId, state FROM operation WHERE kind = 'delete' AND fileId IN (\(databaseQuestionMarks(count: chunk.count)))",
                arguments: StatementArguments(chunk))
            for row in rows {
                let fileId: FileID = row["fileId"]
                if (row["state"] as String) == "pending" { withdrawn.insert(fileId) } else { refused.insert(fileId) }
                let id: Int64 = row["id"]
                try db.execute(sql: "DELETE FROM operation WHERE id = ?", arguments: [id])
            }
        }
        refused.subtract(withdrawn)
        for item in rows.items where withdrawn.contains(item.fileId) {
            try item.insert(db, onConflict: .ignore)
        }
        for member in rows.albumItems where withdrawn.contains(member.fileId) {
            try CollectionStore.insert(member, db: db)
        }
        return (withdrawn, refused)
    }

    // MARK: Worker

    private func drain() async {
        defer { worker = nil }
        cancelWakeUp()
        var readable = true
        repeat {
            lookAgain = false
            readable = await runReadyOperations()
        } while readable && lookAgain && !Task.isCancelled
        if readable && !Task.isCancelled { scheduleNextWakeUp() }
    }

    /// Sends what is due, up to `concurrency` operations at a time, until nothing more is. False when the queue could
    /// not be read.
    private func runReadyOperations() async -> Bool {
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            while !Task.isCancelled {
                if running < concurrency {
                    let ready: [Ready]
                    do {
                        ready = try readyOperations(limit: concurrency - running)
                    } catch {
                        logger.error("could not read the outbox: \(error.localizedDescription, privacy: .public)")
                        return false
                    }
                    for operation in ready {
                        inFlight[operation.id] = operation.operation
                        running += 1
                        group.addTask { await self.run(operation) }
                    }
                }
                guard running > 0 else { return true }
                await group.next()
                running -= 1
            }
            return true
        }
    }

    private struct Ready: Sendable {
        var id: Int64
        var operation: PendingOperation
        var attempts: Int
        var lockedAttempts: Int
        var etag: String?
    }

    /// The operations that may start now, oldest first: due, not being sent, and the oldest pending operation for their
    /// file. Nothing while the queue is paused.
    private func readyOperations(limit: Int) throws -> [Ready] {
        guard limit > 0 else { return [] }
        if let pausedUntil {
            if pausedUntil > Date() { return [] }
            self.pausedUntil = nil
        }
        let sending = Set(inFlight.keys)
        return try database.writer.write { db in
            let decoder = JSONDecoder()
            var ready: [Ready] = []
            while true {
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, payload, attempts, lockedAttempts, etag FROM operation o
                        WHERE state = 'pending' AND (nextAttemptAt IS NULL OR nextAttemptAt <= ?)
                            AND NOT EXISTS (SELECT 1 FROM operation p WHERE p.fileId = o.fileId AND p.id < o.id AND p.state = 'pending')
                        ORDER BY id LIMIT ?
                        """,
                    arguments: [Date().timeIntervalSince1970, limit + sending.count])
                var unknown = false
                for row in rows where ready.count < limit {
                    let id: Int64 = row["id"]
                    guard !sending.contains(id) else { continue }
                    guard let operation = try? decoder.decode(PendingOperation.self, from: Data((row["payload"] as String).utf8)) else {
                        // Written by a newer app version or damaged; it must not stay in the queue for ever.
                        try db.execute(
                            sql: "UPDATE operation SET state = 'failed', lastError = ? WHERE id = ?", arguments: ["Unknown operation", id])
                        unknown = true
                        continue
                    }
                    ready.append(
                        Ready(
                            id: id, operation: operation, attempts: row["attempts"], lockedAttempts: row["lockedAttempts"],
                            etag: row["etag"]))
                }
                // Rows that were set aside as unknown leave room for others.
                if !unknown || ready.count >= limit { return ready }
            }
        }
    }

    /// Sends one operation and records the outcome.
    private func run(_ ready: Ready) async {
        defer { finished(ready.id) }
        let operation = ready.operation
        do {
            try await execute(operation, etag: ready.etag)
            remove(ready.id)
            if case .delete(let fileId, _) = operation { deleteRequestsSent.remove(fileId) }
        } catch  where Task.isCancelled {
            return  // shut down: the operation stays pending
        } catch let error as NetworkError where Self.shouldRetry(error, lockedAttempts: ready.lockedAttempts) {
            backOff(ready, after: error)
        } catch let error as NetworkError where Self.isAlreadyDone(error, operation) {
            remove(ready.id)
        } catch {
            logger.error("operation \(operation.kind, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            let message = error.localizedDescription
            try? await database.writer.write { db in
                try db.execute(sql: "UPDATE operation SET state = 'failed', lastError = ? WHERE id = ?", arguments: [message, ready.id])
                try SyncEngine.requestRestore([operation.fileId], db: db)
            }
            // The change was shown as done and never will be: show what the server has.
            await undoLocalChanges(of: [operation])
        }
    }

    private func remove(_ id: Int64) {
        try? database.writer.write { db in try db.execute(sql: "DELETE FROM operation WHERE id = ?", arguments: [id]) }
    }

    private func finished(_ id: Int64) {
        inFlight[id] = nil
        let waiters = finishWaiters
        finishWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    /// Schedules the retry. A connection problem hits every operation alike and pauses the queue; a locked file only
    /// holds back the operations for that file, and only its 423 answers count towards giving up.
    private func backOff(_ ready: Ready, after error: NetworkError) {
        let date = Date().addingTimeInterval(retryDelay(ready.attempts))
        let locked = error == .locked
        try? database.writer.write { db in
            try db.execute(
                sql:
                    "UPDATE operation SET attempts = attempts + 1, lockedAttempts = lockedAttempts + ?, lastError = ?, nextAttemptAt = ? WHERE id = ?",
                arguments: [locked ? 1 : 0, error.localizedDescription, date.timeIntervalSince1970, ready.id])
        }
        guard !locked else { return }
        if let pausedUntil, pausedUntil > Date() {
            self.pausedUntil = min(pausedUntil, date)
        } else {
            pausedUntil = date
        }
    }

    /// Transient errors are retried for as long as it takes; a locked file only `maxLockedAttempts` times.
    static func shouldRetry(_ error: NetworkError, lockedAttempts: Int) -> Bool {
        guard error.isTransient else { return false }
        return error != .locked || lockedAttempts + 1 < maxLockedAttempts
    }

    /// Sets the timer for the next retry that can run: the end of a pause, or the earliest retry of an operation that
    /// nothing queued before it for its file holds back.
    private func scheduleNextWakeUp() {
        if let pausedUntil, pausedUntil > Date() {
            scheduleWakeUp(at: pausedUntil)
            return
        }
        let next = try? database.writer.read { db in
            try Double.fetchOne(
                db,
                sql: """
                    SELECT min(nextAttemptAt) FROM operation o WHERE state = 'pending' AND nextAttemptAt IS NOT NULL
                        AND NOT EXISTS (SELECT 1 FROM operation p WHERE p.fileId = o.fileId AND p.id < o.id AND p.state = 'pending')
                    """)
        }
        if let next = next ?? nil { scheduleWakeUp(at: Date(timeIntervalSince1970: next)) }
    }

    private func scheduleWakeUp(at date: Date) {
        wakeUp?.cancel()
        wakeUpDate = date
        let delay = max(0, date.timeIntervalSinceNow)
        wakeUp = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.kick()
        }
    }

    private func cancelWakeUp() {
        wakeUp?.cancel()
        wakeUp = nil
        wakeUpDate = nil
    }

    /// 404 on delete (deleted between the lookup and the request) or 409 on album add mean the server already has the
    /// desired state.
    static func isAlreadyDone(_ error: NetworkError, _ operation: PendingOperation) -> Bool {
        switch (operation, error) {
        case (.delete, .notFound), (.removeFromAlbum, .notFound), (.addToAlbum, .conflict): true
        default: false
        }
    }

    /// Runs one operation on the server.
    ///
    /// The path in the payload is the one the file had when the operation was queued. By the time it runs the file may
    /// be elsewhere (an archive queued before it, a move made on another device), and the old path may belong to a
    /// different file. Deletes and moves therefore only act on the stored path when the file there still has the ETag
    /// the index knows (`If-Match`, one request); otherwise they look the file up by its id and act on the path the
    /// server reports. The other operations do so when the stored path is gone.
    func execute(_ operation: PendingOperation, etag: String? = nil) async throws {
        switch operation {
        case .favorite(let fileId, let path, let value):
            try await atCurrentPath(fileId, path) { try await self.api.setFavorite(userPath: $0, value) }
        case .delete(let fileId, let path):
            if let etag,
                try await sendingDelete(
                    fileId, { try await self.ifUnchanged({ try await self.api.delete(userPath: path, ifMatch: etag) }) })
            {
                return
            }
            // No such file any more: deleted elsewhere, which is what was asked for.
            guard let current = try await api.currentPath(fileId: fileId) else { return }
            try await sendingDelete(fileId) { try await self.api.delete(userPath: current) }
        case .archive(let fileId, let path):
            if let etag, !Self.isArchivePath(path) {
                let target = Self.archivePrefix + path
                if try await ifUnchanged({ try await self.api.move(userPath: path, to: target, ifMatch: etag) }) {
                    try recordMove(fileId, to: target)
                    return
                }
            }
            guard let current = try await api.currentPath(fileId: fileId) else { throw NetworkError.notFound }
            let target = Self.isArchivePath(current) ? current : Self.archivePrefix + current
            if target != current { try await api.move(userPath: current, to: target) }
            try recordMove(fileId, to: target)
        case .unarchive(let fileId, let path):
            if let etag, Self.isArchivePath(path) {
                let target = String(path.dropFirst(Self.archivePrefix.count))
                if try await ifUnchanged({ try await self.api.move(userPath: path, to: target, ifMatch: etag) }) {
                    try recordMove(fileId, to: target)
                    return
                }
            }
            guard let current = try await api.currentPath(fileId: fileId) else { throw NetworkError.notFound }
            let target = Self.isArchivePath(current) ? String(current.dropFirst(Self.archivePrefix.count)) : current
            if target != current { try await api.move(userPath: current, to: target) }
            try recordMove(fileId, to: target)
        case .addToAlbum(_, let name, let kind, let fileId, let path):
            try await atCurrentPath(fileId, path) { try await self.api.addToAlbum(Album(kind: kind, name: name), userPath: $0) }
        case .removeFromAlbum(_, let name, let kind, _, let childName):
            try await api.removeFromAlbum(Album(kind: kind, name: name), childName: childName)
        case .setMetadata(let fileId, let path, let capturedAt, let latitude, let longitude, let removeLocation):
            try await atCurrentPath(fileId, path) {
                try await self.api.setMetadata(
                    userPath: $0, capturedAt: capturedAt, latitude: latitude, longitude: longitude, removeLocation: removeLocation)
            }
        case .tag(let change):
            try await change.execute(api: api)
        }
    }

    static func isArchivePath(_ path: String) -> Bool { path.hasPrefix(archivePrefix + "/") }

    /// Sends a request that carries `If-Match`. False when the file at the path is not the one with that ETag (any more):
    /// it was moved, changed or replaced, and has to be looked up by its id.
    /// Sends a DELETE and remembers that it went out (`DeleteWithdrawal.maybeSent`), unless the device was offline:
    /// then nothing reached the server.
    private func sendingDelete<T>(_ fileId: FileID, _ request: () async throws -> T) async throws -> T {
        let sentBefore = deleteRequestsSent.contains(fileId)
        deleteRequestsSent.insert(fileId)
        do {
            return try await request()
        } catch NetworkError.offline {
            if !sentBefore { deleteRequestsSent.remove(fileId) }
            throw NetworkError.offline
        }
    }

    private func ifUnchanged(_ request: () async throws -> Void) async throws -> Bool {
        do {
            try await request()
            return true
        } catch NetworkError.preconditionFailed {
            return false
        } catch NetworkError.notFound {
            return false
        }
    }

    /// Runs `body` with the stored path and, when the server has nothing there, once more with the path the file has now.
    private func atCurrentPath(_ fileId: FileID, _ path: String, _ body: (String) async throws -> Void) async throws {
        do {
            try await body(path)
        } catch NetworkError.notFound {
            guard let current = try await api.currentPath(fileId: fileId), current != path else { throw NetworkError.notFound }
            try await body(current)
        }
    }

    /// The file is at a new path: the index row and every operation still queued for the file follow.
    private func recordMove(_ fileId: FileID, to path: String) throws {
        try database.writer.write { db in
            if var item = try MediaItem.fetchOne(db, key: fileId), item.path != path {
                item.path = path
                try item.update(db)
            }
            let decoder = JSONDecoder()
            let encoder = JSONEncoder()
            for row in try Row.fetchAll(db, sql: "SELECT id, payload FROM operation WHERE fileId = ?", arguments: [fileId]) {
                guard let operation = try? decoder.decode(PendingOperation.self, from: Data((row["payload"] as String).utf8)),
                    operation.fileId == fileId
                else { continue }
                let moved = operation.withPath(path)
                guard moved != operation else { continue }
                let id: Int64 = row["id"]
                try db.execute(
                    sql: "UPDATE operation SET payload = ? WHERE id = ?",
                    arguments: [String(decoding: try encoder.encode(moved), as: UTF8.self), id])
            }
        }
    }

    /// The album changes still queued (adds, removals, deletes of its photos), applied again on top of album content just
    /// read from the server: until they ran, the server's content does not show them.
    static func reapplyPendingAlbumChanges(albumId: String, db: Database) throws {
        let decoder = JSONDecoder()
        let payloads = try String.fetchAll(
            db,
            sql: "SELECT payload FROM operation WHERE state = 'pending' AND kind IN ('addToAlbum', 'removeFromAlbum', 'delete') ORDER BY id"
        )
        for payload in payloads {
            guard let operation = try? decoder.decode(PendingOperation.self, from: Data(payload.utf8)) else { continue }
            switch operation {
            case .addToAlbum(let id, _, _, _, _) where id == albumId, .removeFromAlbum(let id, _, _, _, _) where id == albumId:
                try applyLocally(operation, db: db)
            case .delete(let fileId, _):
                try db.execute(sql: "DELETE FROM albumItem WHERE albumId = ? AND fileId = ?", arguments: [albumId, fileId])
                if db.changesCount > 0 {
                    try db.execute(sql: "UPDATE album SET itemCount = max(0, itemCount - 1) WHERE id = ?", arguments: [albumId])
                }
            default:
                break
            }
        }
    }

    /// Optimistic local effect.
    static func applyLocally(_ operation: PendingOperation, db: Database) throws {
        switch operation {
        case .favorite(let fileId, _, let value):
            try db.execute(sql: "UPDATE media SET isFavorite = ? WHERE fileId = ?", arguments: [value, fileId])
            // Photos of albums shared with the user are only in `collectionMedia`.
            if var record = try CollectionMediaRecord.fetchOne(db, key: fileId) {
                record.item.isFavorite = value
                try record.update(db)
            }
        case .delete(let fileId, _):
            try db.execute(sql: "DELETE FROM media WHERE fileId = ?", arguments: [fileId])
            try db.execute(
                sql: "UPDATE album SET itemCount = max(0, itemCount - 1) WHERE id IN (SELECT albumId FROM albumItem WHERE fileId = ?)",
                arguments: [fileId])
            try db.execute(sql: "DELETE FROM albumItem WHERE fileId = ?", arguments: [fileId])
        case .archive(let fileId, _):
            try db.execute(sql: "UPDATE media SET isArchived = 1 WHERE fileId = ?", arguments: [fileId])
        case .unarchive(let fileId, _):
            try db.execute(sql: "UPDATE media SET isArchived = 0 WHERE fileId = ?", arguments: [fileId])
        case .addToAlbum(let albumId, _, _, let fileId, let path):
            let name = (path as NSString).lastPathComponent
            try db.execute(
                sql:
                    "INSERT OR IGNORE INTO albumItem(albumId, fileId, childName, origin, ownerPath, position) VALUES (?, ?, ?, 'user', ?, (SELECT coalesce(max(position), 0) + 1 FROM albumItem WHERE albumId = ?))",
                arguments: [albumId, fileId, "\(fileId)-\(name)", path, albumId])
            // Already in the album: nothing changes (the server answers 409, which counts as done).
            if db.changesCount > 0 {
                try db.execute(sql: "UPDATE album SET itemCount = itemCount + 1 WHERE id = ?", arguments: [albumId])
            }
        case .removeFromAlbum(let albumId, _, _, let fileId, _):
            try db.execute(sql: "DELETE FROM albumItem WHERE albumId = ? AND fileId = ?", arguments: [albumId, fileId])
            if db.changesCount > 0 {
                try db.execute(sql: "UPDATE album SET itemCount = max(0, itemCount - 1) WHERE id = ?", arguments: [albumId])
            }
        case .setMetadata(let fileId, _, let capturedAt, let latitude, let longitude, let removeLocation):
            if let capturedAt {
                try db.execute(
                    sql: "UPDATE media SET capturedAt = ? WHERE fileId = ?", arguments: [capturedAt.timeIntervalSince1970, fileId])
            }
            if removeLocation {
                try db.execute(
                    sql: "UPDATE media SET latitude = NULL, longitude = NULL, place = NULL WHERE fileId = ?", arguments: [fileId])
            } else if let latitude, let longitude {
                try db.execute(
                    sql: "UPDATE media SET latitude = ?, longitude = ? WHERE fileId = ?", arguments: [latitude, longitude, fileId])
            }
        case .tag(let change):
            try change.applyLocally(db: db)
        }
    }
}
