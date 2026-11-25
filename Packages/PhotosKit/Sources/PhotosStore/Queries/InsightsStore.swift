// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import PhotosDomain
import PhotosModel

/// The camera data of the library's photos for Insights (SPEC §16.5.1): one row per photo whose EXIF was read from
/// the server, with the ETag it was read at. Filled lazily in the background (`ExifIndexing`); a photo whose ETag
/// changed is read again.
public struct InsightsStore: Sendable {
    public let database: AccountDatabase

    public init(database: AccountDatabase) {
        self.database = database
    }

    static func migrate(_ db: Database) throws {
        try db.create(table: "photoExif") { t in
            t.primaryKey("fileId", .integer)
            t.column("etag", .text).notNull()
            t.column("camera", .text)
            t.column("lens", .text)
            t.column("focalLength", .double)
            t.column("focalLength35", .double)
            t.column("aperture", .double)
            t.column("iso", .integer)
            t.column("exposure", .double)
            t.column("hour", .integer)
            t.column("fetchedAt", .double).notNull()
        }
        try db.create(index: "photoExif_camera", on: "photoExif", columns: ["camera"])
        try db.create(index: "photoExif_lens", on: "photoExif", columns: ["lens"])
    }

    /// A photo whose EXIF is still to be read.
    public struct Pending: Sendable, Hashable {
        public var fileId: FileID
        public var etag: String
        public var path: String
        public var capturedAt: Date?
        public var captureOffset: Int?

        public init(fileId: FileID, etag: String, path: String, capturedAt: Date? = nil, captureOffset: Int? = nil) {
            self.fileId = fileId
            self.etag = etag
            self.path = path
            self.capturedAt = capturedAt
            self.captureOffset = captureOffset
        }
    }

    /// Photos of the library (not archived, not in `.nomedia` folders, no videos: they have no EXIF).
    static func libraryCondition(excludedFolders: [String]) -> (String, StatementArguments) {
        var conditions = ["media.kind = 'image'", LibraryStore.visible]
        var arguments: StatementArguments = []
        for prefix in excludedFolders {
            conditions.append("media.path NOT LIKE ? ESCAPE '\\'")
            arguments += [LibraryStore.likePrefix(prefix)]
        }
        return (conditions.joined(separator: " AND "), arguments)
    }

