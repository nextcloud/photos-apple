// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import PhotosModel

/// Something that happened in a shared album since the app last listed it (SPEC SH-7).
///
/// Neither stock nor extended Photos servers say who added what or when, and they send no notification for it. The app
/// notices it itself: every listing of the albums is compared with the previous one, and an album that has more photos
/// than before or that was newly shared with the user becomes an entry here.
/// Instant notifications would need the server to send them (companion S5).
public struct AlbumActivity: Sendable, Hashable, Identifiable {
    public var id: Int64
    /// `Album.id`.
    public var albumId: String
    public var title: String
    public var ownerDisplayName: String?
    /// Photos that are new since the album was last listed (the difference of the counts).
    public var added: Int
    /// The album was shared with the user since the last listing.
    public var isNewAlbum: Bool
    public var coverFileId: FileID?
    public var detectedAt: Date
    /// The user opened the album (or marked everything as seen) since.
    public var isSeen: Bool

    public init(
        id: Int64 = 0, albumId: String, title: String, ownerDisplayName: String? = nil, added: Int, isNewAlbum: Bool = false,
        coverFileId: FileID? = nil, detectedAt: Date = Date(), isSeen: Bool = false
    ) {
        self.id = id
        self.albumId = albumId
        self.title = title
        self.ownerDisplayName = ownerDisplayName
        self.added = added
        self.isNewAlbum = isNewAlbum
        self.coverFileId = coverFileId
        self.detectedAt = detectedAt
        self.isSeen = isSeen
    }
}

enum SharedAlbumActivity {
    /// Seen entries are kept this long (the activity list shows the recent past too).
    static let retention: TimeInterval = 30 * 24 * 3600

    static func baselineKey(_ kind: AlbumKind) -> String { "albumActivityBaseline:\(kind.rawValue)" }

