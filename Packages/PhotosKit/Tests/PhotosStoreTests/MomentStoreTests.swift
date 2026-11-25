// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import Testing

@testable import PhotosDomain
@testable import PhotosModel
@testable import PhotosStore

/// The queries behind the Library's moments and the store of worded titles (SPEC §16.1).
@Suite struct MomentStoreTests {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func item(_ id: FileID, hour: Int, path: String = "/Photos/x.jpg", place: String? = "Lisbon") -> MediaItem {
        let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: hour))!
        return MediaItem(
            fileId: id, path: path, mimeType: "image/jpeg", etag: "e\(id)", modifiedAt: date, capturedAt: date, place: place,
            placeCountry: place == nil ? nil : "Portugal", isArchived: path.hasPrefix("/.archive/"))
    }

    @Test func itemsWithPlacesPeopleAndActivityLabels() async throws {
        let database = try AccountDatabase.temporary()
        let store = LibraryStore(database: database)
        try store.upsert([
            item(1, hour: 10), item(2, hour: 11), item(3, hour: 12, place: nil), item(4, hour: 13, path: "/.archive/Photos/a.jpg"),
            item(5, hour: 14, path: "/Photos/WhatsApp/w.jpg"),
        ])
        try await database.writer.write { db in
            try db.execute(sql: "INSERT INTO person(name) VALUES ('Anna'), ('42'), ('Hidden')")
            try db.execute(
                sql: """
                    INSERT INTO personItem(person, detectionId, fileId, childName)
                    VALUES ('Anna', 1, 1, 'a'), ('Anna', 2, 1, 'a'), ('42', 3, 2, 'b'), ('Hidden', 4, 2, 'b')
                    """)
            // Only activity words are kept; labels of an older version of the file do not count.
            try db.execute(
                sql: """
                    INSERT INTO visionLabel(fileId, etag, labels, labeledAt)
                    VALUES (1, 'e1', 'birthday cake balloon', 0), (2, 'old', 'beach', 0), (3, 'e3', 'dog grass', 0)
                    """)
        }
        let items = try await store.momentItems(excludedFolders: ["/Photos/WhatsApp"], hiddenPeople: ["Hidden"])
        // Newest first; archived and excluded items are not part of the Library.
        #expect(items.map(\.fileId) == [3, 2, 1])
        let first = try #require(items.first { $0.fileId == 1 })
        #expect(first.people == ["Anna"])
        #expect(first.labels == ["birthday"])
        #expect(first.place == "Lisbon" && first.country == "Portugal")
        #expect(items.first { $0.fileId == 2 }?.people == [])
        #expect(items.first { $0.fileId == 2 }?.labels == [])
        #expect(items.first { $0.fileId == 3 }?.labels == [])

        let moments = LibraryMoments.build(items, home: "Berlin", calendar: calendar)
        #expect(moments.count == 1)
        #expect(moments.first?.title == .activity(.birthday, place: nil, person: "Anna"))
    }

    @Test func wordedTitlesAreKeptWhileTheirFactsStayTheSame() async throws {
        let database = try AccountDatabase.temporary()
        let titles = MomentTitleStore(database: database)
        try await titles.save(id: "moment-1-1", facts: "Lisbon;away", title: "Pastéis in Lisbon")
        try await titles.save(id: "moment-2-2", facts: "Porto;away", title: "Port wine evening")
        let found = try await titles.titles(for: [("moment-1-1", "Lisbon;away"), ("moment-2-2", "Porto;away;Anna"), ("moment-3-3", "x")])
        #expect(found == ["moment-1-1": "Pastéis in Lisbon"])
        // Worded again: replaced.
        try await titles.save(id: "moment-2-2", facts: "Porto;away;Anna", title: "Porto with Anna")
        #expect(try await titles.titles(for: [("moment-2-2", "Porto;away;Anna")]) == ["moment-2-2": "Porto with Anna"])
        try await titles.removeAll()
        #expect(try await titles.titles(for: [("moment-1-1", "Lisbon;away")]).isEmpty)
    }
}
