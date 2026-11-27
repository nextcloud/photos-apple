// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import PhotosDomain
import PhotosModel

extension LibraryStore {
    // MARK: Memories

    /// On this day, trips and the year in review, from purpose-built queries (SPEC §7.12).
    public func memories(onlyOnThisDay: Bool = false, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current)
        async throws -> MemoriesSnapshot
    {
        try await database.writer.read { db in
            var snapshot = MemoriesSnapshot()
            snapshot.onThisDay = Memories.onThisDay(
                try Self.onThisDayCandidates(db, now: now, calendar: calendar), now: now, calendar: calendar)
            guard !onlyOnThisDay else {
                try Self.chooseCovers(&snapshot, db)
                return snapshot
            }
            snapshot.trips = Memories.trips(try Self.tripCandidates(db), locale: locale)
            snapshot.recap = Memories.yearRecap(try Self.recapCandidates(db, calendar: calendar), calendar: calendar)
            // Covers by what this device found out about the photos (SPEC §21.4).
            try Self.chooseCovers(&snapshot, db)
            return snapshot
        }
    }

    static func memoryItems(_ db: Database, sql: String, arguments: StatementArguments = [], into result: inout [MemoryItem]) throws {
        let rows = try Row.fetchCursor(db, sql: sql, arguments: arguments)
        while let row = try rows.next() {
            result.append(
                MemoryItem(fileId: row[0], timestamp: Date(timeIntervalSince1970: row[1] ?? 0), isFavorite: row[2], place: row[3]))
        }
    }

    static let inTimeRange = "\(visible) AND \(timestamp) >= ? AND \(timestamp) < ?"

    /// The items inside the on-this-day windows: twenty short ranges of the timeline index.
    static func onThisDayCandidates(_ db: Database, now: Date, calendar: Calendar) throws -> [MemoryItem] {
        var result: [MemoryItem] = []
        for window in Memories.onThisDayWindows(now: now, calendar: calendar) {
            try memoryItems(
                db, sql: "SELECT media.fileId, \(timestamp), media.isFavorite, NULL FROM media WHERE \(inTimeRange)",
                arguments: [window.range.lowerBound.timeIntervalSince1970, window.range.upperBound.timeIntervalSince1970], into: &result)
        }
        return result
    }

    /// Trips are found by the gaps between consecutive items, so this reads four columns of every visible item.
    static func tripCandidates(_ db: Database) throws -> [MemoryItem] {
        var result: [MemoryItem] = []
        try memoryItems(
            db, sql: "SELECT media.fileId, \(timestamp), media.isFavorite, media.place FROM media WHERE \(visible)", into: &result)
        return result
    }

    /// The items of the newest year that has enough photos for a recap; years are counted in the timeline index.
    static func recapCandidates(_ db: Database, calendar: Calendar) throws -> [MemoryItem] {
        func edge(_ direction: String) throws -> Double? {
            try Double.fetchOne(db, sql: "SELECT \(timestamp) FROM media WHERE \(visible) ORDER BY \(timestamp) \(direction) LIMIT 1")
        }
        guard let newest = try edge("DESC"), let oldest = try edge("ASC") else { return [] }
        let firstYear = calendar.component(.year, from: Date(timeIntervalSince1970: oldest))
        var year = calendar.component(.year, from: Date(timeIntervalSince1970: newest))
        while year >= firstYear {
            defer { year -= 1 }
            guard let start = calendar.date(from: DateComponents(year: year)), let end = calendar.date(from: DateComponents(year: year + 1))
            else { continue }
            let range: StatementArguments = [start.timeIntervalSince1970, end.timeIntervalSince1970]
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media WHERE \(inTimeRange)", arguments: range) ?? 0
            if count >= Memories.recapMinimum {
                var result: [MemoryItem] = []
                try memoryItems(
                    db, sql: "SELECT media.fileId, \(timestamp), media.isFavorite, NULL FROM media WHERE \(inTimeRange)", arguments: range,
                    into: &result)
                return result
            }
        }
        return []
    }
}
