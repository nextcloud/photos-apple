// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import PhotosDomain
import PhotosModel
import Synchronization

/// Descriptions of photos written on this device (SPEC §16.2), one per version of a file, in table `photoDescription`
/// (migration `v6-search-descriptions`). They are searched with the rest of the index and read by VoiceOver. Never
/// uploaded; turning the feature off deletes them.
public struct PhotoDescriptionStore: Sendable {
    public let database: AccountDatabase

    public init(database: AccountDatabase) {
        self.database = database
    }

    /// A photo that can be described.
    public struct Candidate: Sendable, Hashable {
        public var fileId: FileID
        public var etag: String

        public init(fileId: FileID, etag: String) {
            self.fileId = fileId
            self.etag = etag
        }
    }

    /// What describing one photo gave; a nil text marks a photo that could not be described.
    public struct Result: Sendable, Equatable {
        public var text: String?
        public var language: String?
        public var source: PhotoDescription.Source

        public init(text: String?, language: String?, source: PhotoDescription.Source) {
            self.text = text
            self.language = language
            self.source = source
        }

        public static let failed = Result(text: nil, language: nil, source: .vision)
    }

    /// A stored description.
    public struct Entry: Sendable, Equatable {
        public var text: String
        public var language: String?
        public var source: PhotoDescription.Source
    }

