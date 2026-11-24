// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import PhotosDomain
import PhotosModel

/// The queries of the year in review and of a past year's film (SPEC §15.1). Archived items are left out like
/// everywhere else (`visible`).
extension LibraryStore {
    /// Years with enough photos for a review, newest first.
    public func reviewYears(calendar: Calendar = .current) async throws -> [Int] {
        try await database.writer.read { db in
            var counts: [Int: Int] = [:]
            let rows = try Double.fetchCursor(db, sql: "SELECT \(Self.timestamp) FROM media WHERE \(Self.visible)")
            while let timestamp = try rows.next() {
                counts[calendar.component(.year, from: Date(timeIntervalSince1970: timestamp)), default: 0] += 1
            }
            return counts.filter { $0.value >= YearInReview.minimumItems }.keys.sorted(by: >)
        }
    }

    /// The items of one year with their named people and on-device labels.
    public func yearReviewItems(year: Int, calendar: Calendar = .current) async throws -> [YearReviewItem] {
        guard let start = calendar.date(from: DateComponents(year: year)), let end = calendar.date(from: DateComponents(year: year + 1))
        else { return [] }
        let range: StatementArguments = [start.timeIntervalSince1970, end.timeIntervalSince1970]
        return try await database.writer.read { db in
            var people: [FileID: [String]] = [:]
            let personRows = try Row.fetchCursor(
                db,
                sql: """
                    SELECT DISTINCT personItem.fileId, personItem.person FROM personItem
                    JOIN media ON media.fileId = personItem.fileId WHERE \(Self.inTimeRange)
                    """, arguments: range)
            while let row = try personRows.next() { people[row[0], default: []].append(row[1]) }

            var labels: [FileID: Set<String>] = [:]
            let labelRows = try Row.fetchCursor(
                db,
                sql: """
                    SELECT visionLabel.fileId, visionLabel.labels FROM visionLabel
                    JOIN media ON media.fileId = visionLabel.fileId AND media.etag = visionLabel.etag WHERE \(Self.inTimeRange)
                    """, arguments: range)
            while let row = try labelRows.next() {
                let text: String = row[1]
                labels[row[0]] = Set(text.split(separator: " ").map(String.init))
            }

            var result: [YearReviewItem] = []
            let rows = try Row.fetchCursor(
                db,
                sql: """
                    SELECT media.fileId, \(Self.timestamp), media.kind, media.isFavorite, media.latitude, media.longitude,
                    media.place, media.placeCountry FROM media WHERE \(Self.inTimeRange)
                    """, arguments: range)
            while let row = try rows.next() {
                let fileId: FileID = row[0]
                let kind: String = row[2]
                result.append(
                    YearReviewItem(
                        fileId: fileId, date: Date(timeIntervalSince1970: row[1]), isVideo: kind == MediaKind.video.rawValue,
                        isFavorite: row[3], location: GeoPoint(latitude: row[4], longitude: row[5]), place: row[6], country: row[7],
                        people: people[fileId] ?? [], labels: labels[fileId] ?? []))
            }
            return result
        }
    }

    /// The highlights film of one year (the year recap of that year), or nil when it has too few photos.
    public func recap(year: Int, calendar: Calendar = .current) async throws -> Memory? {
        guard let start = calendar.date(from: DateComponents(year: year)), let end = calendar.date(from: DateComponents(year: year + 1))
        else { return nil }
        return try await database.writer.read { db in
            var items: [MemoryItem] = []
            try Self.memoryItems(
                db, sql: "SELECT media.fileId, \(Self.timestamp), media.isFavorite, NULL FROM media WHERE \(Self.inTimeRange)",
                arguments: [start.timeIntervalSince1970, end.timeIntervalSince1970], into: &items)
            return Memories.yearRecap(items, year: year, calendar: calendar)
        }
    }
}
