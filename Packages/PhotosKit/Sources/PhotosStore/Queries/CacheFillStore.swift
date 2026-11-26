// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import PhotosDomain
import PhotosModel

/// What the cache fillers read from the index (SPEC §18.3): the library page by page for its thumbnails, and what the
/// app shows first when it opens. Every query reads one index range; none loads the whole library.
public struct CacheFillStore: Sendable {
    public let database: AccountDatabase

    public init(database: AccountDatabase) {
        self.database = database
    }

    /// A photo of the library whose thumbnails are filled.
    public struct Photo: Sendable, Hashable {
        public var fileId: FileID
        public var etag: String
        public var timestamp: Double
    }

    /// Where a page ends; the next page starts after it (newest first, as the timeline).
    public struct Cursor: Sendable, Hashable {
        public var timestamp: Double
        public var fileId: FileID

        public init(timestamp: Double, fileId: FileID) {
            self.timestamp = timestamp
            self.fileId = fileId
        }
    }

    /// Photos the timeline shows (outside the excluded folders) and, with `previews`, that have a server preview.
    static func libraryConditions(excludedFolders: [String], previews: Bool = true) -> (String, StatementArguments) {
        var conditions = [LibraryStore.visible]
        if previews { conditions.append("media.hasPreview = 1") }
        var arguments: StatementArguments = []
        for prefix in excludedFolders {
            conditions.append("media.path NOT LIKE ? ESCAPE '\\'")
            arguments += [LibraryStore.likePrefix(prefix)]
        }
        return (conditions.joined(separator: " AND "), arguments)
    }

    /// How many photos have thumbnails to keep.
    public func libraryCount(excludedFolders: [String] = []) async throws -> Int {
        let (conditions, arguments) = Self.libraryConditions(excludedFolders: excludedFolders)
        return try await database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM media WHERE \(conditions)", arguments: arguments) ?? 0
        }
    }

    /// The next `limit` photos after `cursor` (from the newest when nil).
    public func libraryPage(after cursor: Cursor?, limit: Int, excludedFolders: [String] = []) async throws -> [Photo] {
        let timestamp = LibraryStore.timestamp
        var (conditions, arguments) = Self.libraryConditions(excludedFolders: excludedFolders)
        if let cursor {
            conditions += " AND (\(timestamp) < ? OR (\(timestamp) = ? AND media.fileId < ?))"
            arguments += [cursor.timestamp, cursor.timestamp, cursor.fileId]
        }
        arguments += [limit]
        let sql = """
            SELECT media.fileId, media.etag, \(timestamp) AS timestamp FROM media
            WHERE \(conditions) \(LibraryStore.displayOrder) LIMIT ?
            """
        let finalArguments = arguments
        return try await database.writer.read { db in
            var result: [Photo] = []
            let rows = try Row.fetchCursor(db, sql: sql, arguments: finalArguments)
            while let row = try rows.next() {
                result.append(Photo(fileId: row[0], etag: row[1], timestamp: row[2] ?? 0))
            }
            return result
        }
    }

    // MARK: Preparation

    static func planPhoto(_ row: Row) -> PreparationPlan.Photo {
        let width: Int? = row["width"]
        let height: Int? = row["height"]
        let ratio = width.flatMap { width in height.map { height in width > 0 && height > 0 ? Double(width) / Double(height) : 1 } } ?? 1
        return PreparationPlan.Photo(fileId: row["fileId"], etag: row["etag"], aspectRatio: ratio)
    }

    /// The newest `limit` photos of the timeline.
    public func timelineStart(limit: Int, excludedFolders: [String] = []) async throws -> [PreparationPlan.Photo] {
        // The timeline shows photos without a server preview too (thumbnailed on the device); they are not prepared, but
        // they take their places on the screen.
        let (conditions, arguments) = Self.libraryConditions(excludedFolders: excludedFolders, previews: false)
        let sql = """
            SELECT media.fileId, media.etag, media.width, media.height, media.hasPreview FROM media
            WHERE \(conditions) \(LibraryStore.displayOrder) LIMIT ?
            """
        let finalArguments = arguments + [limit]
        return try await database.writer.read { db in
            try Row.fetchAll(db, sql: sql, arguments: finalArguments).compactMap { row in
                (row["hasPreview"] as Bool) ? Self.planPhoto(row) : nil
            }
        }
    }

    /// These photos by file id (those in the index and with a server preview).
    public func photos(_ fileIds: [FileID]) async throws -> [FileID: PreparationPlan.Photo] {
        guard !fileIds.isEmpty else { return [:] }
        return try await database.writer.read { db in
            var result: [FileID: PreparationPlan.Photo] = [:]
            for chunk in fileIds.chunked(5000) {
                let list = chunk.map(String.init).joined(separator: ",")
                for row in try Row.fetchAll(
                    db, sql: "SELECT fileId, etag, width, height FROM media WHERE fileId IN (\(list)) AND hasPreview = 1")
                {
                    let photo = Self.planPhoto(row)
                    result[photo.fileId] = photo
                }
            }
            return result
        }
    }

    /// The albums opened since `since`, most recent first: their cover and first photos (as the album's grid shows them,
    /// newest first).
    public func recentAlbums(since: Date, limit: Int, photos: Int) async throws -> [PreparationPlan.Collection] {
        try await database.writer.read { db in
            let albums = try Row.fetchAll(
                db,
                sql: """
                    SELECT album.id, coalesce(nullif(album.coverFileId, 0), album.lastPhotoFileId) AS cover
                    FROM smartOfflineAlbumView view JOIN album ON album.id = view.albumId
                    WHERE view.viewedAt >= ? ORDER BY view.viewedAt DESC LIMIT ?
                    """, arguments: [since.timeIntervalSince1970, limit])
            return try albums.map { album in
                let id: String = album["id"]
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT media.fileId, media.etag, media.width, media.height FROM albumItem
                        JOIN media ON media.fileId = albumItem.fileId
                        WHERE albumItem.albumId = ? AND media.hasPreview = 1 AND media.isLivePhotoVideo = 0
                        \(LibraryStore.displayOrder) LIMIT ?
                        """, arguments: [id, photos])
                var coverPhoto: PreparationPlan.Photo?
                if let coverId: FileID = album["cover"],
                    let row = try Row.fetchOne(
                        db, sql: "SELECT fileId, etag, width, height FROM media WHERE fileId = ? AND hasPreview = 1", arguments: [coverId])
                {
                    coverPhoto = Self.planPhoto(row)
                }
                return PreparationPlan.Collection(cover: coverPhoto, photos: rows.map(Self.planPhoto))
            }
        }
    }
}
