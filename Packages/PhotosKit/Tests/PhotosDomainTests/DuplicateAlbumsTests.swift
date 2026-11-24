// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel
import Testing

@testable import PhotosDomain

/// Duplicates: the albums a deleted copy takes the photo out of (SPEC §7.15).
@Suite struct DuplicateAlbumsTests {
    @Test func albumsThatWouldLoseThePhoto() {
        let placements: [Duplicates.AlbumPlacement] = [
            .init(albumId: "own:Trip", fileId: 2),
            .init(albumId: "own:Trip", fileId: 3),
            .init(albumId: "own:Both", fileId: 2),
            .init(albumId: "own:Both", fileId: 1),
            .init(albumId: "own:Filtered", fileId: 3, byFilter: true),
            .init(albumId: "own:Other", fileId: 9),
        ]
        // Copy 1 is kept, 2 and 3 are deleted: "Both" has the kept copy already, "Filtered" follows its filters.
        #expect(Duplicates.albumsLosingPhoto(deleted: [2, 3], kept: 1, placements: placements) == ["own:Trip"])
        #expect(Duplicates.albumsLosingPhoto(deleted: [2], kept: 1, placements: []).isEmpty)
        #expect(Duplicates.albumsLosingPhoto(deleted: [1], kept: 2, placements: placements).isEmpty)
    }
}
