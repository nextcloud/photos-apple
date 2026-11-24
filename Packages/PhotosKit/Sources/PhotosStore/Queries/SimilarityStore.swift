// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import PhotosDomain
import PhotosModel

/// What this device worked out about a photo's picture for "Show Similar" and the key photos of the Library's zoom levels
/// (SPEC §15.5): its Vision feature print, a 128-byte sketch of it, and Vision's aesthetics score. Computed from cached
/// previews (`SimilarityIndexer`), stored per version of the file, never uploaded.
public struct SimilarityStore: Sendable {
    public let database: AccountDatabase

    public init(database: AccountDatabase) {
        self.database = database
    }

    /// Table `similarity`, one row per indexed photo. A photo that could not be analysed keeps a row without a print, so
    /// it is not tried again until its file changes. Rows of deleted photos go with them (trigger).
    static func migrate(_ db: Database) throws {
        try db.create(table: "similarity") { t in
            t.primaryKey("fileId", .integer)
            t.column("etag", .text).notNull()
            t.column("print", .blob)
            t.column("sketch", .blob)
            t.column("quality", .double)
            t.column("isUtility", .boolean).notNull().defaults(to: false)
            t.column("indexedAt", .double).notNull()
        }
        // Loading the sketches after a launch reads them in the order they were added.
        try db.create(index: "similarity_indexedAt", on: "similarity", columns: ["indexedAt"])
        try db.execute(
            sql: """
                CREATE TRIGGER media_similarity_delete AFTER DELETE ON media BEGIN
                    DELETE FROM similarity WHERE fileId = OLD.fileId;
                END
                """)
    }

    /// A photo that can be indexed.
    public struct Candidate: Sendable, Hashable {
        public var fileId: FileID
        public var etag: String

        public init(fileId: FileID, etag: String) {
            self.fileId = fileId
            self.etag = etag
        }
    }

    /// What the analysis of one photo found; nil print: it could not be analysed.
    public struct Analysis: Sendable, Equatable {
        public var print: [Float]?
        public var sketch: [Int8]?
        public var quality: Float?
        public var isUtility: Bool

        public init(print: [Float]?, sketch: [Int8]?, quality: Float?, isUtility: Bool) {
            self.print = print
            self.sketch = sketch
            self.quality = quality
            self.isUtility = isUtility
        }

        public static let failed = Analysis(print: nil, sketch: nil, quality: nil, isUtility: false)
    }

