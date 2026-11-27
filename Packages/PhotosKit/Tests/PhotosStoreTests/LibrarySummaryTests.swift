// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosDomain
import PhotosModel
import Testing

@testable import PhotosStore

/// Years, months and days with their key photos (SPEC §15.5).
@Suite struct LibrarySummaryTests {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    func media(_ id: FileID, _ date: Date, favorite: Bool = false, mime: String = "image/jpeg") -> GridMedia {
        GridMedia(
            MediaItem(
                fileId: id, path: "/Photos/\(id).jpg", mimeType: mime, etag: "e\(id)", modifiedAt: date, capturedAt: date,
                isFavorite: favorite))
    }

    @Test func bucketsAndKeyPhotos() {
        let items = [
            media(1, date(2026, 11, 22, 20)), media(2, date(2026, 11, 22, 10), favorite: true), media(3, date(2026, 11, 3)),
            media(4, date(2026, 10, 31), mime: "image/png"), media(5, date(2026, 10, 30)), media(6, date(2025, 1, 1)),
        ]
        let summary = LibrarySummary(items: items, quality: [3: (0.9, false), 5: (-0.5, false)], calendar: calendar)
        #expect(summary.years.map(\.id) == [2026, 2025])
        #expect(summary.months.map(\.id) == [202611, 202610, 202501])
        #expect(summary.days.map(\.id) == [20261122, 20261103, 20261031, 20261030, 20250101])
        // The favourite stands for its year and month; the PNG loses against a plain photo, a good score wins.
        #expect(summary.years[0].key.fileId == 2)
        #expect(summary.months[0].key.fileId == 2)
        #expect(summary.months[1].key.fileId == 4)  // -0.4 (PNG) beats -0.5 (badly rated)
        #expect(summary.years[0].count == 5)
        #expect(summary.days[0].highlights.map(\.fileId) == [2, 1])
        #expect(summary.years.allSatisfy { $0.highlights.isEmpty })
        // Lookups between levels.
        #expect(summary.bucket(.days, containing: 2)?.id == 20261103)
        #expect(summary.bucket(.months, matching: summary.days[3])?.id == 202610)
        #expect(summary.bucket(.years, containing: 5)?.id == 2025)
        #expect(summary.bucket(.years, containing: 99) == nil)
        #expect(summary.index(of: 4) == 3)
        #expect(summary.buckets(.all) == summary.days)
        #expect(LibrarySummary.empty.years.isEmpty)
    }

    /// SPEC §10 budget: the zoom levels of a 100 000-item library are built off the main actor in well under the grid
    /// model's own budget. Prints the time.
    @Test(
        .tags(.performance),
        .enabled(if: ProcessInfo.processInfo.environment["PHOTOS_SKIP_PERFORMANCE"] == nil, "PHOTOS_SKIP_PERFORMANCE is set"))
    func summaryPerformance100k() {
        var seed: UInt64 = 11
        func random() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(1 << 53)
        }
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        let span: Double = 8 * 365 * 86400
        var unsorted: [GridMedia] = []
        for index in 0..<100_000 {
            let offset: Double = -random() * span
            unsorted.append(media(FileID(index + 1), now.addingTimeInterval(offset), favorite: index % 50 == 0))
        }
        let items: [GridMedia] = unsorted.sorted { $0.timestamp > $1.timestamp }
        var quality: [FileID: (quality: Float, isUtility: Bool)] = [:]
        for index in stride(from: 0, to: 100_000, by: 2) { quality[FileID(index + 1)] = (Float(random() * 2 - 1), false) }
        let clock = ContinuousClock()
        var build = Duration.seconds(1000)
        var summary = LibrarySummary.empty
        for _ in 0..<3 {
            build = min(build, clock.measure { summary = LibrarySummary(items: items, quality: quality, calendar: calendar) })
        }
        print(
            "PERF LibrarySummary 100k: build \(build), \(summary.years.count) years, \(summary.months.count) months, \(summary.days.count) days"
        )
        #expect(summary.days.count > 2900)
        #expect(summary.days.reduce(0) { $0 + $1.count } == 100_000)
        #expect(build < timingBudget(.milliseconds(800)))
    }
}

/// Feature prints and scores stored per photo version (SPEC §15.5).
@Suite struct SimilarityStoreTests {
    @Test func candidatesPrintsAndProgress() throws {
        let database = try AccountDatabase.temporary()
        let library = LibraryStore(database: database)
        try library.upsert([
            MediaItem(fileId: 1, path: "/Photos/a.jpg", mimeType: "image/jpeg", etag: "e1"),
            MediaItem(fileId: 2, path: "/Photos/b.jpg", mimeType: "image/jpeg", etag: "e2"),
            MediaItem(fileId: 3, path: "/Photos/c.mov", mimeType: "video/quicktime", etag: "e3"),
        ])
        let store = SimilarityStore(database: database)
        #expect(try store.candidates(limit: 10).map(\.fileId) == [2, 1])
        let print: [Float] = [0.6, 0.8, 0, -0.25]
        try store.save([
            (.init(fileId: 1, etag: "e1"), .init(print: print, sketch: [1, -2, 3], quality: 0.5, isUtility: true)),
            (.init(fileId: 2, etag: "e2"), .failed),
        ])
        // Both were looked at; only the one with a print has a sketch and a score.
        #expect(try store.candidates(limit: 10).isEmpty)
        #expect(try store.progress() == (indexed: 2, total: 2))
        #expect(try store.prints(of: [1, 2]) == [1: print])
        #expect(try store.sketches().map(\.fileId) == [1])
        #expect(try store.sketches().first?.sketch == [1, -2, 3])
        #expect(try store.qualities()[1]?.quality == 0.5)
        #expect(try store.qualities()[1]?.isUtility == true)
        #expect(try store.qualities(of: [1, 2]) == [1: 0.5])

        // A new version is a candidate again, and its old print no longer counts.
        try library.upsert([MediaItem(fileId: 1, path: "/Photos/a.jpg", mimeType: "image/jpeg", etag: "e1b")])
        #expect(try store.candidates(limit: 10).map(\.fileId) == [1])
        #expect(try store.prints(of: [1]).isEmpty)
        #expect(try store.staleIds() == [1])
        // A deleted photo takes its row along.
        try library.delete([2])
        #expect(try store.progress() == (indexed: 0, total: 1))
        try store.deleteAll()
        #expect(try store.staleIds().isEmpty)
    }

    @Test func encodingRoundTrips() {
        let floats: [Float] = [1.5, -0.0001, .greatestFiniteMagnitude, 0]
        #expect(SimilarityStore.floats(SimilarityStore.data(floats: floats)) == floats)
        let bytes: [Int8] = [-127, 0, 127, 5]
        #expect(SimilarityStore.bytes(SimilarityStore.data(bytes: bytes)) == bytes)
    }
}
