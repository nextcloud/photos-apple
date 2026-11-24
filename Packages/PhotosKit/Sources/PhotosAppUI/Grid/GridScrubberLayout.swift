// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Geometry of the date scrubber at the trailing edge of a grid (SPEC §6.4), shared by the UIKit and AppKit grids.
///
/// The track runs along the visible part of the grid, between the bars; a position along it is a fraction from
/// 0 (newest, top) to 1 (oldest, bottom).
struct GridScrubberTrack: Equatable {
    /// Top of the track in the scrubber's coordinates.
    var top: Double
    var height: Double

    /// - Parameter inset: room left at both ends, so the labels at the ends are drawn whole.
    init(bounds height: Double, inset: Double) {
        top = inset
        self.height = max(height - 2 * inset, 1)
    }

    func y(for fraction: Double) -> Double {
        top + min(max(fraction, 0), 1) * height
    }

    func fraction(at y: Double) -> Double {
        min(max((y - top) / height, 0), 1)
    }

    /// Which year labels are drawn, as indexes into `positions` (their y along the track, top to bottom).
    ///
    /// There is room for a label every `spacing` points. Where years are closer than that (old years with few photos,
    /// a short screen, a large text size), labels are left out — never drawn over each other. The newest year is kept,
    /// and the oldest too, so that the ends of the library stay named. A label within `clearance` of the position
    /// label (`bubbleY`) is left out as well.
    static func visibleLabels(at positions: [Double], spacing: Double, bubbleY: Double? = nil, clearance: Double = 0) -> [Int] {
        let clear: (Double) -> Bool = { (y: Double) -> Bool in
            guard let bubbleY else { return true }
            return abs(y - bubbleY) >= clearance
        }
        var shown: [Int] = []
        for (index, y) in positions.enumerated() where clear(y) {
            if let last = shown.last, y - positions[last] < spacing { continue }
            shown.append(index)
        }
        // The oldest year: it replaces the labels it would run into.
        if let oldest = positions.indices.last, shown.last != oldest, clear(positions[oldest]) {
            while let last = shown.last, shown.count > 1, positions[oldest] - positions[last] < spacing { shown.removeLast() }
            if let last = shown.last, positions[oldest] - positions[last] < spacing {
                // Only the newest year is left and the two do not fit: the newest one stays.
                return shown
            }
            shown.append(oldest)
        }
        return shown
    }
}
