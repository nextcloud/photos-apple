// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import PhotosDomain
import PhotosModel

extension LibraryStore {
    // MARK: Items

    public func item(_ fileId: FileID) throws -> MediaItem? {
        try database.writer.read { db in
            if let item = try MediaItem.fetchOne(db, key: fileId) { return item }
            return try CollectionMediaRecord.fetchOne(db, key: fileId)?.item
        }
    }

    // MARK: Cache key (SPEC §18.1.1) — added by the M9 "load" package

    /// The ETag of a file in the index or of a collection-only item; nil when the library does not know it. Read by the
    /// image pipeline for previews requested without an ETag (covers, memories), one primary-key lookup.
    public func etag(of fileId: FileID) throws -> String? {
        try database.writer.read { db in
            if let etag = try String.fetchOne(db, sql: "SELECT etag FROM media WHERE fileId = ?", arguments: [fileId]) { return etag }
            return try CollectionMediaRecord.fetchOne(db, key: fileId)?.item.etag
        }
    }

    /// Live updates of one item (index or collection-only), e.g. the photo shown in the viewer: its favourite heart
    /// follows a toggle, and the next toggle sends the opposite value.
    public func observeItem(_ fileId: FileID) -> AsyncThrowingStream<MediaItem?, any Error> {
        ValueObservation.tracking { db -> MediaItem? in
            if let item = try MediaItem.fetchOne(db, key: fileId) { return item }
            return try CollectionMediaRecord.fetchOne(db, key: fileId)?.item
        }
        .removeDuplicates()
        .values(in: database.writer)
        .stream()
    }

    public func items(_ fileIds: [FileID]) throws -> [FileID: MediaItem] {
        try database.writer.read { db in try Self.items(db, fileIds) }
    }

    /// `items(_:)` without blocking the caller's actor.
    public func fetchItems(_ fileIds: [FileID]) async throws -> [FileID: MediaItem] {
        try await database.writer.read { db in try Self.items(db, fileIds) }
    }

    static func items(_ db: Database, _ fileIds: [FileID]) throws -> [FileID: MediaItem] {
        var result: [FileID: MediaItem] = [:]
        result.reserveCapacity(fileIds.count)
        // In chunks: a memory or a map area can have more items than SQLite accepts bound values.
        for chunk in fileIds.chunked(5000) {
            for item in try MediaItem.fetchAll(db, keys: chunk) { result[item.fileId] = item }
            let missing = chunk.filter { result[$0] == nil }
            for record in try CollectionMediaRecord.fetchAll(db, keys: missing) { result[record.fileId] = record.item }
        }
        return result
    }

    /// Counts what the actions of a selection depend on, in the database: no item of a selection of 150 000 is loaded.
    public func selectionSummary(_ fileIds: [FileID]) async throws -> SelectionSummary {
        try await database.writer.read { db in try Self.selectionSummary(fileIds, db: db) }
    }

    /// `selectionSummary` for callers that must answer at once (a context menu that opens before the summary arrived).
    public func selectionSummaryNow(_ fileIds: [FileID]) throws -> SelectionSummary {
        try database.writer.read { db in try Self.selectionSummary(fileIds, db: db) }
    }

    static func selectionSummary(_ fileIds: [FileID], db: Database) throws -> SelectionSummary {
        var summary = SelectionSummary()
        for chunk in fileIds.chunked(5000) {
            let list = chunk.map { String($0) }.joined(separator: ",")
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*), TOTAL(isFavorite), TOTAL(instr(permissions, 'D') > 0), TOTAL(instr(permissions, 'W') > 0),
                        TOTAL(mountType = '' AND isArchived = 0 AND instr(permissions, 'D') > 0), TOTAL(isArchived)
                    FROM media WHERE fileId IN (\(list))
                    """)
            if let row {
                summary.count += row[0] as Int
                summary.favorites += Int(row[1] as Double)
                summary.deletable += Int(row[2] as Double)
                summary.writable += Int(row[3] as Double)
                summary.archivable += Int(row[4] as Double)
                summary.archived += Int(row[5] as Double)
            }
            // Items of shared albums and other collections are not in the index.
            let indexed = row.map { $0[0] as Int } ?? 0
            guard indexed < chunk.count else { continue }
            let found = Set(try FileID.fetchAll(db, sql: "SELECT fileId FROM media WHERE fileId IN (\(list))"))
            for record in try CollectionMediaRecord.fetchAll(db, keys: chunk.filter { !found.contains($0) }) { summary.add(record.item) }
        }
        return summary
    }

    /// All visible items as full rows. This is the whole table: only for work that really needs every item (duplicates,
    /// clean-up), and never on the main thread. Search, memories and the map have their own queries.
    public func allVisibleItems() throws -> [MediaItem] {
        try database.writer.read { db in
            try MediaItem.fetchAll(db, sql: "SELECT * FROM media WHERE isLivePhotoVideo = 0 AND isArchived = 0 ORDER BY timestamp DESC")
        }
    }

    /// The visible items that can be exact duplicates of another (SPEC §7.15): another visible item has the same size,
    /// capture second and pixel size. `Duplicates.groups` over these gives the same groups as over the whole library,
    /// without loading every row.
    public func duplicateCandidates() async throws -> [MediaItem] {
        try await database.writer.read { db in
            try MediaItem.fetchAll(
                db,
                sql: """
                    WITH visible AS (
                        SELECT * FROM media
                        WHERE isLivePhotoVideo = 0 AND isArchived = 0 AND size > 0
                            AND capturedAt IS NOT NULL AND width IS NOT NULL AND height IS NOT NULL),
                    keys AS (
                        SELECT size, CAST(capturedAt AS INTEGER) AS second, width, height FROM visible
                        GROUP BY size, second, width, height HAVING COUNT(*) >= 2)
                    SELECT visible.* FROM visible
                    JOIN keys ON keys.size = visible.size AND keys.second = CAST(visible.capturedAt AS INTEGER)
                        AND keys.width = visible.width AND keys.height = visible.height
                    ORDER BY visible.timestamp DESC
                    """)
        }
    }

    /// The visible items that can be "Free up space" candidates (SPEC §7.15): videos, PNGs and images whose name has
    /// the words of a screenshot. `Cleanup.candidates` over these gives the same result as over the whole library;
    /// the exact rules (patterns, phone screen sizes, permissions) stay in `Cleanup`.
    public func cleanupCandidates() async throws -> [MediaItem] {
        // Wider than `Cleanup.screenshotNames` (`%` for the optional separators and the apostrophes and accents).
        let names = ["%screen%shot%", "%bildschirmfoto%", "%capture d%cran%", "%captura de pantalla%", "%schermafbeelding%"]
        let nameClause = names.map { _ in "name LIKE ?" }.joined(separator: " OR ")
        let arguments = StatementArguments([MediaKind.video.rawValue, MediaKind.image.rawValue] + names)
        return try await database.writer.read { db in
            try MediaItem.fetchAll(
                db,
                sql: """
                    SELECT * FROM media
                    WHERE isLivePhotoVideo = 0 AND isArchived = 0
                        AND (kind = ? OR (kind = ? AND (lower(mimeType) = 'image/png' OR \(nameClause))))
                    ORDER BY timestamp DESC
                    """, arguments: arguments)
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
}
