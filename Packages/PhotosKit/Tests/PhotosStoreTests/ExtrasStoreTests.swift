// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import Testing

@testable import PhotosDomain
@testable import PhotosModel
@testable import PhotosStore

@Suite struct SmartOfflineStoreTests {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    let now = date(2026, 11, 24)

    func item(_ id: FileID, _ date: Date, path: String? = nil, favorite: Bool = false, archived: Bool = false) -> MediaItem {
        MediaItem(
            fileId: id, path: path ?? "/Photos/p\(id).jpg", mimeType: "image/jpeg", size: 1000, etag: "e\(id)", modifiedAt: date,
            capturedAt: date, width: 4000, height: 3000, isFavorite: favorite, isArchived: archived)
    }

    @Test func candidatesAreTheRecentFavouriteUpcomingAndAlbumPhotos() async throws {
        let database = try AccountDatabase.temporary()
        let library = LibraryStore(database: database)
        let store = SmartOfflineStore(database: database)
        try library.upsert([
            item(1, now.addingTimeInterval(-86_400)),  // recent
            item(2, Self.date(2015, 3, 1), favorite: true),  // favourite
            item(3, Self.date(2019, 11, 27)),  // On this day in three days
            item(4, Self.date(2016, 5, 5)),  // in an album opened yesterday
            item(5, Self.date(2016, 5, 6)),  // nothing
            item(6, now, archived: true),  // archived
            item(7, now, path: "/Photos/WhatsApp/x.jpg"),  // excluded folder
            item(8, now),  // in an offline album already
        ])
        let album = Album(kind: .own, name: "Trip")
        try CollectionStore(database: database).upsertAlbum(album)
        try await database.writer.write { db in
            try db.execute(
                sql: "INSERT INTO albumItem(albumId, fileId, childName, origin, position) VALUES (?, 4, '4.jpg', 'user', 1)",
                arguments: [album.id])
            try db.execute(sql: "INSERT INTO offlineFile(fileId, etag, localPath, bytes, downloadedAt) VALUES (8, 'e8', '8.jpg', 1, 0)")
        }
        try store.noteAlbumViewed(album.id, at: now.addingTimeInterval(-86_400))

        let candidates = try await store.candidates(now: now, excludedFolders: ["/Photos/WhatsApp"], calendar: Self.calendar)
        #expect(Set(candidates.map(\.fileId)) == [1, 2, 3, 4])
        let album4 = try #require(candidates.first { $0.fileId == 4 })
        #expect(album4.albumViewedAt != nil)
        #expect(candidates.first { $0.fileId == 1 }?.albumViewedAt == nil)
        // Every candidate gets a reason from the policy.
        #expect(SmartOfflinePolicy.rank(candidates, now: now, calendar: Self.calendar).count == 4)

        let present = try await store.present([1, 5, 6, 7, 8, 99], excludedFolders: ["/Photos/WhatsApp"])
        #expect(present == [1: "e1", 5: "e5"])
    }

    @Test func keptRowsAndTheSummary() async throws {
        let database = try AccountDatabase.temporary()
        let library = LibraryStore(database: database)
        let store = SmartOfflineStore(database: database)
        try library.upsert([
            item(1, Self.date(2026, 9, 1)), item(2, Self.date(2026, 11, 1)), item(3, Self.date(2014, 1, 1), favorite: true),
        ])
        for (id, reason) in [(FileID(1), SmartOfflineReason.recent), (2, .recent), (3, .favorite)] {
            try await store.insert(
                SmartOfflineStore.Row(
                    fileId: id, etag: "e\(id)", quality: .screen, localPath: "\(id).jpg", bytes: 100, keptAt: now, reason: reason))
        }
        #expect(try store.kept().count == 3)
        var summary = try store.summary()
        #expect(summary.count == 3)
        #expect(summary.bytes == 300)
        #expect(summary.favorites == 1)
        #expect(summary.recentSince == Self.date(2026, 9, 1))
        try await store.updateReasons([3: .onThisDay])
        try await store.delete([1])
        summary = try store.summary()
        #expect(summary.count == 2)
        #expect(summary.onThisDay == 1)
        #expect(summary.recentSince == Self.date(2026, 11, 1))
        try await store.deleteAll()
        #expect(try store.kept().isEmpty)
    }

    @Test func dailyPhotoCandidatesAreImagesAroundTheDayAndFavourites() async throws {
        let database = try AccountDatabase.temporary()
        let library = LibraryStore(database: database)
        var video = item(4, Self.date(2020, 11, 24))
        video.mimeType = "video/mp4"
        video.kind = .video
        try library.upsert([
            item(1, Self.date(2020, 11, 24)), item(2, Self.date(2021, 11, 26)), item(3, Self.date(2021, 12, 10)), video,
            item(5, Self.date(2020, 11, 24), archived: true), item(6, Self.date(2010, 6, 1), favorite: true),
        ])
        try await database.writer.write { db in
            try db.execute(sql: "INSERT INTO person(name) VALUES ('Ada')")
            try db.execute(sql: "INSERT INTO personItem(person, detectionId, fileId, childName) VALUES ('Ada', 1, 1, 'a')")
        }
        let pools = try await library.dailyPhotoCandidates(for: now, calendar: Self.calendar)
        #expect(Set(pools.onThisDay.map(\.fileId)) == [1, 2])
        #expect(pools.onThisDay.first { $0.fileId == 1 }?.hasPeople == true)
        #expect(pools.onThisDay.first { $0.fileId == 2 }?.hasPeople == false)
        #expect(pools.favorites.map(\.fileId) == [6])
    }
}
