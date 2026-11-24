// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// "Show in timeline" (SPEC VW-3): which tile of the library timeline stands for a photo.
public enum TimelineReveal {
    /// What the timeline highlights for a photo.
    public enum Target<ID: Hashable>: Hashable {
        /// The photo's own tile, or the tile of the stack it is a copy in.
        case tile(ID)
        /// The photo is not in the timeline (archived, in a hidden partner folder, outside the timeline folders): the
        /// tile closest in time, so the timeline still opens at the photo's day.
        case nearest(ID)

        public var id: ID {
            switch self {
            case .tile(let id), .nearest(let id): id
            }
        }
    }

    /// The tile for the photo `id` taken at `date`.
    /// - Parameters:
    ///   - tiles: the timeline's tiles in their order: id, date and, for a stack, the ids of its copies.
    /// - Returns: nil for an empty timeline.
    public static func target<ID: Hashable>(for id: ID, date: Date, in tiles: [(id: ID, date: Date, stack: [ID])]) -> Target<ID>? {
        var nearest: (id: ID, distance: TimeInterval)?
        for tile in tiles {
            if tile.id == id || tile.stack.contains(id) { return .tile(tile.id) }
            let distance: TimeInterval = abs(tile.date.timeIntervalSince(date))
            if let best = nearest, best.distance <= distance { continue }
            nearest = (tile.id, distance)
        }
        return nearest.map { .nearest($0.id) }
    }
}
