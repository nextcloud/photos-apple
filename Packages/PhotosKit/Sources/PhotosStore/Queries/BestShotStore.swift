// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import PhotosDomain
import PhotosModel

/// What this device found out about photos to choose the best shot of a burst or a series (SPEC §21.4,
/// `BestShot.Signals`): stored per version of the file, computed from previews (`BestShotAnalysis`), never uploaded.
public struct BestShotStore: Sendable {
    public let database: AccountDatabase

    public init(database: AccountDatabase) {
        self.database = database
    }

    /// Table `bestShot`, one row per analysed photo: the signals as JSON (a handful of numbers and the faces), the
    /// version of the analysis, and when. A photo that could not be analysed keeps a row without signals, so it is not
    /// tried again until its file changes. Rows go with their photos (trigger).
    static func migrate(_ db: Database) throws {
        try db.create(table: "bestShot") { t in
            t.primaryKey("fileId", .integer)
            t.column("etag", .text).notNull()
            t.column("signals", .text)
            t.column("version", .integer).notNull()
            t.column("analysedAt", .double).notNull()
        }
        try db.execute(
            sql: """
                CREATE TRIGGER media_bestShot_delete AFTER DELETE ON media BEGIN
                    DELETE FROM bestShot WHERE fileId = OLD.fileId;
                END
                """)
    }

    /// A photo to analyse.
    public struct Candidate: Sendable, Hashable {
        public var fileId: FileID
        public var etag: String

        public init(fileId: FileID, etag: String) {
            self.fileId = fileId
            self.etag = etag
        }
    }

    /// Stores what the analysis found; nil: the photo could not be analysed.
    public func save(_ results: [(candidate: Candidate, signals: BestShot.Signals?)], at date: Date = Date()) throws {
        guard !results.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try database.writer.write { db in
            for (candidate, signals) in results {
                let json = try signals.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
                try db.execute(
                    sql: """
                        INSERT INTO bestShot(fileId, etag, signals, version, analysedAt) VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(fileId) DO UPDATE SET etag = excluded.etag, signals = excluded.signals,
                            version = excluded.version, analysedAt = excluded.analysedAt
                        """,
                    arguments: [
                        candidate.fileId, candidate.etag, json, signals?.version ?? BestShot.Signals.currentVersion,
                        date.timeIntervalSince1970,
                    ])
            }
        }
    }

    /// The signals of the current versions of `fileIds`, where they were analysed with the current analysis.
    public func signals(of fileIds: [FileID]) throws -> [FileID: BestShot.Signals] {
        guard !fileIds.isEmpty else { return [:] }
        return try database.writer.read { db in try Self.signals(db, of: fileIds) }
    }

    static func signals(_ db: Database, of fileIds: [FileID]) throws -> [FileID: BestShot.Signals] {
        let decoder = JSONDecoder()
        var result: [FileID: BestShot.Signals] = [:]
        for start in stride(from: 0, to: fileIds.count, by: 500) {
            let chunk = Array(fileIds[start..<min(start + 500, fileIds.count)])
            let marks = chunk.map { _ in "?" }.joined(separator: ",")
            for row in try Row.fetchAll(
                db,
                sql: """
                    SELECT bestShot.fileId, bestShot.signals FROM bestShot
                    JOIN media ON media.fileId = bestShot.fileId AND media.etag = bestShot.etag
                    WHERE bestShot.signals IS NOT NULL AND bestShot.version = \(BestShot.Signals.currentVersion)
                        AND bestShot.fileId IN (\(marks))
                    """, arguments: StatementArguments(chunk))
            {
                let json: String = row["signals"]
                if let signals = try? decoder.decode(BestShot.Signals.self, from: Data(json.utf8)) { result[row["fileId"]] = signals }
            }
        }
        return result
    }

    /// Which of `fileIds` still need an analysis (none of the current version of the file and of the analysis), with
    /// their ETags. Photos that failed are not asked for again.
    public func missing(_ fileIds: [FileID]) throws -> [Candidate] {
        guard !fileIds.isEmpty else { return [] }
        return try database.writer.read { db in
            var result: [Candidate] = []
            for start in stride(from: 0, to: fileIds.count, by: 500) {
                let chunk = Array(fileIds[start..<min(start + 500, fileIds.count)])
                let marks = chunk.map { _ in "?" }.joined(separator: ",")
                for row in try Row.fetchAll(
                    db,
                    sql: """
                        SELECT media.fileId, media.etag FROM media LEFT JOIN bestShot ON bestShot.fileId = media.fileId
                        WHERE media.fileId IN (\(marks)) AND media.kind = 'image'
                            AND (bestShot.fileId IS NULL OR bestShot.etag <> media.etag
                                OR bestShot.version <> \(BestShot.Signals.currentVersion))
                        """, arguments: StatementArguments(chunk))
                {
                    result.append(Candidate(fileId: row["fileId"], etag: row["etag"]))
                }
            }
            // In the order asked for.
            let order = Dictionary(fileIds.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
            return result.sorted { (order[$0.fileId] ?? 0) < (order[$1.fileId] ?? 0) }
        }
    }

    /// How many photos have been analysed (Settings).
    public func count() throws -> Int {
        try database.writer.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM bestShot WHERE signals IS NOT NULL") ?? 0 }
    }

    /// Forgets everything (the user turned "Find similar photos" off).
    public func deleteAll() throws {
        try database.writer.write { db in try db.execute(sql: "DELETE FROM bestShot") }
    }
}

/// The evidence the timeline's burst stacking reads (`BurstEvidence`): the sketches "Show Similar" stored and the
/// best-shot signals, straight from the account's database. Only asked about the few quick runs of photos and the
/// frames of bursts, so a timeline of 100 000 photos costs a handful of small reads.
public struct StoredBurstEvidence: BurstEvidence {
    let database: AccountDatabase

