// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import PhotosDomain
import PhotosModel

/// What smart offline keeps (SPEC §15.8.1): one row per kept file, and when albums were last opened.
///
/// The files themselves live in the account's SmartOffline folder; `localPath` is the file name inside it. Manually pinned
/// offline albums (`offlinePin`/`offlineFile`, SPEC §7.19) are separate: their photos are never candidates here.
public struct SmartOfflineStore: Sendable {
    public let database: AccountDatabase

    public init(database: AccountDatabase) {
        self.database = database
    }

    static func migrate(_ db: Database) throws {
        try db.create(table: "smartOfflineFile") { t in
            t.primaryKey("fileId", .integer)
            t.column("etag", .text).notNull()
            t.column("quality", .text).notNull()
            t.column("localPath", .text).notNull()
            t.column("bytes", .integer).notNull()
            t.column("keptAt", .double).notNull()
            t.column("reason", .text).notNull()
        }
        try db.create(table: "smartOfflineAlbumView") { t in
            t.primaryKey("albumId", .text)
            t.column("viewedAt", .double).notNull()
        }
    }

    /// One kept file as stored.
    public struct Row: Sendable, Hashable {
        public var fileId: FileID
        public var etag: String
        public var quality: SmartOfflineQuality
        public var localPath: String
        public var bytes: Int64
        public var keptAt: Date
        public var reason: SmartOfflineReason

        public init(
            fileId: FileID, etag: String, quality: SmartOfflineQuality, localPath: String, bytes: Int64, keptAt: Date,
            reason: SmartOfflineReason
        ) {
            self.fileId = fileId
            self.etag = etag
            self.quality = quality
            self.localPath = localPath
            self.bytes = bytes
            self.keptAt = keptAt
            self.reason = reason
        }
    }

    // MARK: Album views