    /// Migration `v3-album-activity`.
    static func migrate(_ db: Database) throws {
        try db.create(table: "albumActivity") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("albumId", .text).notNull()
            t.column("title", .text).notNull()
            t.column("ownerDisplayName", .text)
            t.column("added", .integer).notNull().defaults(to: 0)
            t.column("isNewAlbum", .boolean).notNull().defaults(to: false)
            t.column("coverFileId", .integer)
            t.column("detectedAt", .double).notNull()
            t.column("isSeen", .boolean).notNull().defaults(to: false)
        }
        try db.create(index: "albumActivity_album", on: "albumActivity", columns: ["albumId", "isSeen"])
    }

    /// Whether others can add photos to the album: albums shared with the user, and own albums shared with people
    /// (a public link alone lets nobody add).
    static func isWatched(_ album: Album) -> Bool {
        switch album.kind {
        case .shared: true
        case .own: album.collaborators.contains { $0.type != .publicLink }
        case .publicLink: false
        }
    }

    /// What changed between two listings of the same albums. Pure, so it can be tested without a server.
    ///
    /// - Parameter previous: the albums as stored (their counts include changes this app made itself, so adding photos
    ///   here is not reported as activity).
    /// - Parameter isFirstListing: the very first listing of this kind; nothing is reported, it only becomes the baseline.
    static func events(previous: [Album], current: [Album], isFirstListing: Bool, now: Date = Date()) -> [AlbumActivity] {
        guard !isFirstListing else { return [] }
        let before = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [AlbumActivity] = []
        for album in current where isWatched(album) {
            guard let old = before[album.id] else {
                // Own albums appear because the user made them; shared ones because someone shared them.
                if album.kind == .shared {
                    result.append(
                        AlbumActivity(
                            albumId: album.id, title: album.title, ownerDisplayName: album.ownerDisplayName, added: album.itemCount,
                            isNewAlbum: true, coverFileId: album.displayCoverFileId, detectedAt: now))
                }
                continue
            }
            // The count, not the modification time of extended servers: photos added in this app raise the stored
            // count at once (outbox), but not the stored time, and would be reported as someone else's.
            let delta = album.itemCount - old.itemCount
            guard delta > 0 else { continue }
            result.append(
                AlbumActivity(
                    albumId: album.id, title: album.title, ownerDisplayName: album.ownerDisplayName, added: delta,
                    coverFileId: album.displayCoverFileId, detectedAt: now))
        }
        return result
    }

    /// Records what changed between the stored albums of one kind and a new listing; called by `replaceAlbums` in its
    /// own transaction, before the rows are replaced. An unseen entry of the same album is extended, not repeated.
    static func record(existing: [Album], incoming: [Album], kind: AlbumKind, db: Database, now: Date = Date()) throws {
        let key = baselineKey(kind)
        let hasBaseline = try String.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = ?", arguments: [key]) != nil
        for event in events(previous: existing, current: incoming, isFirstListing: !hasBaseline, now: now) {
            let unseen = "SELECT id FROM albumActivity WHERE albumId = ? AND isSeen = 0 ORDER BY id DESC LIMIT 1"
            if let id = try Int64.fetchOne(db, sql: unseen, arguments: [event.albumId]) {
                try db.execute(
                    sql:
                        "UPDATE albumActivity SET added = added + ?, title = ?, coverFileId = coalesce(?, coverFileId), detectedAt = ? WHERE id = ?",
                    arguments: [event.added, event.title, event.coverFileId, now.timeIntervalSince1970, id])
            } else {
                try db.execute(
                    sql: """
                        INSERT INTO albumActivity(albumId, title, ownerDisplayName, added, isNewAlbum, coverFileId, detectedAt, isSeen)
                        VALUES (?, ?, ?, ?, ?, ?, ?, 0)
                        """,
                    arguments: [
                        event.albumId, event.title, event.ownerDisplayName, event.added, event.isNewAlbum, event.coverFileId,
                        now.timeIntervalSince1970,
                    ])
            }
        }
        // Albums that are gone (left, deleted, no longer shared) have nothing to show any more.
        let ids = Set(incoming.map(\.id))
        for gone in Set(existing.map(\.id)).subtracting(ids) {
            try db.execute(sql: "DELETE FROM albumActivity WHERE albumId = ?", arguments: [gone])
        }
        try db.execute(
            sql: "DELETE FROM albumActivity WHERE isSeen = 1 AND detectedAt < ?", arguments: [now.timeIntervalSince1970 - retention])
        if !hasBaseline { try db.execute(sql: "INSERT OR REPLACE INTO syncState(key, value) VALUES (?, '1')", arguments: [key]) }
    }

    /// The album's content was loaded (it was opened): what was new in it has been seen.
    static func markSeen(albumId: String, db: Database) throws {
        try db.execute(sql: "UPDATE albumActivity SET isSeen = 1 WHERE albumId = ? AND isSeen = 0", arguments: [albumId])
    }

    static func activity(_ row: Row) -> AlbumActivity {
        AlbumActivity(
            id: row["id"], albumId: row["albumId"], title: row["title"], ownerDisplayName: row["ownerDisplayName"], added: row["added"],
            isNewAlbum: row["isNewAlbum"], coverFileId: row["coverFileId"],
            detectedAt: Date(timeIntervalSince1970: row["detectedAt"]), isSeen: row["isSeen"])
    }
}

/// The activity list of shared albums.
public struct AlbumActivityStore: Sendable {
    public let database: AccountDatabase

    public init(database: AccountDatabase) {
        self.database = database
    }

    /// Newest first; unseen entries before seen ones.
    public func observe(limit: Int = 100) -> AsyncThrowingStream<[AlbumActivity], any Error> {
        ValueObservation.tracking { db in
            try Row.fetchAll(db, sql: "SELECT * FROM albumActivity ORDER BY isSeen, detectedAt DESC LIMIT ?", arguments: [limit])
                .map(SharedAlbumActivity.activity)
        }
        .removeDuplicates()
        .values(in: database.writer)
        .stream()
    }

    public func all(limit: Int = 100) throws -> [AlbumActivity] {
        try database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM albumActivity ORDER BY isSeen, detectedAt DESC LIMIT ?", arguments: [limit])
                .map(SharedAlbumActivity.activity)
        }
    }

    /// Unseen entries detected at or after `date` (what a refresh found, for a notification).
    public func unseen(since date: Date) throws -> [AlbumActivity] {
        try database.writer.read { db in
            try Row.fetchAll(
                db, sql: "SELECT * FROM albumActivity WHERE isSeen = 0 AND detectedAt >= ? ORDER BY detectedAt DESC",
                arguments: [date.timeIntervalSince1970]
            )
            .map(SharedAlbumActivity.activity)
        }
    }

    public func markSeen(albumId: String) throws {
        try database.writer.write { db in try SharedAlbumActivity.markSeen(albumId: albumId, db: db) }
    }

    public func markAllSeen() throws {
        try database.writer.write { db in try db.execute(sql: "UPDATE albumActivity SET isSeen = 1 WHERE isSeen = 0") }
    }
}
