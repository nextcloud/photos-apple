// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import PhotosDomain
import PhotosModel

/// What the cache knows about which photos matter (SPEC §18.2): the photos looked at in the viewer recently, and where
/// photos are shown besides the grids (covers, key photos, memory covers, faces).
///
/// Everything is read in a few queries for the whole library at once: the preview cache asks for the importance of every
/// photo when it trims, and that must stay fast for 100 000 files.
public struct CacheImportanceStore: Sendable {
    public let database: AccountDatabase

    /// Photos remembered as recently viewed; older views are forgotten.
    public static let recentlyViewedLimit = 2000

    public init(database: AccountDatabase) {
        self.database = database
    }

    static func migrate(_ db: Database) throws {
        try db.create(table: "recentlyViewed") { t in
            t.primaryKey("fileId", .integer)
            t.column("viewedAt", .double).notNull()
            t.column("count", .integer).notNull().defaults(to: 1)
        }
        try db.create(index: "recentlyViewed_viewedAt", on: "recentlyViewed", columns: ["viewedAt"])
        // Roles the app works out itself (key photos of the Library, memory covers); covers and faces come from their tables.
        try db.create(table: "cacheRole") { t in
            t.column("fileId", .integer).notNull()
            t.column("role", .integer).notNull()
            t.primaryKey(["role", "fileId"])
        }
    }

    // MARK: Recently viewed

    /// Remembers that the viewer showed a photo (for a second at least). Keeps the newest `recentlyViewedLimit` photos.
    public func noteViewed(_ fileId: FileID, at date: Date = Date()) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO recentlyViewed(fileId, viewedAt, count) VALUES (?, ?, 1)
                    ON CONFLICT(fileId) DO UPDATE SET viewedAt = excluded.viewedAt, count = count + 1
                    """,
                arguments: [fileId, date.timeIntervalSince1970])
            try db.execute(
                sql: """
                    DELETE FROM recentlyViewed WHERE viewedAt <
                        (SELECT viewedAt FROM recentlyViewed ORDER BY viewedAt DESC LIMIT 1 OFFSET ?)
                    """,
                arguments: [Self.recentlyViewedLimit - 1])
        }
    }

    public struct Viewed: Sendable, Hashable {
        public var fileId: FileID
        public var viewedAt: Date
        public var count: Int
    }

    /// The photos viewed recently, newest first.
    public func recentlyViewed(limit: Int = recentlyViewedLimit) throws -> [Viewed] {
        try database.writer.read { db in
            try Row.fetchAll(
                db, sql: "SELECT fileId, viewedAt, count FROM recentlyViewed ORDER BY viewedAt DESC LIMIT ?", arguments: [limit]
            ).map { Viewed(fileId: $0["fileId"], viewedAt: Date(timeIntervalSince1970: $0["viewedAt"]), count: $0["count"]) }
        }
    }

    // MARK: Roles

    /// Replaces the photos that have `role` (one of the roles the app works out: key photos, memory covers). Writes only
    /// when they changed. Returns whether they did.
    @discardableResult
    public func setRole(_ role: CacheImportance.Roles, fileIds: Set<FileID>) async throws -> Bool {
        try await database.writer.write { db in
            let current = try Set(
                FileID.fetchAll(db, sql: "SELECT fileId FROM cacheRole WHERE role = ?", arguments: [role.rawValue]))
            guard current != fileIds else { return false }
            try db.execute(sql: "DELETE FROM cacheRole WHERE role = ?", arguments: [role.rawValue])
            for fileId in fileIds {
                try db.execute(sql: "INSERT INTO cacheRole(fileId, role) VALUES (?, ?)", arguments: [fileId, role.rawValue])
            }
            return true
        }
    }

    /// `WITH` clauses giving `roleBits(fileId, roles)`: every photo with a role and its roles (`CacheImportance.Roles`).
    /// `UNION` drops repeated (photo, role) pairs, so the sum of the distinct powers of two is their bitwise or.
    static let rolesCTE = """
        roles(fileId, role) AS (
            SELECT coverFileId, 1 FROM album WHERE coverFileId > 0
            UNION SELECT lastPhotoFileId, 1 FROM album WHERE coalesce(coverFileId, 0) <= 0 AND lastPhotoFileId > 0
            UNION SELECT coverFileId, 1 FROM place WHERE coverFileId > 0
            UNION SELECT coverFileId, 1 FROM tag WHERE coverFileId > 0
            UNION SELECT coverFileId, 8 FROM person WHERE coverFileId > 0
            UNION SELECT fileId, role FROM cacheRole
        ),
        roleBits(fileId, roles) AS (SELECT fileId, sum(role) FROM roles GROUP BY fileId)
        """

    /// Every photo with a role (also those that are not in the library index, like covers of albums shared with the user).
    public func roles() throws -> [FileID: CacheImportance.Roles] {
        try database.writer.read { db in try Self.roles(db) }
    }

    /// The photos with any role.
    public func prominentFileIds() async throws -> Set<FileID> {
        try await database.writer.read { db in try Set(Self.roles(db).keys) }
    }

    static func roles(_ db: Database) throws -> [FileID: CacheImportance.Roles] {
        var result: [FileID: CacheImportance.Roles] = [:]
        let rows = try Row.fetchCursor(db, sql: "WITH \(rolesCTE) SELECT fileId, roles FROM roleBits")
        while let row = try rows.next() { result[row["fileId"]] = CacheImportance.Roles(rawValue: row["roles"]) }
        return result
    }

    // MARK: Eviction

    /// The importance tier (`CacheImportance.tier`) of every photo that has one; the others have tier 0. Two queries,
    /// whatever the size of the library.
    public func tiers(now: Date = Date(), calendar: Calendar = .current) throws -> [FileID: UInt8] {
        try database.writer.read { db in
            var tiers: [FileID: UInt8] = [:]
            for candidate in try SmartOfflineStore.candidates(db, now: now, excludedFolders: [], calendar: calendar) {
                if let score = CacheImportance.score(candidate.signals, now: now, calendar: calendar)?.score {
                    tiers[candidate.fileId] = CacheImportance.tier(score)
                }
            }
            // Photos that are no candidates (offline, archived, not in the index) but are shown as covers.
            for (fileId, roles) in try Self.roles(db) where tiers[fileId] == nil {
                if let score = CacheImportance.score(CacheImportance.Signals(roles: roles), now: now, calendar: calendar)?.score {
                    tiers[fileId] = CacheImportance.tier(score)
                }
            }
            return tiers
        }
    }

    /// The ETag of every photo in the library index, as it appears in cache file names (`CacheFileName.etag`).
    public func libraryEtags() throws -> [FileID: String] {
        try database.writer.read { db in
            var result: [FileID: String] = [:]
            let rows = try Row.fetchCursor(db, sql: "SELECT fileId, etag FROM media WHERE isLivePhotoVideo = 0")
            while let row = try rows.next() { result[row["fileId"]] = CacheFileName.etag(row["etag"]) }
            return result
        }
    }
}
