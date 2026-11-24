// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

extension Duplicates {
    /// A copy's place in an album, as the index knows it.
    public struct AlbumPlacement: Hashable, Sendable {
        public var albumId: String
        public var fileId: FileID
        /// The album's filters put the photo there (it follows the filters, not the user).
        public var byFilter: Bool

        public init(albumId: String, fileId: FileID, byFilter: Bool = false) {
            self.albumId = albumId
            self.fileId = fileId
            self.byFilter = byFilter
        }
    }

    /// The albums that lose a photo when `deleted` copies go (SPEC §7.15: warn if the deleted copies are in albums),
    /// with the kept copy not in them yet: those the kept copy can be added to so the albums keep the photo. Albums
    /// whose filters put the copy there are left out — the filters decide, not the user. Sorted by id, no repeats.
    public static func albumsLosingPhoto(deleted: [FileID], kept: FileID, placements: [AlbumPlacement]) -> [String] {
        let deletedIds = Set(deleted)
        let keptIn = Set(placements.filter { $0.fileId == kept }.map(\.albumId))
        let losing = placements.filter { deletedIds.contains($0.fileId) && !$0.byFilter && !keptIn.contains($0.albumId) }
        return Set(losing.map(\.albumId)).sorted()
    }
}
