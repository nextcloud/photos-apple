// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import Testing

@testable import PhotosDomain
@testable import PhotosModel
@testable import PhotosStore

/// The year in review's queries (SPEC §15.1).
@Suite struct YearReviewStoreTests {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    func item(_ id: FileID, _ date: Date, path: String = "/Photos/x.jpg", mime: String = "image/jpeg") -> MediaItem {
        MediaItem(
            fileId: id, path: path, mimeType: mime, etag: "e\(id)", modifiedAt: date, capturedAt: date, latitude: 38.7,
            longitude: -9.1, place: "Lisbon", placeCountry: "Portugal", isArchived: path.hasPrefix("/.archive/"))
    }

    @Test func yearsWithEnoughPhotosAndTheItemsOfOne() async throws {
        let database = try AccountDatabase.temporary()
        let store = LibraryStore(database: database)
        var items = (0..<35).map { item(FileID($0 + 1), date(2024, 1 + $0 % 12, 3)) }
        items += (0..<10).map { item(FileID($0 + 100), date(2023, 5, 1 + $0)) }
        items.append(item(200, date(2024, 6, 6), path: "/.archive/Photos/a.jpg"))
        items.append(item(201, date(2024, 6, 7), mime: "video/mp4"))
        try store.upsert(items)
        try await database.writer.write { db in
            try db.execute(sql: "INSERT INTO person(name) VALUES ('Ada'), ('42')")
            try db.execute(
                sql: """
                    INSERT INTO personItem(person, detectionId, fileId, childName)
                    VALUES ('Ada', 1, 1, 'a'), ('Ada', 2, 1, 'a'), ('42', 3, 2, 'b')
                    """)
            // Labels of the current version count; those of an older version of the file do not.
            try db.execute(
                sql: "INSERT INTO visionLabel(fileId, etag, labels, labeledAt) VALUES (1, 'e1', 'dog grass', 0), (2, 'old', 'snow', 0)")
        }

        #expect(try await store.reviewYears(calendar: calendar) == [2024])

        let rows = try await store.yearReviewItems(year: 2024, calendar: calendar)
        // The archived photo is not part of the year.
        #expect(rows.count == 36)
        #expect(!rows.contains { $0.fileId == 200 })
        let first = try #require(rows.first { $0.fileId == 1 })
        #expect(first.people == ["Ada"])
        #expect(first.labels == ["dog", "grass"])
        #expect(first.place == "Lisbon" && first.country == "Portugal")
        #expect(first.location == GeoPoint(latitude: 38.7, longitude: -9.1))
        #expect(rows.first { $0.fileId == 2 }?.labels == [])
        #expect(rows.first { $0.fileId == 201 }?.isVideo == true)

        let review = YearInReview(year: 2024, items: rows, calendar: calendar)
        // "42" is one of Recognize's unnamed people.
        #expect(review.people.map(\.name) == ["Ada"])

        let recap = try await store.recap(year: 2024, calendar: calendar)
        #expect(recap?.kind == .yearRecap(2024))
        #expect(try await store.recap(year: 2023, calendar: calendar) == nil)
    }
}
