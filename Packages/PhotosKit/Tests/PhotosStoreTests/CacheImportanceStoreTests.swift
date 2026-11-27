// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import Testing

@testable import PhotosDomain
@testable import PhotosModel
@testable import PhotosStore

/// Recently viewed photos, roles and the importance the preview cache evicts by (SPEC §18.2).
@Suite struct CacheImportanceStoreTests {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    let now = date(2026, 11, 24)

    func item(_ id: FileID, _ date: Date, favorite: Bool = false) -> MediaItem {
        MediaItem(
            fileId: id, path: "/Photos/p\(id).jpg", mimeType: "image/jpeg", size: 1000, etag: "e\(id)", modifiedAt: date,
            capturedAt: date, width: 4000, height: 3000, isFavorite: favorite)
    }

    @Test func viewsAreCountedAndBounded() async throws {
        let database = try AccountDatabase.temporary()
        let store = CacheImportanceStore(database: database)
        try await store.noteViewed(1, at: now.addingTimeInterval(-60))
        try await store.noteViewed(2, at: now.addingTimeInterval(-30))
        try await store.noteViewed(1, at: now)
        let viewed = try store.recentlyViewed()
        #expect(viewed.map(\.fileId) == [1, 2])
        #expect(viewed.map(\.count) == [2, 1])
        #expect(viewed.first?.viewedAt == now)
        // Only the newest are remembered.
        for id in 100..<(100 + CacheImportanceStore.recentlyViewedLimit) {
            try await store.noteViewed(FileID(id), at: now.addingTimeInterval(Double(id)))
        }
        let all = try store.recentlyViewed(limit: 10_000)
        #expect(all.count == CacheImportanceStore.recentlyViewedLimit)
        #expect(!all.contains { $0.fileId == 1 || $0.fileId == 2 })
    }

    @Test func rolesComeFromCoversAndFromTheApp() async throws {
        let database = try AccountDatabase.temporary()
        let store = CacheImportanceStore(database: database)
        let collections = CollectionStore(database: database)
        try collections.upsertAlbum(Album(kind: .own, name: "Trip", coverFileId: 10))
        try collections.upsertAlbum(Album(kind: .own, name: "Party", lastPhotoFileId: 11))
        try await database.writer.write { db in
            try db.execute(sql: "INSERT INTO person(name, itemCount, coverFileId) VALUES ('Ann', 3, 12)")
            try db.execute(sql: "INSERT INTO place(name, itemCount, coverFileId) VALUES ('Lisbon', 3, 10)")
        }
        #expect(try await store.setRole(.keyPhoto, fileIds: [10, 13]))
        #expect(try await store.setRole(.keyPhoto, fileIds: [10, 13]) == false)  // unchanged: nothing written
        #expect(try await store.setRole(.memoryCover, fileIds: [14]))
        let roles = try store.roles()
        #expect(roles[10] == [.cover, .keyPhoto])
        #expect(roles[11] == .cover)
        #expect(roles[12] == .face)
        #expect(roles[13] == .keyPhoto)
        #expect(roles[14] == .memoryCover)
        try await store.setRole(.keyPhoto, fileIds: [])
        #expect(try store.roles()[13] == nil)
        #expect(try await store.prominentFileIds() == [10, 11, 12, 14])
    }

    @Test func viewedAndCoverPhotosAreSmartOfflineCandidatesAndHaveATier() async throws {
        let database = try AccountDatabase.temporary()
        try LibraryStore(database: database).upsert([
            item(1, Self.date(2015, 6, 1)),  // viewed yesterday
            item(2, Self.date(2015, 6, 2)),  // an album's cover
            item(3, Self.date(2015, 6, 3)),  // nothing
            item(4, now.addingTimeInterval(-86_400)),  // recent
            item(5, Self.date(2015, 6, 4)),  // viewed long ago
        ])
        try CollectionStore(database: database).upsertAlbum(Album(kind: .own, name: "Trip", coverFileId: 2))
        let store = CacheImportanceStore(database: database)
        try await store.noteViewed(1, at: now.addingTimeInterval(-86_400))
        try await store.noteViewed(5, at: now.addingTimeInterval(-200 * 86_400))
        // A cover of a photo that is not in the library (an album shared with the user).
        try await store.setRole(.memoryCover, fileIds: [99])

        let candidates = try await SmartOfflineStore(database: database).candidates(now: now, calendar: Self.calendar)
        #expect(Set(candidates.map(\.fileId)) == [1, 2, 4])
        let viewed = try #require(candidates.first { $0.fileId == 1 })
        #expect(viewed.viewCount == 1 && viewed.viewedAt != nil)
        #expect(candidates.first { $0.fileId == 2 }?.roles == .cover)
        let ranked = SmartOfflinePolicy.rank(candidates, now: now, calendar: Self.calendar)
        #expect(ranked.map(\.fileId) == [4, 1, 2])
        #expect(ranked.map(\.reason) == [.recent, .viewed, .cover])

        let tiers = try store.tiers(now: now, calendar: Self.calendar)
        #expect(tiers[3] == nil && tiers[5] == nil)
        #expect(tiers[4] == 4 && tiers[1] == 3 && tiers[2] == 2 && tiers[99] == 3)
        #expect(try store.libraryEtags() == [1: "e1", 2: "e2", 3: "e3", 4: "e4", 5: "e5"])
    }

    /// The eviction context is two queries over the whole library: fast for 100 000 photos.
    @Test func tiersOfALargeLibraryAreQuick() async throws {
        let database = try AccountDatabase.temporary()
        let start = Self.date(2000, 1, 1)
        try LibraryStore(database: database).upsert([item(1, start)])
        // 99 999 copies of it in one statement (upserting them one by one would take the test most of a minute).
        try await database.writer.write { db in
            let columns = try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('media')")
            let values = columns.map { column -> String in
                switch column {
                case "fileId": "n.i"
                case "path": "'/Photos/p' || n.i || '.jpg'"
                case "etag": "'e' || n.i"
                case "capturedAt", "modifiedAt": "\(start.timeIntervalSince1970) + n.i * 9000.0"
                case "isFavorite": "n.i % 50 = 0"
                default: "template.\(column)"
                }
            }
            try db.execute(
                sql: """
                    WITH RECURSIVE n(i) AS (SELECT 2 UNION ALL SELECT i + 1 FROM n WHERE i < 100000)
                    INSERT INTO media(\(columns.joined(separator: ", ")))
                    SELECT \(values.joined(separator: ", ")) FROM n, media AS template WHERE template.fileId = 1
                    """)
        }
        let store = CacheImportanceStore(database: database)
        for id in 1...300 { try await store.noteViewed(FileID(id * 7), at: now.addingTimeInterval(-Double(id) * 3600)) }
        let clock = ContinuousClock()
        var tiers: [FileID: UInt8] = [:]
        var etags: [FileID: String] = [:]
        let elapsed = try clock.measure {
            tiers = try store.tiers(now: now, calendar: Self.calendar)
            etags = try store.libraryEtags()
        }
        #expect(etags.count == 100_000)
        #expect(tiers.count > 2000)
        // Three seconds on a Mac (the macOS test job); the CI simulator is several times slower.
        #if targetEnvironment(simulator)
            let budget: Duration = .seconds(15)
        #else
            let budget: Duration = .seconds(3)
        #endif
        #expect(elapsed < budget, "\(elapsed)")
    }
}
