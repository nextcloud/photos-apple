// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosDomain
import PhotosModel
import Testing

@testable import PhotosAppUI

/// Smart albums store their filters as `AlbumFilters`; opening one rebuilds the search filters from them.
@Suite struct SmartAlbumFilterTests {
    @Test func tagsSurviveTheRoundTripThroughASmartAlbum() {
        let filters: [SearchFilter] = [.place("Lisbon"), .tag(id: 7, name: "Holiday"), .text("beach")]
        let stored = SearchEvaluator.albumFilters(filters)
        #expect(stored.tags == ["Holiday"])

        let rebuilt = SearchEvaluator.searchFilters(stored, tags: [SystemTag(id: 7, name: "Holiday"), SystemTag(id: 9, name: "Work")])
        #expect(Set(rebuilt) == Set(filters))
    }

    /// A tag that was deleted on the server must not be dropped: the album would then show more than it should.
    @Test func aTagTheServerNoLongerHasMatchesNothing() {
        let rebuilt = SearchEvaluator.searchFilters(AlbumFilters(tags: ["Gone"]), tags: [])
        #expect(rebuilt == [.tag(id: SearchEvaluator.unknownTagId, name: "Gone")])
    }
}
