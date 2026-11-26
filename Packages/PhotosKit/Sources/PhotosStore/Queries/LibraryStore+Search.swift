// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import PhotosDomain
import PhotosModel

extension LibraryStore {
    // MARK: Search

    /// The conditions of a search, without the server memberships (those are applied to the rows).
    static func searchSQL(_ search: LibrarySearch, columns: String) -> (String, StatementArguments) {
        var conditions = [visible]
        var arguments: StatementArguments = []
        // Trigram tokens need three characters; shorter words are looked up by scanning the indexed text.
        let terms = search.terms
        let indexed = terms.filter { $0.unicodeScalars.count >= 3 }
        if !indexed.isEmpty {
            conditions.append("media.fileId IN (SELECT rowid FROM searchIndex WHERE searchIndex MATCH ?)")
            arguments += [SearchIndex.matchExpression(indexed)]
        }
        for term in terms where term.unicodeScalars.count < 3 {
            conditions.append("media.fileId IN (SELECT rowid FROM searchIndex WHERE text LIKE ? ESCAPE '\\')")
            arguments += ["%" + likeEscaped(term) + "%"]
        }
        if !search.places.isEmpty {
            conditions.append("media.place IN (\(search.places.map { _ in "?" }.joined(separator: ",")))")
            for place in search.places { arguments += [place] }
        }
        if !search.dateRanges.isEmpty {
            let ranges = search.dateRanges.map { _ in "(\(timestamp) >= ? AND \(timestamp) < ?)" }
            conditions.append("(" + ranges.joined(separator: " OR ") + ")")
            for range in search.dateRanges {
                arguments += [range.lowerBound.timeIntervalSince1970, range.upperBound.timeIntervalSince1970]
            }
        }
        if search.favoritesOnly { conditions.append("media.isFavorite = 1") }
        if search.videosOnly { conditions.append("media.kind = 'video'") }
        if search.photosOnly { conditions.append("media.kind = 'image'") }
        if let stars = search.minimumRating, case let (condition, values)? = CullingStore.condition(for: .rating(atLeast: stars)) {
            conditions.append(condition)
            arguments += values
        }
        if !search.albumIds.isEmpty {
            let marks = search.albumIds.map { _ in "?" }.joined(separator: ",")
            conditions.append("media.fileId IN (SELECT fileId FROM albumItem WHERE albumId IN (\(marks)))")
            for id in search.albumIds { arguments += [id] }
        }
        return ("SELECT \(columns) FROM media WHERE \(conditions.joined(separator: " AND ")) \(displayOrder)", arguments)
    }

    /// Search results as grid rows, newest first.
    public func search(_ search: LibrarySearch) async throws -> [GridMedia] {
        let (sql, arguments) = Self.searchSQL(search, columns: Self.gridColumns)
        return try await database.writer.read { db in
            var result: [GridMedia] = []
            let rows = try Row.fetchCursor(db, sql: sql, arguments: arguments)
            while let row = try rows.next() {
                let fileId: FileID = row[0]
                if search.memberships.allSatisfy({ $0.contains(fileId) }) { result.append(GridMedia(gridRow: row)) }
            }
            let extra = try Self.albumOnlyMatches(search, db: db)
            guard !extra.isEmpty else { return result }
            return Self.newestFirst(result + extra.map(GridMedia.init), timestamp: \.timestamp, fileId: \.fileId)
        }
    }

    /// Search results as full items (smart albums), newest first.
    public func searchItems(_ search: LibrarySearch) async throws -> [MediaItem] {
        let (sql, arguments) = Self.searchSQL(search, columns: "media.*")
        return try await database.writer.read { db in
            let items = try MediaItem.fetchAll(db, sql: sql, arguments: arguments)
            let found = items.filter { item in search.memberships.allSatisfy { $0.contains(item.fileId) } }
            let extra = try Self.albumOnlyMatches(search, db: db)
            guard !extra.isEmpty else { return found }
            return Self.newestFirst(found + extra, timestamp: \.timestamp, fileId: \.fileId)
        }
    }

