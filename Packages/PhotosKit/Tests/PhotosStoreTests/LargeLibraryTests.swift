// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import Testing

@testable import PhotosDomain
@testable import PhotosModel
@testable import PhotosStore

/// The store queries that keep a large library fast: full-text search, purpose-built queries for memories and the map,
/// the lightweight timeline, coalesced observation, and the migration that introduces them.
@Suite struct LargeLibraryTests {
    func item(
        _ id: FileID, _ time: Double = 1000, path: String = "/Photos/x.jpg", mime: String = "image/jpeg", favorite: Bool = false,
        place: String? = nil, country: String? = nil, caption: String? = nil, hidden: Bool = false
    ) -> MediaItem {
        MediaItem(
            fileId: id, path: path, mimeType: mime, etag: "e\(id)", modifiedAt: Date(timeIntervalSince1970: time),
            capturedAt: Date(timeIntervalSince1970: time), place: place, placeCountry: country, isFavorite: favorite,
            isLivePhotoVideo: hidden, caption: caption, isArchived: path.hasPrefix("/.archive/"))
    }

    func ids(_ store: LibraryStore, _ search: LibrarySearch) async throws -> [FileID] { try await store.search(search).map(\.fileId) }

    func plan(_ database: AccountDatabase, _ sql: String, _ arguments: StatementArguments = []) throws -> String {
        try database.writer.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql, arguments: arguments).map { $0["detail"] as String }.joined(separator: " | ")
        }
    }

    // MARK: Search

    @Test func freeTextSearchesNamePlaceCountryCaptionAndFolder() async throws {
        let store = LibraryStore(database: try .temporary())
        try store.upsert([
            item(1, 100, path: "/Photos/2019/IMG_1234.jpg"),
            item(2, 200, path: "/Photos/Urlaub/b.jpg", place: "München", country: "Deutschland"),
            item(3, 300, path: "/Photos/c.jpg", caption: "Sunset at the beach"),
            item(4, 400, path: "/Photos/d.mp4", mime: "video/mp4", place: "Paris", country: "France"),
            item(5, 500, path: "/.archive/Photos/IMG_1234.jpg"),
            item(6, 600, path: "/Photos/IMG_1234.mov", mime: "video/quicktime", hidden: true),
        ])
        // Substring of the file name, any case; archived items and Live Photo videos never show up.
        #expect(try await ids(store, LibrarySearch(texts: ["img_12"])) == [1])
        #expect(try await ids(store, LibrarySearch(texts: ["234"])) == [1])
        // Diacritics are ignored in both directions.
        #expect(try await ids(store, LibrarySearch(texts: ["munch"])) == [2])
        #expect(try await ids(store, LibrarySearch(texts: ["MÜNCHEN"])) == [2])
        #expect(try await ids(store, LibrarySearch(texts: ["deutschl"])) == [2])
        #expect(try await ids(store, LibrarySearch(texts: ["sunset"])) == [3])
        #expect(try await ids(store, LibrarySearch(texts: ["urlaub"])) == [2])
        // Every word must match, in any of the fields.
        #expect(try await ids(store, LibrarySearch(texts: ["beach sunset"])) == [3])
        #expect(try await ids(store, LibrarySearch(texts: ["paris", "france"])) == [4])
        #expect(try await ids(store, LibrarySearch(texts: ["paris sunset"])).isEmpty)
        // Words shorter than a trigram still match.
        #expect(try await ids(store, LibrarySearch(texts: ["d."])) == [4])
        #expect(try await ids(store, LibrarySearch(texts: ["at beach"])) == [3])
        // Characters with a meaning in FTS or LIKE syntax are plain text.
        #expect(try await ids(store, LibrarySearch(texts: ["\"beach\" OR"])).isEmpty)
        #expect(try await ids(store, LibrarySearch(texts: ["%"])).isEmpty)
        #expect(try await ids(store, LibrarySearch(texts: ["g_1"])) == [1])
        #expect(try await ids(store, LibrarySearch(texts: ["_1"])) == [1])
    }

    @Test func filtersCombineAsBefore() async throws {
        let database = try AccountDatabase.temporary()
        let store = LibraryStore(database: database)
        try store.upsert([
            item(1, 100, favorite: true, place: "Berlin"), item(2, 200, place: "Paris"),
            item(3, 300, mime: "video/mp4", favorite: true, place: "Paris"), item(4, 400, place: "Roma"), item(5, 500),
        ])
        try await database.writer.write { db in
            try db.execute(sql: "INSERT INTO album(id, kind, name, title) VALUES ('own:a', 'own', 'a', 'A'), ('own:b', 'own', 'b', 'B')")
            try db.execute(
                sql: "INSERT INTO albumItem(albumId, fileId, childName) VALUES ('own:a', 1, 'x'), ('own:a', 2, 'x'), ('own:b', 2, 'x'), ('own:b', 5, 'x')")
        }
        // OR within a kind, newest first.
        #expect(try await ids(store, LibrarySearch(places: ["Berlin", "Paris"])) == [3, 2, 1])
        let ranges = [Date(timeIntervalSince1970: 100)..<Date(timeIntervalSince1970: 200), Date(timeIntervalSince1970: 400)..<Date(timeIntervalSince1970: 401)]
        #expect(try await ids(store, LibrarySearch(dateRanges: ranges)) == [4, 1])
        #expect(try await ids(store, LibrarySearch(albumIds: ["own:a", "own:b"])) == [5, 2, 1])
        // AND between kinds.
        #expect(try await ids(store, LibrarySearch(places: ["Paris"], favoritesOnly: true)) == [3])
        #expect(try await ids(store, LibrarySearch(videosOnly: true)) == [3])
        #expect(try await ids(store, LibrarySearch(texts: ["paris"], albumIds: ["own:a"])) == [2])
        // Memberships from the server: results must be in every set.
        #expect(try await ids(store, LibrarySearch(places: ["Paris", "Roma"], memberships: [[2, 4, 9], [4, 3]])) == [4])
        // The same search as full items.
        #expect(try await store.searchItems(LibrarySearch(places: ["Paris"], memberships: [[2]])).map(\.place) == ["Paris"])

        // Filter chips become one search; tags and people are left to the memberships.
        let search = LibrarySearch(filters: [
            .text("a b"), .place("Paris"), .place("Roma"), .favorites, .videos, .album(id: "own:a", title: "A"), .tag(id: 1, name: "t"),
            .person("p"), .dateRange(start: Date(timeIntervalSince1970: 1), end: Date(timeIntervalSince1970: 2), label: ""),
        ])
        #expect(search.terms == ["a", "b"])
        #expect(search.places == ["Paris", "Roma"])
        #expect(search.favoritesOnly && search.videosOnly)
        #expect(search.albumIds == ["own:a"])
        #expect(search.dateRanges.count == 1)
        #expect(search.memberships.isEmpty)
    }

    @Test func searchIndexFollowsEveryWrite() async throws {
        let database = try AccountDatabase.temporary()
        let store = LibraryStore(database: database)
        try store.upsert([item(1, 100, path: "/Photos/first.jpg", place: "Berlin"), item(2, 200, path: "/Photos/second.jpg")])
        func indexed() throws -> Int { try database.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM searchIndex")! } }
        #expect(try indexed() == 2)

        // Changed by the sync.
        try store.upsert([item(1, 100, path: "/Photos/first.jpg", place: "Hamburg")])
        #expect(try await ids(store, LibrarySearch(texts: ["berlin"])).isEmpty)
        #expect(try await ids(store, LibrarySearch(texts: ["hamburg"])) == [1])
        // An optimistic local change.
        try store.update(2) { $0.caption = "Kaffee und Kuchen" }
        #expect(try await ids(store, LibrarySearch(texts: ["kuchen"])) == [2])
        // Written past the store (the outbox moves and renames rows itself).
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE media SET path = '/Photos/Renamed/zweite.jpg', name = 'zweite.jpg' WHERE fileId = 2")
        }
        #expect(try await ids(store, LibrarySearch(texts: ["second"])).isEmpty)
        #expect(try await ids(store, LibrarySearch(texts: ["renamed zweite"])) == [2])
        #expect(try indexed() == 2)

        try store.delete([1])
        #expect(try indexed() == 1)
        #expect(try await ids(store, LibrarySearch(texts: ["hamburg"])).isEmpty)

        try store.deleteAll()
        #expect(try indexed() == 0)
        #expect(try store.count() == 0)
        // The index works again after it was emptied.
        try store.upsert([item(3, 300, path: "/Photos/third.jpg")])
        #expect(try await ids(store, LibrarySearch(texts: ["third"])) == [3])
        #expect(try indexed() == 1)
    }

    @Test func upsertOfUnchangedRowsWritesNothing() async throws {
        let database = try AccountDatabase.temporary()
        let store = LibraryStore(database: database)
        let items = SyntheticLibrary.items(0..<300, of: 300)
        try store.upsert(items)
        func changes() throws -> Int { try database.writer.write { db in db.totalChangesCount } }
        let before = try changes()
        try store.upsert(items)
        #expect(try changes() == before)

        var changed = items[7]
        changed.isFavorite.toggle()
        try store.upsert(items[0..<7] + [changed] + items[8...])
        #expect(try store.item(changed.fileId) == changed)
        // One row, and no rewrite of its search text (the indexed fields are the same).
        #expect(try changes() == before + 1)
    }

    // MARK: Migration

    @Test func migrationKeepsDataAndRebuildsTheSearchIndex() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "photos-migration-\(UUID().uuidString).sqlite")
        let items = [
            item(1, 100, path: "/Photos/2019/IMG_0001.jpg", favorite: true, place: "Köln", country: "Deutschland"),
            item(2, 200, path: "/Photos/clip.mp4", mime: "video/mp4", caption: "Erster Schultag"),
            item(3, 300, path: "/.archive/Photos/hidden.jpg"),
        ]
        // A database as the previous version left it: schema v1 with its search table (fileId, text).
        do {
            let pool = try DatabasePool(path: url.path(percentEncoded: false))
            try AccountDatabase.migrator.migrate(pool, upTo: "v1-backup")
            try await pool.write { db in
                for item in items {
                    try item.insert(db)
                    try db.execute(sql: "INSERT INTO searchIndex(fileId, text) VALUES (?, ?)", arguments: [item.fileId, "stale \(item.name)"])
                }
                try db.execute(sql: "INSERT INTO album(id, kind, name, title) VALUES ('own:a', 'own', 'a', 'A')")
                try db.execute(sql: "INSERT INTO albumItem(albumId, fileId, childName, position) VALUES ('own:a', 2, 'clip.mp4', 0)")
                try db.execute(sql: "INSERT INTO syncState(key, value) VALUES ('initialComplete', '1')")
                try db.execute(
                    sql: "INSERT INTO offlineFile(fileId, etag, localPath, bytes, downloadedAt) VALUES (1, 'e1', '1.jpg', 10, 0)")
            }
            try pool.close()
        }

        let database = try AccountDatabase(url: url)
        defer { SyntheticLibrary.remove(database) }
        let store = LibraryStore(database: database)
        // Everything is still there.
        #expect(try store.items([1, 2, 3]) == Dictionary(uniqueKeysWithValues: items.map { ($0.fileId, $0) }))
        #expect(try store.gridItems(.all).map(\.fileId) == [2, 1])
        #expect(try store.gridItems(.album("own:a")).map(\.fileId) == [2])
        #expect(try database.syncValue("initialComplete") == "1")
        #expect(try await database.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM offlineFile") } == 1)
        // The search index was rebuilt from the media rows and is searchable.
        #expect(try await database.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM searchIndex") } == 3)
        #expect(try await ids(store, LibrarySearch(texts: ["stale"])).isEmpty)
        #expect(try await ids(store, LibrarySearch(texts: ["koln"])) == [1])
        #expect(try await ids(store, LibrarySearch(texts: ["schultag"])) == [2])
        #expect(try await ids(store, LibrarySearch(texts: ["2019"])) == [1])
        // The new indexes exist.
        let indexes = try await database.writer.read { db in
            try Set(String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name IN ('media', 'albumItem')"))
        }
        #expect(indexes.isSuperset(of: ["media_uploadedAt", "media_timeline", "media_favorite_timestamp", "media_map", "albumItem_position"]))
        // Opening it again changes nothing.
        try database.writer.close()
        let reopened = try AccountDatabase(url: url)
        #expect(try LibraryStore(database: reopened).count() == 3)
        try reopened.writer.close()
    }

    @Test func rebuiltIndexTextIsWhatTheTriggersWrite() async throws {
        // The migration fills the index with SQL; rows written afterwards go through the triggers. Both must agree.
        let url = FileManager.default.temporaryDirectory.appending(path: "photos-migration-\(UUID().uuidString).sqlite")
        let items = SyntheticLibrary.items(0..<200, of: 200) + [item(9, 1, path: "/root.jpg"), item(8, 1, path: "/A B/c d.jpg", caption: "x")]
        do {
            let pool = try DatabasePool(path: url.path(percentEncoded: false))
            try AccountDatabase.migrator.migrate(pool, upTo: "v1-backup")
            try await pool.write { db in for item in items { try item.insert(db) } }
            try pool.close()
        }
        let migrated = try AccountDatabase(url: url)
        defer { SyntheticLibrary.remove(migrated) }
        let fresh = try AccountDatabase.temporary()
        defer { SyntheticLibrary.remove(fresh) }
        try LibraryStore(database: fresh).upsert(items)
        func texts(_ database: AccountDatabase) throws -> [String] {
            try database.writer.read { db in try String.fetchAll(db, sql: "SELECT rowid || ':' || text FROM searchIndex ORDER BY rowid") }
        }
        #expect(try texts(migrated) == texts(fresh))
        #expect(try texts(fresh).contains("9:root.jpg"))
        #expect(try texts(fresh).contains("8:c d.jpg x /A B"))
    }

    // MARK: Timeline

    @Test func lightweightTimelineMatchesTheGrid() async throws {
        let (database, store, _) = try SyntheticLibrary.makeDatabase(count: 3000)
        defer { SyntheticLibrary.remove(database) }
        for filter in [MediaFilter.all, .photos, .videos, .favorites, .archived, .place("Berlin")] {
            let grid = try store.gridItems(filter)
            let entries = try await store.timelineRows(filter)
            #expect(entries.map(\.fileId) == grid.map(\.fileId))
            #expect(entries.map(\.timestamp) == grid.map(\.timestamp))
            #expect(entries.map(\.kind) == grid.map(\.kind))
            #expect(entries.map(\.isFavorite) == grid.map(\.isFavorite))
            #expect(entries.map(\.isLivePhoto) == grid.map(\.isLivePhoto))
            #expect(entries.map(\.aspectRatio) == grid.map(\.aspectRatio))
            #expect(entries.map(\.duration) == grid.map(\.duration))
            #expect(try await store.fetchGridItems(filter) == grid)
        }
        #expect(try store.gridItems(.all).count > 2900)
        let excluded = try await store.timelineRows(.all, excludedFolders: ["/Photos/2026"])
        #expect(excluded.map(\.fileId) == (try store.gridItems(.all, excludedFolders: ["/Photos/2026"]).map(\.fileId)))
        #expect(excluded.count < 3000 - 100)

        // Details for the tiles on screen.
        let some = Array(try store.gridItems(.all).prefix(700))
        let details = try await store.gridMedia(some.map(\.fileId))
        #expect(details.count == 700)
        #expect(some.allSatisfy { details[$0.fileId] == $0 })
    }

    @Test func gridRowsDecodeLikeTheRecord() throws {
        let (database, store, _) = try SyntheticLibrary.makeDatabase(count: 500)
        defer { SyntheticLibrary.remove(database) }
        // By position (fast) and by name (the `FetchableRecord` conformance) give the same rows.
        let (sql, arguments) = LibraryStore.sql(for: .all, excludedPrefixes: [])
        let byName = try database.writer.read { db in try GridMedia.fetchAll(db, sql: sql, arguments: arguments) }
        #expect(try store.gridItems(.all) == byName)
        #expect(byName.count > 400)
        for path in ["/Photos/2019/a.jpg", "/a.jpg", "/Photos/a b/ü.jpg", "relative.jpg", "/Photos//a.jpg", "/Photos/dir/", "", "/"] {
            #expect(GridMedia.directory(of: path) == (path as NSString).deletingLastPathComponent, "\(path)")
        }
    }

    @Test func membersAreListedOnceWithoutDistinct() async throws {
        let database = try AccountDatabase.temporary()
        let store = LibraryStore(database: database)
        try store.upsert([item(1, 100), item(2, 200)])
        try await database.writer.write { db in
            try db.execute(sql: "INSERT INTO person(name) VALUES ('Ada')")
            // Two detections of the same person in one photo.
            try db.execute(
                sql: "INSERT INTO personItem(person, detectionId, fileId, childName) VALUES ('Ada', 1, 1, 'a'), ('Ada', 2, 1, 'a'), ('Ada', 3, 2, 'b')")
        }
        #expect(try store.gridItems(.person("Ada")).map(\.fileId) == [2, 1])
        #expect(!LibraryStore.sql(for: .all, excludedPrefixes: []).0.contains("DISTINCT"))
    }

    @Test func hotQueriesUseTheirIndexes() throws {
        let (database, _, _) = try SyntheticLibrary.makeDatabase(count: 2000)
        defer { SyntheticLibrary.remove(database) }
        // No ANALYZE: the app does not run it either, so these are the plans a real database gets.
        // The lightweight timeline: one covering index, already in display order.
        let timeline = try plan(database, LibraryStore.sql(for: .all, excludedPrefixes: [], columns: LibraryStore.timelineColumns).0)
        #expect(timeline.contains("COVERING INDEX media_timeline"))
        #expect(!timeline.contains("TEMP B-TREE"))
        // Favourites: found in an index that is in display order (the flag is part of the timeline index), no sort.
        let favorites = try plan(database, LibraryStore.sql(for: .favorites, excludedPrefixes: []).0)
        #expect((favorites.contains("media_timeline") || favorites.contains("media_favorite_timestamp")) && !favorites.contains("TEMP B-TREE"))
        // Recent uploads (SyncEngine.recentUploads).
        #expect(try plan(database, "SELECT fileId FROM media WHERE uploadedAt > ? LIMIT 500", [0]).contains("media_uploadedAt"))
        // The favourites the sync compares with the server.
        #expect(try plan(database, "SELECT fileId FROM media WHERE isFavorite = 1").contains("media_favorite_timestamp"))
        // Album content: by primary key, no scan of media.
        let album = try plan(database, LibraryStore.sql(for: .album("own:a"), excludedPrefixes: []).0, ["own:a"])
        #expect(!album.contains("SCAN media"))
        #expect(try plan(database, "SELECT fileId FROM albumItem WHERE albumId = ? ORDER BY position", ["own:a"]).contains("albumItem_position"))
        // Map cells: aggregated from the coordinate index alone.
        let cells = try plan(
            database,
            "SELECT \(LibraryStore.cellRow) AS cellRow, \(LibraryStore.cellColumn) AS cellColumn, COUNT(*), MAX(media.fileId) FROM media WHERE \(LibraryStore.located) AND \(LibraryStore.inRegion) GROUP BY cellRow, cellColumn",
            [1, 1, 40, 50, 0, 10])
        #expect(cells.contains("COVERING INDEX media_map"))
        // Full-text search goes through the FTS index, not a scan.
        let search = try plan(database, LibraryStore.searchSQL(LibrarySearch(texts: ["berlin"]), columns: LibraryStore.gridColumns).0, ["\"berlin\""])
        #expect(search.contains("searchIndex VIRTUAL TABLE INDEX") && !search.contains("SCAN media"))
        // On this day and the counts per year: ranges of the timeline index.
        let year = try plan(database, "SELECT COUNT(*) FROM media WHERE \(LibraryStore.inTimeRange)", [0, 1])
        #expect(year.contains("SEARCH media USING COVERING INDEX media_timeline"))
    }

    // MARK: Observation

    @Test func coalescedObservationDeliversTheLastStateWithFewRefetches() async throws {
        let database = try AccountDatabase.temporary()
        let store = LibraryStore(database: database)
        try store.upsert([item(1, 100)])
        var iterator = store.observeTimeline(.all, coalescing: .milliseconds(150)).makeAsyncIterator()
        #expect(try await iterator.next()?.map(\.fileId) == [1])

        // A burst of writes, as a sync storing page after page.
        for id in 2...40 { try store.upsert([item(FileID(id), Double(100 + id))]) }
        var deliveries = 0
        var last: [FileID] = []
        while last.count < 40, let value = try await iterator.next() {
            deliveries += 1
            last = value.map(\.fileId)
        }
        #expect(last == (1...40).reversed().map { FileID($0) })
        // Far fewer values than writes: the first change refetches at once, the rest is coalesced.
        #expect(deliveries <= 4)

        // A write that changes nothing the query returns delivers nothing; the next real change does.
        try store.update(1) { $0.caption = "not part of the timeline row" }
        try store.update(1) { $0.isFavorite = true }
        let value = try await iterator.next()
        #expect(value?.last?.isFavorite == true)
    }

    @Test func gridObservationStillWorksAndCanCoalesce() async throws {
        let store = LibraryStore(database: try .temporary())
        try store.upsert([item(1, 100)])
        for interval in [Duration.zero, .milliseconds(50)] {
            var iterator = store.observeGrid(.all, coalescing: interval).makeAsyncIterator()
            let first = try await iterator.next()
            #expect(first?.isEmpty == false)
            let id = FileID(1000 + (first?.count ?? 0))
            try store.upsert([item(id, 5000 + Double(id))])
            #expect(try await iterator.next()?.first?.fileId == id)
        }
    }

    // MARK: Memories and map

    @Test func memoriesFromQueriesEqualMemoriesFromTheWholeLibrary() async throws {
        let (database, store, _) = try SyntheticLibrary.makeDatabase(count: 6000)
        defer { SyntheticLibrary.remove(database) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let locale = Locale(identifier: "en_US")
        // A year and a day after the newest items, so that "1 year ago" has something.
        let now = Date(timeIntervalSince1970: SyntheticLibrary.newest + 366 * 86_400)
        let all = try store.allVisibleItems()

        let snapshot = try await store.memories(now: now, calendar: calendar, locale: locale)
        func normalized(_ memories: [Memory]) -> [Memory] {
            // Items with the same timestamp have no defined order.
            memories.map { memory in
                var memory = memory
                memory.items.sort()
                return memory
            }
        }
        let expectedOnThisDay = Memories.onThisDay(all, now: now, calendar: calendar)
        #expect(!expectedOnThisDay.isEmpty)
        #expect(normalized(snapshot.onThisDay).map(\.items) == normalized(expectedOnThisDay).map(\.items))
        #expect(snapshot.onThisDay.map(\.id) == expectedOnThisDay.map(\.id))
        let expectedTrips = Memories.trips(all, locale: locale)
        #expect(expectedTrips.count > 10)
        #expect(normalized(snapshot.trips).map(\.items) == normalized(expectedTrips).map(\.items))
        #expect(snapshot.trips.map(\.title) == expectedTrips.map(\.title))
        let expectedRecap = Memories.yearRecap(all, calendar: calendar)
        #expect(expectedRecap != nil)
        #expect(snapshot.recap?.id == expectedRecap?.id)
        #expect(snapshot.recap?.items.sorted() == expectedRecap?.items.sorted())

        let only = try await store.memories(onlyOnThisDay: true, now: now, calendar: calendar, locale: locale)
        #expect(only.onThisDay == snapshot.onThisDay)
        #expect(only.trips.isEmpty && only.recap == nil)
    }

    @Test func recapSkipsYearsWithTooFewPhotos() async throws {
        let store = LibraryStore(database: try .temporary())
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let year2024 = calendar.date(from: DateComponents(year: 2024, month: 3))!.timeIntervalSince1970
        let year2022 = calendar.date(from: DateComponents(year: 2022, month: 3))!.timeIntervalSince1970
        try store.upsert((0..<5).map { item(FileID(1 + $0), year2024 + Double($0) * 86_400 * 7) })
        try store.upsert((0..<40).map { item(FileID(100 + $0), year2022 + Double($0) * 86_400 * 7) })
        let snapshot = try await store.memories(now: Date(timeIntervalSince1970: year2024 + 200 * 86_400), calendar: calendar)
        #expect(snapshot.recap?.id == "recap-2022")
        #expect(try await LibraryStore(database: .temporary()).memories() == MemoriesSnapshot())
    }

    @Test func mapCellsAggregateInTheDatabase() async throws {
        let (database, store, _) = try SyntheticLibrary.makeDatabase(count: 4000)
        defer { SyntheticLibrary.remove(database) }
        let located = try store.allVisibleItems().filter(\.hasLocation)
        #expect(located.count > 1500)

        // Europe, in cells of 5°.
        let region = MapRegion(minLatitude: 35, maxLatitude: 65, minLongitude: -25, maxLongitude: 30)
        let inside = located.filter { (35...65).contains($0.latitude!) && (-25...30).contains($0.longitude!) }
        let cells = try await store.mapCells(in: region, cellLatitude: 5, cellLongitude: 5)
        #expect(cells.count > 5)
        #expect(cells.map(\.count).reduce(0, +) == inside.count)
        #expect(Set(cells.map(\.id)).count == cells.count)
        // The same partition as cutting the coordinates into cells by hand.
        var expected: [String: [MediaItem]] = [:]
        for item in inside {
            expected["\(Int(((item.latitude! + 90) / 5).rounded(.down)))-\(Int(((item.longitude! + 180) / 5).rounded(.down)))", default: []].append(item)
        }
        #expect(Dictionary(uniqueKeysWithValues: cells.map { ($0.id, $0.count) }) == expected.mapValues(\.count))
        for cell in cells {
            let members = expected[cell.id] ?? []
            // The marker shows the newest file of the cell, where it was taken.
            #expect(cell.cover.fileId == members.map(\.fileId).max())
            #expect(members.contains { $0.fileId == cell.cover.fileId && $0.latitude == cell.latitude && $0.longitude == cell.longitude })
            let items = try await store.mapItems(in: cell)
            #expect(items.map(\.fileId).sorted() == members.map(\.fileId).sorted())
            #expect(items.map(\.timestamp) == items.map(\.timestamp).sorted(by: >))
        }
        #expect(try await store.mapItemCount(in: region) == inside.count)
        #expect(try await store.mapItems(in: region).count == inside.count)
        // Nothing in the middle of the Pacific, and nothing without a sensible cell size.
        #expect(try await store.mapCells(in: MapRegion(minLatitude: -10, maxLatitude: 0, minLongitude: -140, maxLongitude: -130), cellLatitude: 1, cellLongitude: 1).isEmpty)
        #expect(try await store.mapCells(in: region, cellLatitude: 0, cellLongitude: 5).isEmpty)
        // Places for the search suggestions.
        #expect(try await store.placeNames() == Set(try store.allVisibleItems().compactMap(\.place)).sorted())
    }

    @Test func itemsAndDeleteAcceptMoreIdsThanSQLiteBinds() async throws {
        let database = try AccountDatabase.temporary()
        defer { SyntheticLibrary.remove(database) }
        let store = LibraryStore(database: database)
        try store.upsert((1...300).map { item(FileID($0), Double($0)) })
        // 40 000 ids (a memory of a whole library); most of them unknown.
        let many = (1...40_000).map { FileID($0) }
        #expect(try store.items(many).count == 300)
        #expect(try await store.fetchItems(many).count == 300)
        #expect(try await store.gridMedia(many).count == 300)
        try store.delete(many)
        #expect(try store.count() == 0)
    }
}
