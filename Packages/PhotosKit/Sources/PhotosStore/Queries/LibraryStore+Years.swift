// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB

extension LibraryStore {
    /// The years the visible photos were taken in, newest first, with how many photos each has (the command palette's
    /// years, SPEC §16.2). Years in the device's time zone.
    public func years() async throws -> [(year: Int, count: Int)] {
        try await database.writer.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT CAST(strftime('%Y', \(Self.timestamp), 'unixepoch', 'localtime') AS INTEGER) AS year, count(*) AS count
                    FROM media WHERE \(Self.visible) GROUP BY year ORDER BY year DESC
                    """
            )
            .compactMap { row in
                let year: Int? = row["year"]
                return year.map { ($0, row["count"]) }
            }
        }
    }
}
