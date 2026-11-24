// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosAppUI

/// The date scrubber's year labels fit the track: none overlap, the ends of the library stay named.
@Suite struct GridScrubberLayoutTests {
    @Test func theTrackMapsFractionsWithinItsInsets() {
        let track = GridScrubberTrack(bounds: 520, inset: 10)
        #expect(track.y(for: 0) == 10)
        #expect(track.y(for: 1) == 510)
        #expect(track.y(for: 2) == 510)
        #expect(track.fraction(at: 260) == 0.5)
        #expect(track.fraction(at: -40) == 0)
    }

    @Test func labelsThatFitAreAllShown() {
        #expect(GridScrubberTrack.visibleLabels(at: [0, 30, 60, 90], spacing: 20) == [0, 1, 2, 3])
    }

    /// 26 years crowded into the lower part of a short track (old years with few photos): labels are skipped, never
    /// drawn over each other, and the oldest year is kept.
    @Test func crowdedLabelsAreSkippedAndTheOldestStays() {
        let positions: [Double] = [0, 100] + (0..<24).map { 400 + Double($0) * 4 }
        let shown = GridScrubberTrack.visibleLabels(at: positions, spacing: 20)
        #expect(shown.first == 0)
        #expect(shown.last == positions.count - 1)
        for (a, b) in zip(shown, shown.dropFirst()) { #expect(positions[b] - positions[a] >= 20) }
        #expect(shown.count < positions.count)
    }

    @Test func labelsNearThePositionLabelAreLeftOut() {
        let shown = GridScrubberTrack.visibleLabels(at: [0, 50, 100, 150], spacing: 20, bubbleY: 55, clearance: 22)
        #expect(shown == [0, 2, 3])
    }

    @Test func twoYearsThatDoNotFitKeepTheNewest() {
        #expect(GridScrubberTrack.visibleLabels(at: [0, 5], spacing: 20) == [0])
        #expect(GridScrubberTrack.visibleLabels(at: [], spacing: 20).isEmpty)
    }
}
