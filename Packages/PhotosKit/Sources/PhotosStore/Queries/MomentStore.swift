// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import PhotosDomain
import PhotosModel

/// The queries behind the Library's moments (SPEC §16.1).
extension LibraryStore {
    /// Every item the Library shows (not archived, not in `excludedFolders`), newest first, with its place, its named
    /// people and the labels of the moment activities the device recognised in it. Seven columns of each item plus two
    /// small lookups: well under a second for 100 000 items.
    ///
    /// - Parameter hiddenPeople: people hidden on this device; moments are not named after them.
    public func momentItems(excludedFolders: [String] = [], hiddenPeople: Set<String> = []) async throws -> [MomentItem] {
        let (sql, arguments) = Self.sql(
            for: .all, excludedPrefixes: excludedFolders,
            columns:
                "media.fileId, \(Self.timestamp) AS timestamp, media.isFavorite, media.place, media.placeCountry, media.latitude, media.longitude"
        )
        return try await database.writer.read { db in
            var items: [MomentItem] = []
            var index: [FileID: Int] = [:]
            let rows = try Row.fetchCursor(db, sql: sql, arguments: arguments)
            while let row = try rows.next() {
                let fileId: FileID = row[0]
                index[fileId] = items.count
                items.append(
                    MomentItem(
                        fileId: fileId, timestamp: Date(timeIntervalSince1970: row[1] ?? 0), isFavorite: row[2], place: row[3],
                        country: row[4], location: GeoPoint(latitude: row[5], longitude: row[6])))
            }
            guard !items.isEmpty else { return items }
            // Unnamed Recognize clusters are numbers: nothing to name a moment after.
            let people = try Row.fetchCursor(
                db, sql: "SELECT DISTINCT fileId, person FROM personItem WHERE person GLOB '*[^0-9]*'")
            while let row = try people.next() {
                let person: String = row[1]
                guard let position = index[row[0]], !hiddenPeople.contains(person) else { continue }
                items[position].people.append(person)
            }
            // Only rows that can name an activity, and only labels of the picture as it is now (same ETag).
            let words = MomentActivity.allLabels.sorted()
            let condition = words.map { _ in "instr(visionLabel.labels, ?) > 0" }.joined(separator: " OR ")
            let labels = try Row.fetchCursor(
                db,
                sql: """
                    SELECT visionLabel.fileId, visionLabel.labels FROM visionLabel
                    JOIN media ON media.fileId = visionLabel.fileId AND media.etag = visionLabel.etag WHERE \(condition)
                    """, arguments: StatementArguments(words))
            while let row = try labels.next() {
                guard let position = index[row[0]] else { continue }
                let text: String = row[1]
                items[position].labels = Set(text.split(separator: " ").map(String.init)).intersection(MomentActivity.allLabels)
            }
            return items
        }
    }
}

/// Moment titles a language model worded on this device (SPEC §16.1), kept so that they are worded once: by moment id,
/// with the facts they were worded from (`MomentFacts.key`). A title whose facts changed is worded again. Migration
/// `v6-library-moment-titles`.
public struct MomentTitleStore: Sendable {
    public let database: AccountDatabase

    public init(database: AccountDatabase) {
        self.database = database
    }

    static func migrate(_ db: Database) throws {
        try db.create(table: "momentTitle") { t in
            t.primaryKey("id", .text)
            t.column("facts", .text).notNull()
            t.column("title", .text).notNull()
            t.column("createdAt", .double).notNull()
        }
    }

    /// The stored titles of these moments whose facts are still the same, by moment id.
    public func titles(for moments: [(id: String, facts: String)]) async throws -> [String: String] {
        guard !moments.isEmpty else { return [:] }
        let wanted = Dictionary(moments.map { ($0.id, $0.facts) }, uniquingKeysWith: { first, _ in first })
        return try await database.writer.read { db in
            var result: [String: String] = [:]
            let rows = try Row.fetchCursor(db, sql: "SELECT id, facts, title FROM momentTitle")
            while let row = try rows.next() {
                let id: String = row[0]
                let facts: String = row[1]
                if wanted[id] == facts { result[id] = row[2] }
            }
            return result
        }
    }

    public func save(id: String, facts: String, title: String, now: Date = Date()) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO momentTitle(id, facts, title, createdAt) VALUES (?, ?, ?, ?)",
                arguments: [id, facts, title, now.timeIntervalSince1970])
        }
    }

    /// Forgets every worded title (the setting was turned off, or the account's data is reset).
    public func removeAll() async throws {
        try await database.writer.write { db in try db.execute(sql: "DELETE FROM momentTitle") }
    }
}