    /// Photos without a description of their current version, newest file ids first, after `before` (a run pages
    /// through them and skips what it cannot do now, a photo without a cached preview, without asking again).
    public func candidates(limit: Int, before: FileID? = nil) throws -> [Candidate] {
        try database.writer.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT media.fileId, media.etag FROM media LEFT JOIN photoDescription ON photoDescription.fileId = media.fileId
                    WHERE media.kind = 'image' AND media.isLivePhotoVideo = 0 AND media.hasPreview = 1 AND media.fileId < ?
                        AND (photoDescription.fileId IS NULL OR photoDescription.etag <> media.etag)
                    ORDER BY media.fileId DESC LIMIT ?
                    """, arguments: [before ?? FileID.max, limit]
            )
            .map { Candidate(fileId: $0["fileId"], etag: $0["etag"]) }
        }
    }

    /// Stores results (failed ones too).
    public func save(_ results: [(candidate: Candidate, result: Result)], at date: Date = Date()) throws {
        guard !results.isEmpty else { return }
        try database.writer.write { db in
            for (candidate, result) in results {
                try db.execute(
                    sql: """
                        INSERT INTO photoDescription(fileId, etag, text, language, source, describedAt) VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT(fileId) DO UPDATE SET etag = excluded.etag, text = excluded.text, language = excluded.language,
                            source = excluded.source, describedAt = excluded.describedAt
                        """,
                    arguments: [
                        candidate.fileId, candidate.etag, result.text, result.language, result.source.rawValue, date.timeIntervalSince1970,
                    ])
            }
        }
    }

    /// The description of the file's current version.
    public func description(of fileId: FileID) throws -> Entry? {
        try descriptions(of: [fileId])[fileId]
    }

    /// The descriptions of the files' current versions.
    public func descriptions(of fileIds: [FileID]) throws -> [FileID: Entry] {
        guard !fileIds.isEmpty else { return [:] }
        return try database.writer.read { db in
            var result: [FileID: Entry] = [:]
            for start in stride(from: 0, to: fileIds.count, by: 500) {
                let chunk = Array(fileIds[start..<min(start + 500, fileIds.count)])
                let marks = chunk.map { _ in "?" }.joined(separator: ",")
                for row in try Row.fetchAll(
                    db,
                    sql: """
                        SELECT photoDescription.fileId, photoDescription.text, photoDescription.language, photoDescription.source
                        FROM photoDescription JOIN media ON media.fileId = photoDescription.fileId AND media.etag = photoDescription.etag
                        WHERE photoDescription.text IS NOT NULL AND photoDescription.fileId IN (\(marks))
                        """, arguments: StatementArguments(chunk))
                {
                    let source = PhotoDescription.Source(rawValue: row["source"]) ?? .vision
                    result[row["fileId"]] = Entry(text: row["text"], language: row["language"], source: source)
                }
            }
            return result
        }
    }

    /// How many photos have been looked at (described or not) and how many there are (Settings).
    public func progress() throws -> (described: Int, total: Int) {
        try database.writer.read { db in
            let total =
                try Int.fetchOne(
                    db, sql: "SELECT count(*) FROM media WHERE kind = 'image' AND isLivePhotoVideo = 0 AND hasPreview = 1") ?? 0
            let described =
                try Int.fetchOne(
                    db,
                    sql: """
                        SELECT count(*) FROM photoDescription
                        JOIN media ON media.fileId = photoDescription.fileId AND media.etag = photoDescription.etag
                        WHERE media.kind = 'image' AND media.isLivePhotoVideo = 0 AND media.hasPreview = 1
                        """) ?? 0
            return (described, total)
        }
    }

    /// Words photos are known to show, for reading searches (`NaturalSearch.Vocabulary.labels`): the labels this device
    /// recognised (`visionLabel`). At most `limit`, the most frequent first.
    public func knownLabels(limit: Int = 2000) throws -> [String] {
        try database.writer.read { db in
            var counts: [String: Int] = [:]
            let rows = try String.fetchCursor(db, sql: "SELECT labels FROM visionLabel")
            while let labels = try rows.next() {
                for label in labels.split(separator: " ") where label.count >= 3 { counts[String(label), default: 0] += 1 }
            }
            return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(limit).map(\.key)
        }
    }

    /// Forgets every description (the user turned the feature off). The index rows are written again without them.
    public func deleteAll() throws {
        try database.writer.write { db in try db.execute(sql: "DELETE FROM photoDescription") }
    }
}

/// The descriptions the grid's tiles read for VoiceOver, kept in memory as they are asked for (SPEC §16.2). A tile asks
/// on the main thread while it is configured: a hit costs a dictionary lookup, a miss one read by primary key.
public final class PhotoDescriptionLookup: Sendable {
    let store: PhotoDescriptionStore
    /// The stored description per file id (its text empty when a file has none). Cleared when it grows past `capacity`.
    private let cache = Mutex<[FileID: Entry]>([:])
    private let enabled = Atomic<Bool>(true)
    static let capacity = 4000

    struct Entry {
        var text: String
        var language: String?
    }

    public init(database: AccountDatabase) {
        store = PhotoDescriptionStore(database: database)
    }

    /// Whether descriptions are used at all (the setting).
    public var isEnabled: Bool {
        get { enabled.load(ordering: .relaxed) }
        set { enabled.store(newValue, ordering: .relaxed) }
    }

    /// The description of the file's current version, if this device wrote one in `language` (a description in
    /// another language is not read out: VoiceOver would read English words with the voice of the user's language).
    public func text(of fileId: FileID, language: String? = Locale.current.language.languageCode?.identifier) -> String? {
        guard isEnabled else { return nil }
        let entry: Entry
        if let known = cache.withLock({ $0[fileId] }) {
            entry = known
        } else {
            let stored = try? store.description(of: fileId)
            entry = Entry(text: stored?.text ?? "", language: stored?.language)
            cache.withLock { cache in
                if cache.count >= Self.capacity { cache.removeAll(keepingCapacity: true) }
                cache[fileId] = entry
            }
        }
        guard !entry.text.isEmpty else { return nil }
        if let language, let written = entry.language, written != language { return nil }
        return entry.text
    }

    /// Forgets what is cached for these files (they were just described) or for all.
    public func invalidate(_ fileIds: [FileID]? = nil) {
        cache.withLock { cache in
            if let fileIds {
                for id in fileIds { cache[id] = nil }
            } else {
                cache.removeAll()
            }
        }
    }
}