    /// Images without an analysis of their current version, by descending file id (roughly newest uploads first), after
    /// `before`: a run pages through them and skips what it cannot do now (no cached preview) without asking again.
    public func candidates(limit: Int, before: FileID? = nil) throws -> [Candidate] {
        try database.writer.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT media.fileId, media.etag FROM media LEFT JOIN similarity ON similarity.fileId = media.fileId
                    WHERE media.kind = 'image' AND media.isLivePhotoVideo = 0 AND media.hasPreview = 1 AND media.fileId < ?
                        AND (similarity.fileId IS NULL OR similarity.etag <> media.etag)
                    ORDER BY media.fileId DESC LIMIT ?
                    """, arguments: [before ?? FileID.max, limit]
            )
            .map { Candidate(fileId: $0["fileId"], etag: $0["etag"]) }
        }
    }

    /// Stores analyses (failed ones too).
    public func save(_ results: [(candidate: Candidate, analysis: Analysis)], at date: Date = Date()) throws {
        guard !results.isEmpty else { return }
        try database.writer.write { db in
            for (candidate, analysis) in results {
                try db.execute(
                    sql: """
                        INSERT INTO similarity(fileId, etag, print, sketch, quality, isUtility, indexedAt) VALUES (?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(fileId) DO UPDATE SET etag = excluded.etag, print = excluded.print, sketch = excluded.sketch,
                            quality = excluded.quality, isUtility = excluded.isUtility, indexedAt = excluded.indexedAt
                        """,
                    arguments: [
                        candidate.fileId, candidate.etag, analysis.print.map(Self.data(floats:)), analysis.sketch.map(Self.data(bytes:)),
                        analysis.quality.map { Double($0) }, analysis.isUtility, date.timeIntervalSince1970,
                    ])
            }
        }
    }

    /// The sketches of current versions, in the order they were indexed, from `since` on (incremental loading).
    public func sketches(since: Date? = nil) throws -> [(fileId: FileID, sketch: [Int8], indexedAt: Date)] {
        try database.writer.read { db in
            let rows = try Row.fetchCursor(
                db,
                sql: """
                    SELECT similarity.fileId, similarity.sketch, similarity.indexedAt FROM similarity
                    JOIN media ON media.fileId = similarity.fileId AND media.etag = similarity.etag
                    WHERE similarity.sketch IS NOT NULL AND similarity.indexedAt >= ?
                    ORDER BY similarity.indexedAt
                    """, arguments: [since?.timeIntervalSince1970 ?? 0])
            var result: [(FileID, [Int8], Date)] = []
            while let row = try rows.next() {
                let data: Data = row["sketch"]
                result.append((row["fileId"], Self.bytes(data), Date(timeIntervalSince1970: row["indexedAt"])))
            }
            return result
        }
    }

    /// Full prints of current versions (re-ranking a search).
    public func prints(of fileIds: [FileID]) throws -> [FileID: [Float]] {
        guard !fileIds.isEmpty else { return [:] }
        return try database.writer.read { db in
            var result: [FileID: [Float]] = [:]
            for start in stride(from: 0, to: fileIds.count, by: 500) {
                let chunk = Array(fileIds[start..<min(start + 500, fileIds.count)])
                let marks = chunk.map { _ in "?" }.joined(separator: ",")
                for row in try Row.fetchAll(
                    db,
                    sql: """
                        SELECT similarity.fileId, similarity.print FROM similarity
                        JOIN media ON media.fileId = similarity.fileId AND media.etag = similarity.etag
                        WHERE similarity.print IS NOT NULL AND similarity.fileId IN (\(marks))
                        """, arguments: StatementArguments(chunk))
                {
                    let data: Data = row["print"]
                    result[row["fileId"]] = Self.floats(data)
                }
            }
            return result
        }
    }

    /// Aesthetics scores of the indexed photos (key photos of the zoom levels).
    public func qualities() throws -> [FileID: (quality: Float, isUtility: Bool)] {
        try database.writer.read { db in
            var result: [FileID: (Float, Bool)] = [:]
            let rows = try Row.fetchCursor(db, sql: "SELECT fileId, quality, isUtility FROM similarity WHERE quality IS NOT NULL")
            while let row = try rows.next() {
                let quality: Double = row["quality"]
                result[row["fileId"]] = (Float(quality), row["isUtility"])
            }
            return result
        }
    }

    /// How many images are indexed (with or without a print) and how many there are (the Similar screen, Settings).
    public func progress() throws -> (indexed: Int, total: Int) {
        try database.writer.read { db in
            let total =
                try Int.fetchOne(
                    db, sql: "SELECT count(*) FROM media WHERE kind = 'image' AND isLivePhotoVideo = 0 AND hasPreview = 1") ?? 0
            let indexed =
                try Int.fetchOne(
                    db,
                    sql: """
                        SELECT count(*) FROM similarity JOIN media ON media.fileId = similarity.fileId AND media.etag = similarity.etag
                        WHERE media.kind = 'image' AND media.isLivePhotoVideo = 0 AND media.hasPreview = 1
                        """) ?? 0
            return (indexed, total)
        }
    }

    /// Ids of indexed photos that are no longer current (deleted rows go by trigger; this finds changed versions).
    public func staleIds() throws -> Set<FileID> {
        try database.writer.read { db in
            Set(
                try FileID.fetchAll(
                    db,
                    sql:
                        "SELECT similarity.fileId FROM similarity LEFT JOIN media ON media.fileId = similarity.fileId WHERE media.fileId IS NULL OR media.etag <> similarity.etag"
                ))
        }
    }

    /// Forgets everything (the user turned the feature off).
    public func deleteAll() throws {
        try database.writer.write { db in try db.execute(sql: "DELETE FROM similarity") }
    }

    // MARK: Encoding

    static func data(floats: [Float]) -> Data {
        floats.map { $0.bitPattern.littleEndian }.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func floats(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<UInt32>.size
        var result = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            for index in 0..<count {
                result[index] = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)))
            }
        }
        return result
    }

    static func data(bytes: [Int8]) -> Data {
        bytes.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func bytes(_ data: Data) -> [Int8] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Int8.self)) }
    }
}
