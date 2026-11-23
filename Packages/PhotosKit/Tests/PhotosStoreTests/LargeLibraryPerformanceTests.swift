// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import Testing

@testable import PhotosDomain
@testable import PhotosModel
@testable import PhotosStore

extension Tag {
    /// Timing tests on a synthetic 100 000-item index (SPEC §10). Slow by nature (they build the index first).
    @Tag static var performance: Self
}

/// Store timings against the budgets of SPEC §10, on a synthetic library of 100 000 items.
///
/// Skipping them (slow CI): `PHOTOS_SKIP_PERFORMANCE=1` (with xcodebuild: `TEST_RUNNER_PHOTOS_SKIP_PERFORMANCE=1`), or
/// `-skip-testing:PhotosStoreTests/LargeLibraryPerformanceTests` / `swift test --skip LargeLibraryPerformanceTests`.
/// Another size: `PHOTOS_PERFORMANCE_ITEMS=250000`. The measured numbers are printed as lines starting with `PERF`.
///
/// The limits asserted here are several times the budgets: unit tests run unoptimised and on machines that do other
/// things at the same time. They catch a query that fell back to scanning or a write path that became quadratic, not a
/// regression of a few percent; for those, read the printed numbers (best of several runs), ideally from an optimised
/// run: `swift test -c release -Xswiftc -enable-testing --filter LargeLibraryPerformanceTests` in `Packages/PhotosKit`
/// (this needs every test target to compile in release; a target that uses debug-only API has to be left out for it).
@Suite(
    .serialized, .tags(.performance),
    .enabled(if: ProcessInfo.processInfo.environment["PHOTOS_SKIP_PERFORMANCE"] == nil, "PHOTOS_SKIP_PERFORMANCE is set"))
struct LargeLibraryPerformanceTests {
    static let itemCount = Int(ProcessInfo.processInfo.environment["PHOTOS_PERFORMANCE_ITEMS"] ?? "") ?? 100_000

    /// Best time of `runs` runs, in milliseconds.
    @discardableResult
    static func measure<T>(_ label: String, runs: Int = 5, _ body: () async throws -> T) async rethrows -> (value: T, milliseconds: Double) {
        var best = Double.infinity
        var value: T?
        for _ in 0..<runs {
            let began = ContinuousClock.now
            value = try await body()
            best = min(best, (ContinuousClock.now - began).milliseconds)
        }
        print("PERF \(label): \(String(format: "%.1f", best)) ms")
        return (value!, best)
    }