    static func newestFirst<T>(_ items: [T], timestamp: (T) -> Date, fileId: (T) -> FileID) -> [T] {
        items.sorted { a, b in
            let (ta, tb) = (timestamp(a), timestamp(b))
            return ta != tb ? ta > tb : fileId(a) > fileId(b)
        }
    }

    /// Photos of albums that are not in the timeline index (other people's photos in albums shared with the user, own
    /// albums' photos outside the timeline folders), matched by the album filters and by free text over their name,
    /// place, caption and album titles (SPEC SR-3). Only for searches by text or album: the other criteria alone search
    /// the library. They are known once the album's content was read (`collectionMedia`), and are checked here in Swift
    /// with the same rules as the index (every word a substring, case and diacritics ignored).
    static func albumOnlyMatches(_ search: LibrarySearch, db: Database) throws -> [MediaItem] {
        let terms = search.terms
        guard !terms.isEmpty || !search.albumIds.isEmpty else { return [] }
        var conditions = ["album.kind IN ('own', 'shared')", "albumItem.fileId NOT IN (SELECT fileId FROM media)"]
        var arguments: StatementArguments = []
        if !search.albumIds.isEmpty {
            let marks = search.albumIds.map { _ in "?" }.joined(separator: ",")
            conditions.append("albumItem.fileId IN (SELECT fileId FROM albumItem WHERE albumId IN (\(marks)))")
            for id in search.albumIds { arguments += [id] }
        }
        let sql = """
            SELECT albumItem.fileId, group_concat(album.title, ' ') FROM albumItem JOIN album ON album.id = albumItem.albumId
            WHERE \(conditions.joined(separator: " AND ")) GROUP BY albumItem.fileId
            """
        var titles: [FileID: String] = [:]
        for row in try Row.fetchAll(db, sql: sql, arguments: arguments) { titles[row[0]] = row[1] ?? "" }
        guard !titles.isEmpty else { return [] }
        var result: [MediaItem] = []
        for chunk in Array(titles.keys).chunked(500) {
            for record in try CollectionMediaRecord.fetchAll(db, keys: Array(chunk)) {
                let item = record.item
                guard Self.matches(item, albumTitles: titles[item.fileId] ?? "", search: search, terms: terms) else { continue }
                result.append(item)
            }
        }
        return result
    }

    /// Whether a photo that is not in the index meets a search: what `searchSQL` asks of an indexed one.
    static func matches(_ item: MediaItem, albumTitles: String, search: LibrarySearch, terms: [String]) -> Bool {
        guard !item.isLivePhotoVideo, !item.isArchived else { return false }
        if !terms.isEmpty {
            let fields = [item.name, item.place, item.placeCountry, item.caption, albumTitles].compactMap { $0 }
            let text = fields.joined(separator: " ")
            for term in terms where text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) == nil { return false }
        }
        if !search.places.isEmpty && !search.places.contains(item.place ?? "") { return false }
        if !search.dateRanges.isEmpty && !search.dateRanges.contains(where: { $0.contains(item.timestamp) }) { return false }
        if search.favoritesOnly && !item.isFavorite { return false }
        if search.videosOnly && item.kind != .video { return false }
        if search.photosOnly && item.kind != .image { return false }
        // Ratings are tags of the user's own files; photos only known from albums have none here.
        if search.minimumRating != nil { return false }
        return search.memberships.allSatisfy { $0.contains(item.fileId) }
    }

    /// The names of the places visible items were taken at, sorted (search suggestions).
    public func placeNames() async throws -> [String] {
        try await database.writer.read { db in
            try String.fetchAll(
                db,
                sql:
                    "SELECT DISTINCT media.place FROM media WHERE media.place IS NOT NULL AND media.place <> '' AND \(Self.visible) ORDER BY 1"
            )
        }
    }
}
