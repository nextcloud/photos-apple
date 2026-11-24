// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel
import Testing

@testable import PhotosDomain

/// The "Add to Album" submenus (SPEC §6.2).
@Suite struct AlbumChoicesTests {
    func album(_ name: String, modified: TimeInterval? = nil, end: TimeInterval? = nil) -> Album {
        Album(
            kind: .own, name: name, dateEnd: end.map { Date(timeIntervalSince1970: $0) },
            lastModified: modified.map { Date(timeIntervalSince1970: $0) })
    }

    @Test func usedAlbumsComeFirstThenRecentlyChanged() {
        let albums = [album("Old", modified: 10), album("New", modified: 30), album("Middle", end: 20), album("Used", modified: 1)]
        let picked = RecentAlbums.pick(albums, used: ["own:Used", "own:Gone"], limit: 3)
        #expect(picked.map(\.name) == ["Used", "New", "Middle"])
        #expect(RecentAlbums.pick(albums, used: []).map(\.name) == ["New", "Middle", "Old", "Used"])
        #expect(RecentAlbums.pick([], used: ["own:Used"]).isEmpty)
    }

    @Test func noteMovesToTheFrontWithoutRepeats() {
        #expect(RecentAlbums.noting("b", in: ["a", "b", "c"]) == ["b", "a", "c"])
        let long = (0..<30).map { "album\($0)" }
        let noted = RecentAlbums.noting("new", in: long)
        #expect(noted.count == RecentAlbums.rememberedLimit && noted.first == "new")
    }
}