    static func plan(_ database: AccountDatabase, _ sql: String, _ arguments: StatementArguments = []) throws -> String {
        try database.writer.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql, arguments: arguments).map { $0["detail"] as String }.joined(separator: " | ")
        }
    }

    @Test func budgets() async throws {
        let count = Self.itemCount
        #if DEBUG
            print("PERF build: debug (unoptimised), \(count) items")
        #else
            print("PERF build: release, \(count) items")
        #endif

        // MARK: Initial index (the store's share of the initial sync): pages of 1000 as the sync delivers them.
        let (database, library, pages) = try SyntheticLibrary.makeDatabase(count: count)
        defer { SyntheticLibrary.remove(database) }
        let total = pages.reduce(0, +)
        let tenth = max(pages.count / 10, 1)
        let firstPages = pages.prefix(tenth).reduce(0, +) / Double(tenth) * 1000
        let lastPages = pages.suffix(tenth).reduce(0, +) / Double(tenth) * 1000
        print("PERF initial index of \(count) items (store only): \(String(format: "%.2f", total)) s")
        print("PERF upsert of a 1000-row page: \(String(format: "%.1f", firstPages)) ms into an empty index, \(String(format: "%.1f", lastPages)) ms at \(count)")
        // Budget: the whole initial sync in < 10 min; the store may use a small part of that.
        #expect(total < 120)
        // The cost of a page must not grow with the size of the index (it was a full scan of the search table per row).
        #expect(lastPages < max(firstPages * 4, 250))

        let size = (try? FileManager.default.attributesOfItem(atPath: database.url.path(percentEncoded: false))[.size] as? Int64) ?? 0
        print("PERF database file: \(size / 1_048_576) MB")

        // MARK: Writes on the full index
        let page = SyntheticLibrary.items(0..<1000, of: count)
        let unchanged = try await Self.measure("re-upsert of an unchanged 1000-row page", runs: 3) { try library.upsert(page) }
        #expect(unchanged.milliseconds < 500)
        var toggle = false
        let changed = try await Self.measure("upsert of a 1000-row page with changed rows (etag, favourite, caption)", runs: 3) {
            toggle.toggle()
            try library.upsert(
                page.map { item in
                    var item = item
                    item.etag = toggle ? "changed" : "changed-again"
                    item.isFavorite.toggle()
                    item.caption = toggle ? "Neue Beschreibung" : nil
                    return item
                })
        }
        #expect(changed.milliseconds < 1500)
        try library.upsert(page)

        // MARK: Timeline
        let grid = try await Self.measure("timeline, full grid rows (gridItems(.all))") { try library.gridItems(.all) }
        #expect(grid.value.count > count * 9 / 10)
        #expect(grid.milliseconds < 1500)
        let entries = try await Self.measure("timeline, lightweight rows (timelineRows(.all))") { try await library.timelineRows(.all) }
        #expect(entries.value.count == grid.value.count)
        #expect(entries.milliseconds < 500)
        print("PERF   plan: \(try Self.plan(database, LibraryStore.sql(for: .all, excludedPrefixes: [], columns: LibraryStore.timelineColumns).0))")
        print("PERF   plan (grid rows): \(try Self.plan(database, LibraryStore.sql(for: .all, excludedPrefixes: []).0))")
        let visible = Array(grid.value[5000..<5200].map(\.fileId))
        let details = try await Self.measure("grid details of 200 tiles (gridMedia)") { try await library.gridMedia(visible) }
        #expect(details.value.count == 200)
        #expect(details.milliseconds < 50)
        for (name, filter) in [("photos", MediaFilter.photos), ("videos", .videos), ("favourites", .favorites), ("place", .place("Berlin"))] {
            let rows = try await Self.measure("grid rows, \(name)") { try library.gridItems(filter) }
            print("PERF   \(rows.value.count) rows; plan: \(try Self.plan(database, LibraryStore.sql(for: filter, excludedPrefixes: []).0, filter == .place("Berlin") ? ["Berlin"] : []))")
            #expect(!rows.value.isEmpty)
            #expect(rows.milliseconds < 1500)
        }
        let excluded = try await Self.measure("timeline, lightweight rows, one folder excluded") {
            try await library.timelineRows(.all, excludedFolders: ["/Photos/2020"])
        }
        #expect(excluded.value.count < entries.value.count)

        // MARK: Search (budget: local search/filter over 100 000 items < 100 ms)
        var searches: [(String, LibrarySearch)] = [
            ("text 'berlin' (place, ~1 % of the library)", LibrarySearch(texts: ["berlin"])),
            ("text 'sunset beach' (caption)", LibrarySearch(texts: ["sunset beach"])),
            ("text 'IMG_2019' (file names of a year)", LibrarySearch(texts: ["IMG_2019"])),
            ("text '2019/07' (folder)", LibrarySearch(texts: ["2019/07"])),
            ("text 'koln' + favourites", LibrarySearch(texts: ["koln"], favoritesOnly: true)),
            ("two-letter text 'ky'", LibrarySearch(texts: ["ky"])),
            ("text without a match", LibrarySearch(texts: ["zzzzqq"])),
            ("places Paris or Roma", LibrarySearch(places: ["Paris", "Roma"])),
            ("favourites", LibrarySearch(favoritesOnly: true)),
            ("videos", LibrarySearch(videosOnly: true)),
            (
                "one month",
                LibrarySearch(dateRanges: [
                    Date(timeIntervalSince1970: SyntheticLibrary.newest - 400 * 86_400)..<Date(timeIntervalSince1970: SyntheticLibrary.newest - 370 * 86_400)
                ])
            ),
        ]
        let members = Set(grid.value.enumerated().filter { $0.offset % 7 == 0 }.map(\.element.fileId))
        searches.append(("place Paris + a tag with 14 000 members", LibrarySearch(places: ["Paris"], memberships: [members])))
        for (name, search) in searches {
            let result = try await Self.measure("search: \(name)") { try await library.search(search) }
            let (sql, arguments) = LibraryStore.searchSQL(search, columns: LibraryStore.gridColumns)
            print("PERF   \(result.value.count) results; plan: \(try Self.plan(database, sql, arguments))")
            // Five times the budget (see the suite's comment).
            #expect(result.milliseconds < 500, "\(name)")
        }
        // The worst case: a word that is in every row returns the whole library; the time is that of the timeline.
        let everything = try await Self.measure("search: text 'photos' (matches every row)") {
            try await library.search(LibrarySearch(texts: ["photos"]))
        }
        #expect(everything.value.count == grid.value.count)
        let places = try await Self.measure("place names for suggestions") { try await library.placeNames() }
        #expect(places.value.count == SyntheticLibrary.places.count)

        // MARK: Memories
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let now = Date(timeIntervalSince1970: SyntheticLibrary.newest + 366 * 86_400)
        let onThisDay = try await Self.measure("memories: on this day") {
            try await library.memories(onlyOnThisDay: true, now: now, calendar: calendar)
        }
        #expect(!onThisDay.value.onThisDay.isEmpty)
        #expect(onThisDay.milliseconds < 250)
        let memories = try await Self.measure("memories: on this day, trips, year in review", runs: 3) {
            try await library.memories(now: now, calendar: calendar)
        }
        #expect(memories.value.recap != nil && !memories.value.trips.isEmpty)
        #expect(memories.milliseconds < 3000)

        // MARK: Map (budget: clustering < 200 ms per region change, 50 000 geotagged photos)
        let located = try await library.mapItemCount(in: MapRegion(minLatitude: -90, maxLatitude: 90, minLongitude: -180, maxLongitude: 180))
        print("PERF geotagged items: \(located)")
        let regions: [(String, MapRegion, Double, Double)] = [
            ("the world", MapRegion(minLatitude: -90, maxLatitude: 90, minLongitude: -180, maxLongitude: 180), 22.5, 45),
            ("Europe", MapRegion(minLatitude: 35, maxLatitude: 65, minLongitude: -25, maxLongitude: 30), 3.75, 6.9),
            ("a city", MapRegion(minLatitude: 52.4, maxLatitude: 52.6, minLongitude: 13.3, maxLongitude: 13.5), 0.025, 0.025),
        ]
        for (name, region, cellLatitude, cellLongitude) in regions {
            let cells = try await Self.measure("map cells: \(name)") {
                try await library.mapCells(in: region, cellLatitude: cellLatitude, cellLongitude: cellLongitude)
            }
            print("PERF   \(cells.value.count) cells, \(cells.value.map(\.count).reduce(0, +)) items")
            #expect(!cells.value.isEmpty)
            #expect(cells.milliseconds < 1000)
        }

        // MARK: Other hot queries
        let recent = try await Self.measure("recent uploads (SyncEngine.recentUploads)") {
            try await database.writer.read { db in
                try FileID.fetchAll(db, sql: "SELECT fileId FROM media WHERE uploadedAt > ? LIMIT 500", arguments: [SyntheticLibrary.newest + 3000])
            }
        }
        #expect(recent.milliseconds < 50)
        try await Self.measure("favourite ids (SyncEngine.syncFavorites)") {
            try await database.writer.read { db in try FileID.fetchAll(db, sql: "SELECT fileId FROM media WHERE isFavorite = 1") }
        }
        try await Self.measure("reconcile key scan (SyncEngine.reconcile)", runs: 3) {
            try await database.writer.read { db in
                var keys = 0
                let rows = try Row.fetchCursor(db, sql: "SELECT fileId, etag, path, isFavorite, place, caption FROM media")
                while let row = try rows.next() {
                    let etag: String = row[1]
                    keys += etag.isEmpty ? 0 : 1
                }
                return keys
            }
        }
        // An album with 5000 items.
        try await database.writer.write { db in
            try db.execute(sql: "INSERT INTO album(id, kind, name, title) VALUES ('own:big', 'own', 'big', 'Big')")
            for (position, item) in grid.value.prefix(5000).enumerated() {
                try db.execute(
                    sql: "INSERT INTO albumItem(albumId, fileId, childName, position) VALUES ('own:big', ?, ?, ?)",
                    arguments: [item.fileId, item.name, position])
            }
        }
        let album = try await Self.measure("album with 5000 items, grid rows") { try library.gridItems(.album("own:big")) }
        #expect(album.value.count == 5000)
        #expect(album.milliseconds < 500)
        print("PERF   plan: \(try Self.plan(database, LibraryStore.sql(for: .album("own:big"), excludedPrefixes: []).0, ["own:big"]))")

        // A memory or map area with more items than SQLite binds values.
        let many = Array(grid.value.prefix(40_000).map(\.fileId))
        let items = try await Self.measure("40 000 items by id", runs: 1) { try await library.fetchItems(many) }
        #expect(items.value.count == 40_000)

        let emptied = try await Self.measure("deleteAll", runs: 1) { try library.deleteAll() }
        #expect(emptied.milliseconds < 5000)
        #expect(try library.count() == 0)
    }
}