    public init(database: AccountDatabase) {
        self.database = database
    }

    public func sketches(of ids: [FileID]) -> [FileID: [Float]] {
        guard !ids.isEmpty else { return [:] }
        return
            (try? database.writer.read { db in
                var result: [FileID: [Float]] = [:]
                for start in stride(from: 0, to: ids.count, by: 500) {
                    let chunk = Array(ids[start..<min(start + 500, ids.count)])
                    let marks = chunk.map { _ in "?" }.joined(separator: ",")
                    for row in try Row.fetchAll(
                        db,
                        sql: """
                            SELECT similarity.fileId, similarity.sketch FROM similarity
                            JOIN media ON media.fileId = similarity.fileId AND media.etag = similarity.etag
                            WHERE similarity.sketch IS NOT NULL AND similarity.fileId IN (\(marks))
                            """, arguments: StatementArguments(chunk))
                    {
                        let data: Data = row["sketch"]
                        result[row["fileId"]] = SimilarityStore.bytes(data).map(Float.init)
                    }
                }
                return result
            }) ?? [:]
    }

    public func signals(of ids: [FileID]) -> [FileID: BestShot.Signals] {
        guard !ids.isEmpty else { return [:] }
        return (try? database.writer.read { db in try BestShotStore.signals(db, of: ids) }) ?? [:]
    }
}

// MARK: - Memory covers

extension LibraryStore {
    /// Memories looked at for a better cover, newest first (the strip shows a few; the rest keep their cover).
    static let coveredMemories = 40
    /// Photos of one memory looked at: all its favourites, and evenly spread others up to this many.
    static let coverCandidates = 600

    /// The covers of memories (SPEC §21.4): the photo with the best key-photo score (`KeyPhoto.score`: favourites first,
    /// then Vision's aesthetics score, no screenshots or documents) plus the faces' bonus (`BestShot.coverBonus`: open
    /// eyes and smiles), where this device analysed the photos. A memory none of whose photos is analysed keeps the
    /// cover its algorithm chose, and so does one where the cover is as good as any.
    static func chooseCovers(_ snapshot: inout MemoriesSnapshot, _ db: Database) throws {
        // Nothing analysed on this device (a new device, or "Find similar photos" off): nothing to do.
        guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM similarity WHERE quality IS NOT NULL)") == true else { return }
        var budget = coveredMemories
        func improve(_ memory: Memory) throws -> Memory {
            guard budget > 0 else { return memory }
            budget -= 1
            return try betterCover(memory, db)
        }
        snapshot.onThisDay = try snapshot.onThisDay.map(improve)
        if let recap = snapshot.recap { snapshot.recap = try improve(recap) }
        snapshot.trips = try snapshot.trips.map(improve)
    }

    static func betterCover(_ memory: Memory, _ db: Database) throws -> Memory {
        var ids = memory.items
        if ids.count > coverCandidates {
            let step = Double(ids.count) / Double(coverCandidates)
            ids = (0..<coverCandidates).map { memory.items[Int(Double($0) * step)] }
        }
        if !ids.contains(memory.cover) { ids.append(memory.cover) }
        let decoder = JSONDecoder()
        var scores: [FileID: Float] = [:]
        var analysed = false
        for start in stride(from: 0, to: ids.count, by: 500) {
            let chunk = Array(ids[start..<min(start + 500, ids.count)])
            let marks = chunk.map { _ in "?" }.joined(separator: ",")
            for row in try Row.fetchAll(
                db,
                sql: """
                    SELECT media.fileId, media.isFavorite, media.kind, media.hasPreview, media.width, media.height, media.mimeType,
                        media.blurhash, similarity.quality, similarity.isUtility, bestShot.signals
                    FROM media
                    LEFT JOIN similarity ON similarity.fileId = media.fileId AND similarity.etag = media.etag
                    LEFT JOIN bestShot ON bestShot.fileId = media.fileId AND bestShot.etag = media.etag
                        AND bestShot.version = \(BestShot.Signals.currentVersion)
                    WHERE media.fileId IN (\(marks))
                    """, arguments: StatementArguments(chunk))
            {
                let quality: Double? = row["quality"]
                let width: Int? = row["width"]
                let height: Int? = row["height"]
                let mime: String = row["mimeType"]
                let blurhash: String? = row["blurhash"]
                let kind: String = row["kind"]
                let json: String? = row["signals"]
                let signals = json.flatMap { try? decoder.decode(BestShot.Signals.self, from: Data($0.utf8)) }
                if quality != nil || signals != nil { analysed = true }
                let traits = KeyPhoto.Traits(
                    isFavorite: row["isFavorite"], isVideo: kind == MediaKind.video.rawValue, hasPreview: row["hasPreview"],
                    aspectRatio: width.flatMap { w in height.map { h in h > 0 ? Double(w) / Double(h) : 1 } } ?? 1,
                    isPNG: mime == "image/png", quality: quality.map { Float($0) }, isUtility: row["isUtility"] ?? false,
                    hasBlurhash: blurhash != nil)
                scores[row["fileId"]] = KeyPhoto.score(traits) + BestShot.coverBonus(signals)
            }
        }
        guard analysed, let best = ids.max(by: { (scores[$0] ?? -.infinity) < (scores[$1] ?? -.infinity) }),
            (scores[best] ?? 0) > (scores[memory.cover] ?? -.infinity)
        else { return memory }
        var improved = memory
        improved.cover = best
        return improved
    }
}
