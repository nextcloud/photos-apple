// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

extension Memories {
    /// The name of the album a memory is saved as (SPEC ME-4): the trip's or the recap's title; for "1 year ago", which
    /// says nothing once the year has passed, its dates. A name that is taken gets " (2)", " (3)"… like the web app's
    /// copies; a slash (not allowed in an album name, it is a path on the server) becomes a dash.
    public static func albumName(
        for memory: Memory, existing: Set<String>, locale: Locale = .current, calendar: Calendar = .current
    ) -> String {
        var base: String
        switch memory.kind {
        case .yearsAgo: base = DateRangeLabel.string(from: memory.start, to: memory.end, locale: locale, calendar: calendar)
        case .trip, .yearRecap, .birthday: base = memory.title
        }
        base = base.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = memory.title.isEmpty ? memory.id : memory.title }
        var name = base
        var counter = 2
        while existing.contains(name) {
            name = "\(base) (\(counter))"
            counter += 1
        }
        return name
    }
}
