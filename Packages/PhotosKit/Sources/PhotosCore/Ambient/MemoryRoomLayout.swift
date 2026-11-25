// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// Where the photos of a memory hang in the Vision Pro memory room (SPEC §15.4): framed pictures on a ring around the
/// viewer, in one row or two, facing the centre. Pure geometry in metres (RealityKit's axes: y up, −z in front of the
/// viewer when the room opens); the room itself is built on visionOS.
public enum MemoryRoomLayout {
    /// More frames than this crowd the room and take long to load.
    public static let maximumFrames = 24
    /// The long side of a frame's photo.
    public static let photoSize: Float = 0.6
    /// Room between neighbouring frames on a ring.
    static let spacing: Float = 0.3
    static let minimumRadius: Float = 2.0

    /// Up to `maximumFrames` photos of the memory, in their order: favourites always, the others evenly spread.
    public static func pick<Item>(_ items: [Item], isFavorite: (Item) -> Bool, limit: Int = maximumFrames) -> [Item] {
        guard items.count > limit else { return items }
        let favorites = Set(items.indices.filter { isFavorite(items[$0]) }.prefix(limit))
        let others = items.indices.filter { !favorites.contains($0) }
        let wanted = limit - favorites.count
        var chosen = favorites
        if wanted > 0, !others.isEmpty {
            for step in 0..<wanted {
                chosen.insert(others[step * others.count / wanted])
            }
        }
        return chosen.sorted().map { items[$0] }
    }

    public struct Placement: Equatable, Sendable {
        /// The centre of the frame.
        public var position: SIMD3<Float>
        /// The turn around the vertical axis (radians) that makes the frame face the centre.
        public var yaw: Float
    }

    /// The part of the ring right in front of the viewer that stays free (radians, both sides together): the app's
    /// window and the memory's title are there.
    public static let frontGap: Float = .pi / 3

    /// The frames in one row up to 12, else in two rows (one at sitting, one at standing eye height); from the right of
    /// the window clockwise around the viewer to its left. A little height varies per frame so the walls do not look like
    /// a grid.
    public static func placements(count: Int) -> [Placement] {
        guard count > 0 else { return [] }
        let rows = count > 12 ? 2 : 1
        let perRow = Int((Double(count) / Double(rows)).rounded(.up))
        let span = 2 * Float.pi - frontGap
        let length = Float(perRow) * (photoSize + spacing)
        let radius = max(minimumRadius, length / span)
        return (0..<count).map { index in
            let row = rows == 1 ? 0 : index % 2
            let column = rows == 1 ? index : index / 2
            // The second row sits between the frames of the first.
            let offset: Float = row == 1 ? 0.25 : 0
            let angle = frontGap / 2 + span * (Float(column) + 0.5 + offset) / Float(perRow)
            let baseHeight: Float = rows == 1 ? 1.45 : (row == 0 ? 1.1 : 1.85)
            let jitter = Float((index * 37) % 7 - 3) * 0.025
            let position = SIMD3<Float>(radius * sin(angle), baseHeight + jitter, -radius * cos(angle))
            return Placement(position: position, yaw: -angle)
        }
    }

    /// The size of a frame's photo for its pixel size: the long side is `photoSize`.
    public static func photoExtent(width: Int?, height: Int?) -> SIMD2<Float> {
        guard let width, let height, width > 0, height > 0 else { return [photoSize, photoSize * 0.75] }
        let ratio = Float(width) / Float(height)
        return ratio >= 1 ? [photoSize, photoSize / ratio] : [photoSize * ratio, photoSize]
    }

    /// Where a frame comes when the viewer pinches it: in front, at eye height, within reach.
    public static let focusPosition = SIMD3<Float>(0, 1.55, -1.5)
    public static let focusScale: Float = 1.2
}
