// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import Testing

@testable import PhotosModel
@testable import PhotosStore

/// Album dates are stored as seconds since 1970 (the columns are `REAL`), and the text older versions wrote still reads.
@Suite struct AlbumRecordDateTests {
    @Test func albumDatesAreWrittenAsSecondsSince1970() async throws {
        let database = try AccountDatabase.temporary()
        let collections = CollectionStore(database: database)
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let album = Album(kind: .own, name: "Trip", dateStart: start, dateEnd: start.addingTimeInterval(3600))
        try collections.upsertAlbum(album)

        let stored = try await database.writer.read { db -> (kind: String, fetched: String, value: Double)? in
            guard
                let row = try Row.fetchOne(db, sql: "SELECT typeof(dateStart) AS kind, dateStart, typeof(fetchedAt) AS fetched FROM album")
            else { return nil }
            return (row["kind"], row["fetched"], row["dateStart"])
        }
        let row = try #require(stored)
        #expect(row.kind == "real")
        #expect(row.fetched == "real")
        #expect(row.value == 1_750_000_000)
        #expect(try collections.album(id: album.id)?.dateStart == start)
    }

    @Test func textDatesOfOlderVersionsStillRead() async throws {
        let database = try AccountDatabase.temporary()
        let collections = CollectionStore(database: database)
        let album = Album(kind: .own, name: "Old")
        try collections.upsertAlbum(album)
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE album SET dateStart = '2025-06-15 12:00:00.000' WHERE id = ?", arguments: [album.id])
        }
        let read = try #require(try collections.album(id: album.id)?.dateStart)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day, .hour], from: read)
        #expect(parts == DateComponents(year: 2025, month: 6, day: 15, hour: 12))
    }
}
