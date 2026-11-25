// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import PhotosDomain
import PhotosModel

extension LibraryStore {
    /// The photos the "Photo of the day" for `day` is chosen from (SPEC §15.8.4): photos taken within three days of its date
    /// in earlier years and the favourites, as the library shows them (no videos, no archived photos, no Live Photo
    /// videos, nothing in excluded folders). `hasPeople` is set for photos with a recognised person.
    public func dailyPhotoCandidates(for day: Date, excludedFolders: [String] = [], calendar: Calendar = .current) async throws
        -> (onThisDay: [DailyPhotoCandidate], favorites: [DailyPhotoCandidate])
    {
        var conditions = ["\(Self.visible)", "media.kind = 'image'"]
        var arguments: StatementArguments = []
        for prefix in excludedFolders {
            conditions.append("media.path NOT LIKE ? ESCAPE '\\'")
            arguments += [Self.likePrefix(prefix)]
        }
        var ranges: [String] = []
        var rangeArguments: StatementArguments = []
        let start = calendar.startOfDay(for: day)
        for yearsAgo in 1...Memories.onThisDayYears * 2 {
            guard let anchor = calendar.date(byAdding: .year, value: -yearsAgo, to: start),
                let from = calendar.date(byAdding: .day, value: -Memories.onThisDayWindowDays, to: anchor),
                let to = calendar.date(byAdding: .day, value: Memories.onThisDayWindowDays + 1, to: anchor)
            else { continue }
            ranges.append("(\(Self.timestamp) >= ? AND \(Self.timestamp) < ?)")
            rangeArguments += [from.timeIntervalSince1970, to.timeIntervalSince1970]
        }
        let base = conditions.joined(separator: " AND ")
        let people = "EXISTS (SELECT 1 FROM personItem WHERE personItem.fileId = media.fileId) AS hasPeople"
        let onThisDaySQL = "SELECT media.*, \(people) FROM media WHERE \(base) AND (\(ranges.joined(separator: " OR "))) LIMIT 2000"
        let favoritesSQL = "SELECT media.*, \(people) FROM media WHERE \(base) AND media.isFavorite = 1 \(Self.displayOrder) LIMIT 2000"
        let onThisDayArguments = arguments + rangeArguments
        let favoriteArguments = arguments
        return try await database.writer.read { db in
            func fetch(_ sql: String, _ arguments: StatementArguments) throws -> [DailyPhotoCandidate] {
                try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in
                    DailyPhotoCandidate(try MediaItem(row: row), hasPeople: row["hasPeople"] as Bool? ?? false)
                }
            }
            return (try fetch(onThisDaySQL, onThisDayArguments), try fetch(favoritesSQL, favoriteArguments))
        }
    }
}
