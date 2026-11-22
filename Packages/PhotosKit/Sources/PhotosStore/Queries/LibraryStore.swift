// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import PhotosModel

/// What a timeline-like view shows.
public enum MediaFilter: Hashable, Sendable {
    case all
    case photos
    case videos
    case favorites
    case archived
    case place(String)
    case album(String)
    case person(String)
    case tag(Int)
    case fileIds([FileID])
}

/// Lightweight row for grids (keeps 100k items cheap in memory).
public struct GridMedia: Hashable, Sendable, Identifiable, FetchableRecord {
    public var id: FileID { fileId }
    public var fileId: FileID
    public var timestamp: Date
    public var kind: MediaKind
    public var etag: String
    public var isFavorite: Bool
    public var isLivePhoto: Bool
    public var hasPreview: Bool
    public var blurhash: String?
    public var duration: Double?
    public var aspectRatio: Double
    public var name: String
    public var directory: String
    public var mimeType: String
    public var isArchived: Bool

    public init(row: Row) throws {
        fileId = row["fileId"]
        timestamp = Date(timeIntervalSince1970: row["timestamp"] ?? 0)
        kind = MediaKind(rawValue: row["kind"]) ?? .image
        etag = row["etag"]
        isFavorite = row["isFavorite"]
        isLivePhoto = (row["livePhotoPeer"] as Int64?) != nil
        hasPreview = row["hasPreview"]
        blurhash = row["blurhash"]
        duration = row["duration"]
        let width: Int? = row["width"]
        let height: Int? = row["height"]
        if let width, let height, width > 0, height > 0 { aspectRatio = Double(width) / Double(height) } else { aspectRatio = 1 }
        name = row["name"]
        let path: String = row["path"]
        directory = (path as NSString).deletingLastPathComponent
        mimeType = row["mimeType"]
        isArchived = row["isArchived"]
    }

    public init(_ item: MediaItem) {
        fileId = item.fileId
        timestamp = item.timestamp
        kind = item.kind
        etag = item.etag
        isFavorite = item.isFavorite
        isLivePhoto = item.isLivePhoto
        hasPreview = item.hasPreview
        blurhash = item.blurhash
        duration = item.duration
        aspectRatio = item.aspectRatio
        name = item.name
        directory = item.directory
        mimeType = item.mimeType
        isArchived = item.isArchived
    }
}

/// Read and write access to the library index.
public struct LibraryStore: Sendable {
    public let database: AccountDatabase

    public init(database: AccountDatabase) {
        self.database = database
    }

    static let gridColumns =
        "media.fileId, media.timestamp, media.kind, media.etag, media.isFavorite, media.livePhotoPeer, media.hasPreview, media.blurhash, media.duration, media.width, media.height, media.name, media.path, media.mimeType, media.isArchived"

    /// SQL for a filter; visible items exclude Live Photo videos and (unless asked) archived items.
    static func sql(for filter: MediaFilter, excludedPrefixes: [String]) -> (String, StatementArguments) {
        var joins = ""
        var conditions = ["media.isLivePhotoVideo = 0"]
        var arguments: StatementArguments = []
        switch filter {
        case .all: conditions.append("media.isArchived = 0")
        case .photos: conditions.append("media.isArchived = 0 AND media.kind = 'image'")
        case .videos: conditions.append("media.isArchived = 0 AND media.kind = 'video'")
        case .favorites: conditions.append("media.isArchived = 0 AND media.isFavorite = 1")
        case .archived: conditions.append("media.isArchived = 1")
        case .place(let name):
            conditions.append("media.isArchived = 0 AND media.place = ?")
            arguments += [name]
        case .album(let id):
            joins = "JOIN albumItem ON albumItem.fileId = media.fileId"
            conditions.append("albumItem.albumId = ?")
            arguments += [id]
        case .person(let name):
            joins = "JOIN personItem ON personItem.fileId = media.fileId"
            conditions.append("personItem.person = ?")
            arguments += [name]
        case .tag(let id):
            joins = "JOIN tagItem ON tagItem.fileId = media.fileId"
            conditions.append("media.isArchived = 0 AND tagItem.tagId = ?")
            arguments += [id]
        case .fileIds(let ids):
            conditions.append("media.fileId IN (\(ids.map { String($0) }.joined(separator: ",").ifEmpty("-1")))")
        }
        for prefix in excludedPrefixes {
            conditions.append("media.path NOT LIKE ? ESCAPE '\\'")
            arguments += [Self.likePrefix(prefix)]
        }
        let sql =
            "SELECT DISTINCT \(gridColumns) FROM media \(joins) WHERE \(conditions.joined(separator: " AND ")) ORDER BY media.timestamp DESC, media.fileId DESC"
        return (sql, arguments)
    }

    static func likePrefix(_ folder: String) -> String {
        let trimmed = folder.hasSuffix("/") ? folder : folder + "/"
        let escaped = trimmed.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(
            of: "_", with: "\\_")
        return escaped + "%"
    }

    public func gridItems(_ filter: MediaFilter, excludedFolders: [String] = []) throws -> [GridMedia] {
        let (sql, arguments) = Self.sql(for: filter, excludedPrefixes: excludedFolders)
        return try database.writer.read { db in try GridMedia.fetchAll(db, sql: sql, arguments: arguments) }
    }

    /// Live updates of a grid query.
    public func observeGrid(_ filter: MediaFilter, excludedFolders: [String] = []) -> AsyncThrowingStream<[GridMedia], any Error> {
        let (sql, arguments) = Self.sql(for: filter, excludedPrefixes: excludedFolders)
        return ValueObservation.tracking { db in try GridMedia.fetchAll(db, sql: sql, arguments: arguments) }
            .removeDuplicates()
            .values(in: database.writer)
            .stream()
    }

