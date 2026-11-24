// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// The albums "Add to Album" offers first, as a submenu of the Image menu and of the grid's context menu (SPEC §6.2).
public enum RecentAlbums {
    /// How many albums the submenu lists; the others are in "All Albums…".
    public static let menuLimit = 8
    /// How many used albums are remembered.
    public static let rememberedLimit = 20

    /// The albums used last in this app first (newest first), then the most recently changed ones, up to `limit`.
    public static func pick(_ albums: [Album], used: [String], limit: Int = menuLimit) -> [Album] {
        let byId = Dictionary(albums.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [Album] = []
        var taken = Set<String>()
        for id in used where result.count < limit {
            guard let album = byId[id], taken.insert(id).inserted else { continue }
            result.append(album)
        }
        let rest = albums.filter { !taken.contains($0.id) }.sorted { lhs, rhs in
            let left = lhs.lastModified ?? lhs.dateEnd ?? .distantPast
            let right = rhs.lastModified ?? rhs.dateEnd ?? .distantPast
            if left != right { return left > right }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
        for album in rest where result.count < limit {
            result.append(album)
        }
        return result
    }

    /// The used albums after `albumId` was used: it moves to the front, without repeats, at most `rememberedLimit`.
    public static func noting(_ albumId: String, in used: [String]) -> [String] {
        Array(([albumId] + used.filter { $0 != albumId }).prefix(rememberedLimit))
    }
}
