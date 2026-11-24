// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosDomain
@testable import PhotosModel

/// The album a memory is saved as (SPEC ME-4).
@Suite struct MemoryAlbumTests {
    let locale = Locale(identifier: "en_US")

    func memory(_ kind: Memory.Kind, title: String) -> Memory {
        Memory(id: "m", kind: kind, title: title, start: day(2025, 11, 20), end: day(2025, 11, 26), cover: 1, items: [1, 2])
    }

    @Test func tripsAndRecapsKeepTheirTitleOnThisDayItsDates() {
        #expect(Memories.albumName(for: memory(.trip, title: "Lisbon & Porto"), existing: [], locale: locale) == "Lisbon & Porto")
        #expect(Memories.albumName(for: memory(.yearRecap(2025), title: "2025 in review"), existing: []) == "2025 in review")
        let onThisDay = memory(.yearsAgo(1), title: "1 year ago")
        #expect(
            Memories.albumName(for: onThisDay, existing: [], locale: locale, calendar: utcCalendar)
                == DateRangeLabel.string(from: onThisDay.start, to: onThisDay.end, locale: locale, calendar: utcCalendar))
    }

    @Test func takenNamesGetANumberAndSlashesADash() {
        let trip = memory(.trip, title: "Lisbon & Porto")
        #expect(Memories.albumName(for: trip, existing: ["Lisbon & Porto"]) == "Lisbon & Porto (2)")
        #expect(Memories.albumName(for: trip, existing: ["Lisbon & Porto", "Lisbon & Porto (2)"]) == "Lisbon & Porto (3)")
        #expect(Memories.albumName(for: memory(.trip, title: "12/3/2024 – 15/3/2024"), existing: []) == "12-3-2024 – 15-3-2024")
        #expect(Memories.albumName(for: memory(.trip, title: " / "), existing: []) == "-")
    }
}