    public func item(_ fileId: FileID) throws -> MediaItem? {
        try database.writer.read { db in
            if let item = try MediaItem.fetchOne(db, key: fileId) { return item }
            return try CollectionMediaRecord.fetchOne(db, key: fileId)?.item
        }
    }

    public func items(_ fileIds: [FileID]) throws -> [FileID: MediaItem] {
        try database.writer.read { db in
            var result: [FileID: MediaItem] = [:]
            for item in try MediaItem.fetchAll(db, keys: fileIds) { result[item.fileId] = item }
            let missing = fileIds.filter { result[$0] == nil }
            for record in try CollectionMediaRecord.fetchAll(db, keys: missing) { result[record.fileId] = record.item }
            return result
        }
    }

    /// All visible items (used by memories, map, duplicates, search).
    public func allVisibleItems() throws -> [MediaItem] {
        try database.writer.read { db in
            try MediaItem.fetchAll(db, sql: "SELECT * FROM media WHERE isLivePhotoVideo = 0 AND isArchived = 0 ORDER BY timestamp DESC")
        }
    }

    /// Items within ±3 days of today in each of the last 20 years (cheap SQL for widgets).
    public func onThisDayItems(now: Date = Date(), calendar: Calendar = .current, limit: Int = 200) throws -> [MediaItem] {
        var ranges: [String] = []
        var arguments: StatementArguments = []
        for yearsAgo in 1...20 {
            guard let anchor = calendar.date(byAdding: .year, value: -yearsAgo, to: now),
                let start = calendar.date(byAdding: .day, value: -3, to: calendar.startOfDay(for: anchor)),
                let end = calendar.date(byAdding: .day, value: 4, to: calendar.startOfDay(for: anchor))
            else { continue }
            ranges.append("(timestamp >= ? AND timestamp < ?)")
            arguments += [start.timeIntervalSince1970, end.timeIntervalSince1970]
        }
        let sql =
            "SELECT * FROM media WHERE isLivePhotoVideo = 0 AND isArchived = 0 AND kind = 'image' AND (\(ranges.joined(separator: " OR "))) ORDER BY isFavorite DESC, timestamp DESC LIMIT \(limit)"
        return try database.writer.read { db in try MediaItem.fetchAll(db, sql: sql, arguments: arguments) }
    }

    public func favoriteImages(limit: Int = 50) throws -> [MediaItem] {
        try database.writer.read { db in
            try MediaItem.fetchAll(
                db, sql: "SELECT * FROM media WHERE isFavorite = 1 AND isArchived = 0 AND kind = 'image' ORDER BY timestamp DESC LIMIT ?",
                arguments: [limit])
        }
    }

    public func count() throws -> Int {
        try database.writer.read { db in try MediaItem.fetchCount(db) }
    }

    // MARK: Writes

    public func upsert(_ items: [MediaItem], generation: Int? = nil) throws {
        guard !items.isEmpty else { return }
        try database.writer.write { db in
            for item in items {
                try item.upsert(db)
                if let generation {
                    try db.execute(sql: "UPDATE media SET syncGeneration = ? WHERE fileId = ?", arguments: [generation, item.fileId])
                }
                try SearchIndex.update(db, item: item)
            }
        }
    }

    public func delete(_ fileIds: [FileID]) throws {
        guard !fileIds.isEmpty else { return }
        try database.writer.write { db in
            _ = try MediaItem.deleteAll(db, keys: fileIds)
            try db.execute(sql: "DELETE FROM searchIndex WHERE fileId IN (\(fileIds.map { String($0) }.joined(separator: ",")))")
        }
    }

    /// Optimistic local update (outbox applies it on the server).
    public func update(_ fileId: FileID, _ change: @Sendable (inout MediaItem) -> Void) throws {
        try database.writer.write { db in
            guard var item = try MediaItem.fetchOne(db, key: fileId) else { return }
            change(&item)
            try item.update(db)
        }
    }

    /// Keeps items that are not in the timeline index (shared albums, other folders, people…) so viewers can show them.
    public func storeCollectionMedia(_ items: [MediaItem]) throws {
        try database.writer.write { db in
            for item in items where try !MediaItem.exists(db, key: item.fileId) {
                try CollectionMediaRecord(fileId: item.fileId, item: item).upsert(db)
            }
        }
    }

    public func deleteAll() throws {
        try database.writer.write { db in
            try db.execute(
                sql: "DELETE FROM media; DELETE FROM searchIndex; DELETE FROM albumItem; DELETE FROM album; DELETE FROM syncState")
        }
    }
}

enum SearchIndex {
    static func update(_ db: Database, item: MediaItem) throws {
        try db.execute(sql: "DELETE FROM searchIndex WHERE fileId = ?", arguments: [item.fileId])
        let text = [item.name, item.place, item.placeCountry, item.caption, (item.directory as NSString).lastPathComponent]
            .compactMap { $0 }.joined(separator: " ")
        try db.execute(sql: "INSERT INTO searchIndex(fileId, text) VALUES (?, ?)", arguments: [item.fileId, text])
    }
}

extension String {
    func ifEmpty(_ replacement: String) -> String { isEmpty ? replacement : self }
}

extension AsyncValueObservation {
    /// Wraps a GRDB observation so modules that don't import GRDB can consume it.
    public func stream() -> AsyncThrowingStream<Element, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await value in self { continuation.yield(value) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