    /// The photos without camera data, or with data read at another ETag; newest first (they are the ones people look
    /// at first).
    public func pending(limit: Int, excludedFolders: [String] = []) throws -> [Pending] {
        let (condition, arguments) = Self.libraryCondition(excludedFolders: excludedFolders)
        return try database.writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT media.fileId, media.etag, media.path, media.capturedAt, media.captureOffset FROM media
                    LEFT JOIN photoExif ON photoExif.fileId = media.fileId
                    WHERE \(condition) AND (photoExif.fileId IS NULL OR photoExif.etag <> media.etag)
                    ORDER BY media.timestamp DESC LIMIT ?
                    """, arguments: arguments + [limit])
            return rows.map { row in
                Pending(
                    fileId: row["fileId"], etag: row["etag"], path: row["path"],
                    capturedAt: (row["capturedAt"] as Double?).map { Date(timeIntervalSince1970: $0) }, captureOffset: row["captureOffset"])
            }
        }
    }

    /// How far reading the camera data has come: photos with data, and photos of the library.
    public func progress(excludedFolders: [String] = []) async throws -> (analysed: Int, total: Int) {
        let (condition, arguments) = Self.libraryCondition(excludedFolders: excludedFolders)
        return try await database.writer.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) AS total, COUNT(photoExif.fileId) AS analysed FROM media
                    LEFT JOIN photoExif ON photoExif.fileId = media.fileId AND photoExif.etag = media.etag
                    WHERE \(condition)
                    """, arguments: arguments)
            return (row?["analysed"] ?? 0, row?["total"] ?? 0)
        }
    }

    /// Stores what was read, keyed by file id with the ETag it was read at. A photo without any camera data gets a row
    /// too, so it is not asked for again.
    public func store(_ facts: [FileID: (etag: String, facts: ExifFacts)], at date: Date = Date()) throws {
        guard !facts.isEmpty else { return }
        try database.writer.write { db in
            let statement = try db.makeStatement(
                sql: """
                    INSERT OR REPLACE INTO photoExif
                    (fileId, etag, camera, lens, focalLength, focalLength35, aperture, iso, exposure, hour, fetchedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """)
            for (fileId, value) in facts {
                let f = value.facts
                try statement.execute(arguments: [
                    fileId, value.etag, f.camera, f.lens, f.focalLength, f.focalLength35, f.aperture, f.iso, f.exposure, f.hour,
                    date.timeIntervalSince1970,
                ])
            }
        }
    }

    /// Rows of files that are no longer in the index.
    public func removeOrphans() throws {
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM photoExif WHERE fileId NOT IN (SELECT fileId FROM media)")
        }
    }

    static func facts(_ row: Row) -> ExifFacts {
        ExifFacts(
            camera: row["camera"], lens: row["lens"], focalLength: row["focalLength"], focalLength35: row["focalLength35"],
            aperture: row["aperture"], iso: row["iso"], exposure: row["exposure"], hour: row["hour"])
    }

    /// The camera data of one photo, when it was read at this ETag.
    public func facts(of fileId: FileID, etag: String) async throws -> ExifFacts? {
        try await database.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM photoExif WHERE fileId = ? AND etag = ?", arguments: [fileId, etag]).map(Self.facts)
        }
    }

    /// Every analysed photo of the library with its rating and flag, for `PhotoInsights.summarize`.
    public func rows(excludedFolders: [String] = []) async throws -> [InsightsRow] {
        let (condition, arguments) = Self.libraryCondition(excludedFolders: excludedFolders)
        return try await database.writer.read { db in
            let marks = try CullingStore.fetchMarks(db)
            var result: [InsightsRow] = []
            let rows = try Row.fetchCursor(
                db,
                sql: """
                    SELECT photoExif.* FROM photoExif JOIN media ON media.fileId = photoExif.fileId WHERE \(condition)
                    """, arguments: arguments)
            while let row = try rows.next() {
                let fileId: FileID = row["fileId"]
                result.append(InsightsRow(facts: Self.facts(row), mark: marks[fileId] ?? .none))
            }
            return result
        }
    }

    /// The SQL condition (on `photoExif` and `media`) of a filter; the same rules as `InsightsFilter.matches`.
    static func condition(for filter: InsightsFilter) -> (String, StatementArguments) {
        func range(_ column: String, _ scale: StopScale, _ stop: Double) -> (String, StatementArguments) {
            let bounds = scale.range(of: stop)
            if bounds.upper.isInfinite { return ("\(column) >= ?", [bounds.lower]) }
            return ("\(column) >= ? AND \(column) < ?", [bounds.lower, bounds.upper])
        }
        switch filter {
        case .camera(let name): return ("photoExif.camera = ?", [name])
        case .lens(let name): return ("photoExif.lens = ?", [name])
        case .focalLength(let stop):
            return range("coalesce(photoExif.focalLength35, photoExif.focalLength)", .focalLength, stop)
        case .aperture(let stop): return range("photoExif.aperture", .aperture, stop)
        case .iso(let stop): return range("photoExif.iso", .iso, stop)
        case .shutter(let stop): return range("photoExif.exposure", .shutter, stop)
        case .hour(let hour): return ("photoExif.hour = ?", [hour])
        case .keepers(let lens, let camera):
            // Pick wins over Rejected; three stars or more count unless rejected (`PhotoInsights.isKeeper`).
            let (picked, pickArguments) = CullingStore.filesWith([CullingTags.pick])
            let (rated, ratedArguments) = CullingStore.filesWith(Array(CullingTags.ratingNames.dropFirst(2)))
            let (rejected, rejectedArguments) = CullingStore.filesWith([CullingTags.rejected])
            let keeper = """
                (media.fileId IN (\(picked)) OR (media.fileId IN (\(rated)) AND media.fileId NOT IN (\(rejected))))
                """
            let source: String
            var arguments: StatementArguments
            if let lens {
                source = "photoExif.lens = ?"
                arguments = [lens]
            } else {
                source = "photoExif.lens IS NULL AND photoExif.camera = ?"
                arguments = [camera ?? ""]
            }
            arguments += pickArguments + ratedArguments + rejectedArguments
            return ("\(source) AND \(keeper)", arguments)
        }
    }

    /// The photos of a filter, newest first.
    public func items(matching filter: InsightsFilter, excludedFolders: [String] = []) async throws -> [MediaItem] {
        let (library, libraryArguments) = Self.libraryCondition(excludedFolders: excludedFolders)
        let (condition, arguments) = Self.condition(for: filter)
        return try await database.writer.read { db in
            try MediaItem.fetchAll(
                db,
                sql: """
                    SELECT media.* FROM media JOIN photoExif ON photoExif.fileId = media.fileId
                    WHERE \(library) AND \(condition) \(LibraryStore.displayOrder)
                    """, arguments: libraryArguments + arguments)
        }
    }
}
