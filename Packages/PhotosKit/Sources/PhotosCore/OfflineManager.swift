// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import OSLog
import PhotosModel
import PhotosNetworking
import PhotosStore

/// Offline albums and photos (SPEC §7.19): originals are downloaded into the account's Offline folder and kept in sync.
public actor OfflineManager {
    let services: AccountServices
    let directory: URL
    private let logger = Logger(subsystem: "com.nextcloud.photos", category: "offline")
    private var syncing = false

    public init(services: AccountServices) {
        self.services = services
        self.directory = AppPaths.offline(services.account.id)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var database: AccountDatabase { services.database }

    public struct Pin: Sendable, Hashable, Identifiable {
        public var id: String
        public var title: String
        public var fileCount: Int
        public var bytes: Int64
    }

    public static func pinId(album: Album) -> String { "album:\(album.id)" }

    public func pin(album: Album) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO offlinePin(id, title, createdAt) VALUES (?, ?, ?)",
                arguments: [Self.pinId(album: album), album.title, Date().timeIntervalSince1970])
        }
        await syncPins()
    }

    public func unpin(album: Album) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM offlinePin WHERE id = ?", arguments: [Self.pinId(album: album)])
        }
        try await removeUnpinnedFiles()
    }

    public func isPinned(_ id: String) -> Bool {
        (try? database.writer.read { db in try Bool.fetchOne(db, sql: "SELECT 1 FROM offlinePin WHERE id = ?", arguments: [id]) }) ?? false
    }

    public func pins() throws -> [Pin] {
        try database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT id, title FROM offlinePin ORDER BY createdAt").map { row in
                let id: String = row["id"]
                let albumId = id.hasPrefix("album:") ? String(id.dropFirst(6)) : ""
                let stats = try Row.fetchOne(
                    db,
                    sql:
                        "SELECT count(*) AS n, coalesce(sum(offlineFile.bytes), 0) AS b FROM albumItem JOIN offlineFile ON offlineFile.fileId = albumItem.fileId WHERE albumItem.albumId = ?",
                    arguments: [albumId])
                return Pin(id: id, title: row["title"], fileCount: stats?["n"] ?? 0, bytes: stats?["b"] ?? 0)
            }
        }
    }

    /// Local original of a file when it is available offline.
    public nonisolated func localFile(fileId: FileID, etag: String) -> URL? {
        guard
            let row = try? services.database.writer.read({ db in
                try Row.fetchOne(db, sql: "SELECT localPath, etag FROM offlineFile WHERE fileId = ?", arguments: [fileId])
            }),
            (row["etag"] as String) == etag
        else { return nil }
        let url = URL(fileURLWithPath: row["localPath"])
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    /// Downloads missing files of every pinned album (call on Wi-Fi / when the app becomes active).
    public func syncPins() async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            let albumIds: [String] = try await database.writer.read { db in
                try String.fetchAll(db, sql: "SELECT substr(id, 7) FROM offlinePin WHERE id LIKE 'album:%'")
            }
            for albumId in albumIds {
                guard let album = try services.collections.album(id: albumId) else { continue }
                try? await services.sync.refreshAlbumContent(album)
                let items = try services.collections.albumItems(albumId: albumId)
                let map = try services.library.items(items.map(\.fileId))
                for info in items {
                    guard let item = map[info.fileId], localFile(fileId: item.fileId, etag: item.etag) == nil else { continue }
                    try Task.checkCancellation()
                    let path = info.ownerPath ?? item.path
                    let url =
                        item.isOwnStorage || info.ownerPath != nil
                        ? services.connection.filesURL(path) : services.api.albumURL(album).appending(path: info.childName)
                    do {
                        let (file, _) = try await services.dav.download(url)
                        let target = directory.appending(path: "\(item.fileId)-\(item.etag).\((item.name as NSString).pathExtension)")
                        try? FileManager.default.removeItem(at: target)
                        try FileManager.default.moveItem(at: file, to: target)
                        let size = Int64((try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                        try await database.writer.write { db in
                            try db.execute(
                                sql:
                                    "INSERT OR REPLACE INTO offlineFile(fileId, etag, localPath, bytes, downloadedAt) VALUES (?, ?, ?, ?, ?)",
                                arguments: [item.fileId, item.etag, target.path(percentEncoded: false), size, Date().timeIntervalSince1970])
                        }
                    } catch {
                        logger.error("offline download failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
            try await removeUnpinnedFiles()
        } catch {
            logger.error("offline sync failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Deletes offline files that no pinned album contains any more.
    func removeUnpinnedFiles() async throws {
        let stale: [(Int64, String)] = try await database.writer.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT fileId, localPath FROM offlineFile WHERE fileId NOT IN (
                      SELECT albumItem.fileId FROM albumItem JOIN offlinePin ON offlinePin.id = 'album:' || albumItem.albumId)
                    """
            ).map { ($0["fileId"], $0["localPath"]) }
        }
        for (_, path) in stale { try? FileManager.default.removeItem(atPath: path) }
        let ids = stale.map(\.0)
        guard !ids.isEmpty else { return }
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM offlineFile WHERE fileId IN (\(ids.map(String.init).joined(separator: ",")))")
        }
    }

    public func removeAll() async throws {
        try await database.writer.write { db in try db.execute(sql: "DELETE FROM offlinePin; DELETE FROM offlineFile") }
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