    /// Remembers that an album was opened (its photos become candidates for a while).
    public func noteAlbumViewed(_ albumId: String, at date: Date = Date()) throws {
        try database.writer.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO smartOfflineAlbumView(albumId, viewedAt) VALUES (?, ?)",
                arguments: [albumId, date.timeIntervalSince1970])
        }
    }

    // MARK: Candidates

    /// Conditions every candidate meets: shown in the library (no Live Photo video, not archived, not in an excluded folder)
    /// and not already kept by an offline album.
    static func visibleConditions(excludedFolders: [String]) -> (String, StatementArguments) {
        var conditions = [
            "media.isLivePhotoVideo = 0", "media.isArchived = 0", "media.fileId NOT IN (SELECT fileId FROM offlineFile)",
        ]
        var arguments: StatementArguments = []
        for prefix in excludedFolders {
            conditions.append("media.path NOT LIKE ? ESCAPE '\\'")
            arguments += [LibraryStore.likePrefix(prefix)]
        }
        return (conditions.joined(separator: " AND "), arguments)
    }

    /// Every photo a reason of `SmartOfflinePolicy` may apply to: taken in the recent months, a favourite, its "On this
    /// day" comes up in the next days, or in an album opened recently. Reads only these rows, not the whole library.
    public func candidates(now: Date = Date(), excludedFolders: [String] = [], calendar: Calendar = .current) async throws
        -> [SmartOfflineCandidate]
    {
        let timestamp = LibraryStore.timestamp
        let (visible, visibleArguments) = Self.visibleConditions(excludedFolders: excludedFolders)
        let recentStart = calendar.date(byAdding: .month, value: -SmartOfflinePolicy.recentMonths, to: now) ?? now
        let albumStart = now.addingTimeInterval(-SmartOfflinePolicy.albumWindowDays * 86_400)
        var reasons = ["\(timestamp) >= ?", "media.isFavorite = 1"]
        var reasonArguments: StatementArguments = [recentStart.timeIntervalSince1970]
        // The coming days of every earlier year the library can have.
        let today = calendar.startOfDay(for: now)
        for yearsAgo in 1...Memories.onThisDayYears * 2 {
            guard let start = calendar.date(byAdding: .year, value: -yearsAgo, to: today),
                let end = calendar.date(byAdding: .day, value: SmartOfflinePolicy.upcomingDays, to: start)
            else { continue }
            reasons.append("(\(timestamp) >= ? AND \(timestamp) < ?)")
            reasonArguments += [start.timeIntervalSince1970, end.timeIntervalSince1970]
        }
        reasons.append(
            "media.fileId IN (SELECT albumItem.fileId FROM albumItem JOIN smartOfflineAlbumView view ON view.albumId = albumItem.albumId WHERE view.viewedAt >= ?)"
        )
        reasonArguments += [albumStart.timeIntervalSince1970]
        let sql = """
            SELECT media.fileId, media.etag, \(timestamp) AS timestamp, media.isFavorite, media.kind, media.size,
                (SELECT max(view.viewedAt) FROM albumItem JOIN smartOfflineAlbumView view ON view.albumId = albumItem.albumId
                 WHERE albumItem.fileId = media.fileId AND view.viewedAt >= ?) AS albumViewedAt
            FROM media
            WHERE \(visible) AND (\(reasons.joined(separator: " OR ")))
            """
        var allArguments: StatementArguments = [albumStart.timeIntervalSince1970]
        allArguments += visibleArguments
        allArguments += reasonArguments
        let arguments = allArguments
        return try await database.writer.read { db in
            try GRDB.Row.fetchAll(db, sql: sql, arguments: arguments).map { row in
                let viewed: Double? = row["albumViewedAt"]
                return SmartOfflineCandidate(
                    fileId: row["fileId"], etag: row["etag"], timestamp: Date(timeIntervalSince1970: row["timestamp"]),
                    isFavorite: row["isFavorite"], kind: MediaKind(rawValue: row["kind"]) ?? .image, size: row["size"],
                    albumViewedAt: viewed.map { Date(timeIntervalSince1970: $0) })
            }
        }
    }

    /// The current ETags of these files, for those the library still shows (see `candidates` for what that means).
    public func present(_ fileIds: [FileID], excludedFolders: [String] = []) async throws -> [FileID: String] {
        let (visible, visibleArguments) = Self.visibleConditions(excludedFolders: excludedFolders)
        let arguments = visibleArguments
        return try await database.writer.read { db in
            var result: [FileID: String] = [:]
            for chunk in fileIds.chunked(5000) {
                let list = chunk.map(String.init).joined(separator: ",")
                for row in try GRDB.Row.fetchAll(
                    db, sql: "SELECT fileId, etag FROM media WHERE fileId IN (\(list)) AND \(visible)", arguments: arguments)
                {
                    result[row["fileId"]] = row["etag"]
                }
            }
            return result
        }
    }

    // MARK: Kept files

    public func kept() throws -> [Row] {
        try database.writer.read { db in try Self.kept(db) }
    }

    static func kept(_ db: Database) throws -> [Row] {
        try GRDB.Row.fetchAll(db, sql: "SELECT * FROM smartOfflineFile").map { row in
            Row(
                fileId: row["fileId"], etag: row["etag"], quality: SmartOfflineQuality(rawValue: row["quality"]) ?? .screen,
                localPath: row["localPath"], bytes: row["bytes"], keptAt: Date(timeIntervalSince1970: row["keptAt"]),
                reason: SmartOfflineReason(rawValue: row["reason"]) ?? .recent)
        }
    }

    public func insert(_ row: Row) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO smartOfflineFile(fileId, etag, quality, localPath, bytes, keptAt, reason)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    row.fileId, row.etag, row.quality.rawValue, row.localPath, row.bytes, row.keptAt.timeIntervalSince1970,
                    row.reason.rawValue,
                ])
        }
    }

    /// Records why the wanted files are kept now (the reason of a file changes as it ages).
    public func updateReasons(_ reasons: [FileID: SmartOfflineReason]) async throws {
        guard !reasons.isEmpty else { return }
        try await database.writer.write { db in
            for (fileId, reason) in reasons {
                try db.execute(
                    sql: "UPDATE smartOfflineFile SET reason = ? WHERE fileId = ? AND reason != ?",
                    arguments: [reason.rawValue, fileId, reason.rawValue])
            }
        }
    }

    public func delete(_ fileIds: [FileID]) async throws {
        guard !fileIds.isEmpty else { return }
        try await database.writer.write { db in
            for chunk in fileIds.chunked(5000) {
                try db.execute(sql: "DELETE FROM smartOfflineFile WHERE fileId IN (\(chunk.map(String.init).joined(separator: ",")))")
            }
        }
    }

    public func deleteAll() async throws {
        try await database.writer.write { db in try db.execute(sql: "DELETE FROM smartOfflineFile") }
    }

    /// What the kept files cover (Settings, the offline banner).
    public func summary() throws -> SmartOfflineSummary {
        try database.writer.read { db in
            let rows = try GRDB.Row.fetchAll(
                db, sql: "SELECT reason, count(*) AS n, coalesce(sum(bytes), 0) AS b FROM smartOfflineFile GROUP BY reason")
            var summary = SmartOfflineSummary()
            for row in rows {
                let count: Int = row["n"]
                summary.count += count
                summary.bytes += row["b"] as Int64
                switch SmartOfflineReason(rawValue: row["reason"]) {
                case .favorite: summary.favorites = count
                case .onThisDay: summary.onThisDay = count
                default: break
                }
            }
            let since: Double? = try Double.fetchOne(
                db,
                sql: """
                    SELECT min(\(LibraryStore.timestamp)) FROM media JOIN smartOfflineFile kept ON kept.fileId = media.fileId
                    WHERE kept.reason = 'recent'
                    """)
            summary.recentSince = since.map { Date(timeIntervalSince1970: $0) }
            summary.albums =
                try Int.fetchOne(
                    db,
                    sql: """
                        SELECT count(DISTINCT albumItem.albumId) FROM albumItem
                        JOIN smartOfflineFile kept ON kept.fileId = albumItem.fileId AND kept.reason = 'album'
                        """) ?? 0
            return summary
        }
    }
}
