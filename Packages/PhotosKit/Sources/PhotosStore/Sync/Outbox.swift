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

    var kind: String {
        switch self {
        case .favorite: "favorite"
        case .delete: "delete"
        case .archive: "archive"
        case .unarchive: "unarchive"
        case .addToAlbum: "addToAlbum"
        case .removeFromAlbum: "removeFromAlbum"
        case .setMetadata: "setMetadata"
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
        }
    }
}

public struct FailedOperation: Sendable, Identifiable, Hashable {
    public var id: Int64
    public var operation: PendingOperation
    public var error: String
}

/// Executes pending operations with retries. Optimistic local changes are applied when enqueuing.
///
/// Operations run strictly in the order they were queued: while the oldest one waits for its retry, nothing behind it
/// runs (a later operation on the same file must never overtake an earlier one, and a transient error — offline,
/// server down — hits the others just the same). The outbox wakes itself up when the retry is due.
public actor Outbox {
    let api: PhotosAPI
    let library: LibraryStore
    let database: AccountDatabase
    private let logger = Logger(subsystem: "com.nextcloud.photos", category: "outbox")
    private var worker: Task<Void, Never>?
    /// Timer that kicks the outbox when the operation in backoff is due.
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
    static let archivePrefix = "/.archive"
    /// A locked file (423) is retried like a transient error, but not for ever: everything queued behind it waits.
    /// With the default delays this is about 40 minutes.
    static let maxLockedAttempts = 8

    public init(api: PhotosAPI, database: AccountDatabase, restore: (@Sendable () async -> Void)? = nil) {
        self.init(api: api, database: database, retryDelay: Self.defaultRetryDelay, restore: restore)
    }

    init(
        api: PhotosAPI, database: AccountDatabase, retryDelay: @escaping @Sendable (Int) -> TimeInterval,
        restore: (@Sendable () async -> Void)? = nil
    ) {
        self.api = api
        self.database = database
        self.library = LibraryStore(database: database)
        self.retryDelay = retryDelay
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
            for operation in operations {
                try Self.applyLocally(operation, db: db)
                let payload = String(data: try JSONEncoder().encode(operation), encoding: .utf8)!
                try db.execute(
                    sql: "INSERT INTO operation(kind, payload, state, createdAt) VALUES (?, ?, 'pending', ?)",
                    arguments: [operation.kind, payload, Date().timeIntervalSince1970])
            }
        }
        kick()
    }

    /// Starts processing if not already running. An operation waiting for its retry keeps waiting (and holds back the
    /// ones behind it); the outbox wakes itself up when it is due.
    public func kick() {
        guard worker == nil else { return }
        worker = Task { await self.drain() }
    }

    /// Retries now, without waiting for the backoff: call when the network came back.
    public func kickNow() {
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

    /// When the operation at the head of the queue is retried, if it is in backoff.
    public func nextRetryDate() throws -> Date? {
        try database.writer.read { db in
            try Double.fetchOne(db, sql: "SELECT nextAttemptAt FROM operation WHERE state = 'pending' ORDER BY id LIMIT 1")
        }.map { Date(timeIntervalSince1970: $0) }
    }

    /// File ids with operations that have not reached the server yet; a sync must not overwrite their local state.
    static func pendingFileIds(_ db: Database) throws -> Set<FileID> {
        let decoder = JSONDecoder()
        return Set(
            try String.fetchAll(db, sql: "SELECT payload FROM operation WHERE state = 'pending'").compactMap {
                (try? decoder.decode(PendingOperation.self, from: Data($0.utf8)))?.fileId
            })
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
            try db.execute(sql: "UPDATE operation SET state = 'pending', attempts = 0, nextAttemptAt = NULL WHERE state = 'failed'")
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
    /// of their albums. Best effort; the index rows are also restored by the next sync.
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

    private func drain() async {
        defer { worker = nil }
        cancelWakeUp()
        while !Task.isCancelled {
            let next: Next
            do {
                next = try nextOperation()
            } catch {
                logger.error("could not read the outbox: \(error.localizedDescription, privacy: .public)")
                return
            }
            let id: Int64
            let operation: PendingOperation
            let attempts: Int
            switch next {
            case .empty:
                return
            case .waiting(let date):
                // The oldest operation is in backoff: nothing may overtake it. Come back when it is due.
                scheduleWakeUp(at: date)
                return
            case .undecodable(let id):
                // Written by a newer app version or damaged; do not let it block the queue forever.
                await mark(id, failed: "Unknown operation")
                continue
            case .ready(let readyId, let readyOperation, let readyAttempts):
                (id, operation, attempts) = (readyId, readyOperation, readyAttempts)
            }
            do {
                try await execute(operation)
                try? await database.writer.write { db in try db.execute(sql: "DELETE FROM operation WHERE id = ?", arguments: [id]) }
            } catch  where Task.isCancelled {
                return  // shut down: the operation stays pending
            } catch let error as NetworkError where Self.shouldRetry(error, attempts: attempts) {
                // Back off and stop: later operations wait behind this one until it is retried (timer, network change).
                let date = Date().addingTimeInterval(retryDelay(attempts))
                try? await database.writer.write { db in
                    try db.execute(
                        sql: "UPDATE operation SET attempts = attempts + 1, lastError = ?, nextAttemptAt = ? WHERE id = ?",
                        arguments: [error.localizedDescription, date.timeIntervalSince1970, id])
                }
                scheduleWakeUp(at: date)
                return
            } catch let error as NetworkError where Self.isAlreadyDone(error, operation) {
                try? await database.writer.write { db in try db.execute(sql: "DELETE FROM operation WHERE id = ?", arguments: [id]) }
            } catch {
                logger.error("operation \(operation.kind, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                await mark(id, failed: error.localizedDescription, restoring: operation.fileId)
                // The change was shown as done and never will be: show what the server has.
                await undoLocalChanges(of: [operation])
            }
        }
    }

    /// Transient errors are retried for as long as it takes; a locked file only `maxLockedAttempts` times.
    static func shouldRetry(_ error: NetworkError, attempts: Int) -> Bool {
        guard error.isTransient else { return false }
        return error != .locked || attempts + 1 < maxLockedAttempts
    }

    private func mark(_ id: Int64, failed message: String, restoring fileId: FileID? = nil) async {
        try? await database.writer.write { db in
            try db.execute(sql: "UPDATE operation SET state = 'failed', lastError = ? WHERE id = ?", arguments: [message, id])
            if let fileId { try SyncEngine.requestRestore([fileId], db: db) }
        }
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

    private enum Next {
        case empty
        case ready(Int64, PendingOperation, attempts: Int)
        case waiting(until: Date)
        case undecodable(Int64)
    }

    /// The oldest pending operation, whether it is due or not: the queue never skips ahead of it.
    private func nextOperation() throws -> Next {
        try database.writer.read { db in
            guard
                let row = try Row.fetchOne(
                    db, sql: "SELECT id, payload, attempts, nextAttemptAt FROM operation WHERE state = 'pending' ORDER BY id LIMIT 1")
            else { return .empty }
            if let due: Double = row["nextAttemptAt"], due > Date().timeIntervalSince1970 {
                return .waiting(until: Date(timeIntervalSince1970: due))
            }
            let payload: String = row["payload"]
            guard let operation = try? JSONDecoder().decode(PendingOperation.self, from: Data(payload.utf8)) else {
                return .undecodable(row["id"])
            }
            return .ready(row["id"], operation, attempts: row["attempts"])
        }
    }

    /// Runs one operation on the server.
    ///
    /// The path in the payload is the one the file had when the operation was queued. By the time it runs the file may
    /// be elsewhere (an archive queued before it, a move made on another device), and the old path may belong to a
    /// different file. Deletes and moves therefore look the file up by its id first and act on the path the server
    /// reports; the other operations do so when the stored path is gone.
    func execute(_ operation: PendingOperation) async throws {
        switch operation {
        case .favorite(let fileId, let path, let value):
            try await atCurrentPath(fileId, path) { try await self.api.setFavorite(userPath: $0, value) }
        case .delete(let fileId, _):
            // No such file any more: deleted elsewhere, which is what was asked for.
            guard let current = try await api.currentPath(fileId: fileId) else { return }
            try await api.delete(userPath: current)
        case .archive(let fileId, _):
            guard let current = try await api.currentPath(fileId: fileId) else { throw NetworkError.notFound }
            let target = Self.isArchivePath(current) ? current : Self.archivePrefix + current
            if target != current { try await api.move(userPath: current, to: target) }
            try recordMove(fileId, to: target)
        case .unarchive(let fileId, _):
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
        }
    }

    static func isArchivePath(_ path: String) -> Bool { path.hasPrefix(archivePrefix + "/") }

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
            for row in try Row.fetchAll(db, sql: "SELECT id, payload FROM operation") {
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
            try db.execute(sql: "UPDATE album SET itemCount = itemCount + 1 WHERE id = ?", arguments: [albumId])
        case .removeFromAlbum(let albumId, _, _, let fileId, _):
            try db.execute(sql: "DELETE FROM albumItem WHERE albumId = ? AND fileId = ?", arguments: [albumId, fileId])
            try db.execute(sql: "UPDATE album SET itemCount = max(0, itemCount - 1) WHERE id = ?", arguments: [albumId])
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
        }
    }
}
