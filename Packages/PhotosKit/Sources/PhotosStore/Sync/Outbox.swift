// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
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
}

public struct FailedOperation: Sendable, Identifiable, Hashable {
    public var id: Int64
    public var operation: PendingOperation
    public var error: String
}

/// Executes pending operations with retries. Optimistic local changes are applied when enqueuing.
public actor Outbox {
    let api: PhotosAPI
    let library: LibraryStore
    let database: AccountDatabase
    private let logger = Logger(subsystem: "com.nextcloud.photos", category: "outbox")
    private var worker: Task<Void, Never>?
    static let archivePrefix = "/.archive"

    public init(api: PhotosAPI, database: AccountDatabase) {
        self.api = api
        self.database = database
        self.library = LibraryStore(database: database)
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

    /// Starts processing if not already running.
    public func kick() {
        guard worker == nil else { return }
        worker = Task { await self.drain() }
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

    public func retryFailed() throws {
        try database.writer.write { db in
            try db.execute(sql: "UPDATE operation SET state = 'pending', attempts = 0, nextAttemptAt = NULL WHERE state = 'failed'")
        }
        kick()
    }

    public func discardFailed() throws {
        try database.writer.write { db in try db.execute(sql: "DELETE FROM operation WHERE state = 'failed'") }
    }

    public func pendingCount() throws -> Int {
        try database.writer.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM operation WHERE state = 'pending'") ?? 0 }
    }

    private func drain() async {
        defer { worker = nil }
        while true {
            guard let (id, operation, attempts) = (try? nextOperation()) ?? nil else { return }
            do {
                try await execute(operation)
                try? await database.writer.write { db in try db.execute(sql: "DELETE FROM operation WHERE id = ?", arguments: [id]) }
            } catch let error as NetworkError where error.isTransient {
                // Back off; stop draining until kicked again (network change, foreground, sync).
                let delay = min(3600, pow(2, Double(attempts)) * 10)
                try? await database.writer.write { db in
                    try db.execute(
                        sql: "UPDATE operation SET attempts = attempts + 1, lastError = ?, nextAttemptAt = ? WHERE id = ?",
                        arguments: [error.localizedDescription, Date().timeIntervalSince1970 + delay, id])
                }
                return
            } catch let error as NetworkError where Self.isAlreadyDone(error, operation) {
                try? await database.writer.write { db in try db.execute(sql: "DELETE FROM operation WHERE id = ?", arguments: [id]) }
            } catch {
                logger.error("operation \(operation.kind, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                try? await database.writer.write { db in
                    try db.execute(
                        sql: "UPDATE operation SET state = 'failed', lastError = ? WHERE id = ?",
                        arguments: [error.localizedDescription, id])
                }
            }
        }
    }

    /// 404 on delete or 409 on album add mean the server already has the desired state.
    static func isAlreadyDone(_ error: NetworkError, _ operation: PendingOperation) -> Bool {
        switch (operation, error) {
        case (.delete, .notFound), (.removeFromAlbum, .notFound), (.addToAlbum, .conflict): true
        default: false
        }
    }

    private func nextOperation() throws -> (Int64, PendingOperation, Int)? {
        try database.writer.read { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql:
                        "SELECT id, payload, attempts FROM operation WHERE state = 'pending' AND (nextAttemptAt IS NULL OR nextAttemptAt <= ?) ORDER BY id LIMIT 1",
                    arguments: [Date().timeIntervalSince1970])
            else { return nil }
            let payload: String = row["payload"]
            let operation = try JSONDecoder().decode(PendingOperation.self, from: Data(payload.utf8))
            return (row["id"], operation, row["attempts"])
        }
    }

    func execute(_ operation: PendingOperation) async throws {
        switch operation {
        case .favorite(_, let path, let value):
            try await api.setFavorite(userPath: path, value)
        case .delete(_, let path):
            try await api.delete(userPath: path)
        case .archive(let fileId, let path):
            let target = Self.archivePrefix + path
            try await api.move(userPath: path, to: target)
            try library.update(fileId) { $0.path = target }
        case .unarchive(let fileId, let path):
            let original = path.hasPrefix(Self.archivePrefix + "/") ? String(path.dropFirst(Self.archivePrefix.count)) : path
            try await api.move(userPath: path, to: original)
            try library.update(fileId) { $0.path = original }
        case .addToAlbum(_, let name, let kind, _, let path):
            try await api.addToAlbum(Album(kind: kind, name: name), userPath: path)
        case .removeFromAlbum(_, let name, let kind, _, let childName):
            try await api.removeFromAlbum(Album(kind: kind, name: name), childName: childName)
        case .setMetadata(_, let path, let capturedAt, let latitude, let longitude, let removeLocation):
            try await api.setMetadata(
                userPath: path, capturedAt: capturedAt, latitude: latitude, longitude: longitude, removeLocation: removeLocation)
        }
    }

    /// Optimistic local effect.
    static func applyLocally(_ operation: PendingOperation, db: Database) throws {
        switch operation {
        case .favorite(let fileId, _, let value):
            try db.execute(sql: "UPDATE media SET isFavorite = ? WHERE fileId = ?", arguments: [value, fileId])
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
