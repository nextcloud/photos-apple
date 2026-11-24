// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosDomain

/// The slideshow of any grid (SPEC VW-5) and "Show in library" (VW-3).
@Suite struct ViewerFeaturesTests {
    @Test func theSlideshowStartsAtThePhotoItWasStartedFrom() {
        #expect(SlideshowPlan.order([1, 2, 3, 4], from: 3) == [3, 4, 1, 2], "the photos before it follow at the end")
        #expect(SlideshowPlan.order([1, 2, 3, 4], from: 1) == [1, 2, 3, 4])
        #expect(SlideshowPlan.order([1, 2, 3, 4], from: nil) == [1, 2, 3, 4])
        #expect(SlideshowPlan.order([1, 2, 3, 4], from: 9) == [1, 2, 3, 4], "a photo outside the context starts at the first")
        #expect(SlideshowPlan.order([Int](), from: 1) == [])
    }

    @Test func theSlideshowRepeatsOrStopsAfterTheLastPhoto() {
        #expect(SlideshowPlan.next(after: 0, count: 3, repeats: false) == 1)
        #expect(SlideshowPlan.next(after: 2, count: 3, repeats: true) == 0)
        #expect(SlideshowPlan.next(after: 2, count: 3, repeats: false) == nil)
        #expect(SlideshowPlan.next(after: 0, count: 0, repeats: true) == nil)
        #expect(SlideshowPlan.next(after: 0, count: 1, repeats: true) == 0)
    }

    @Test func aStoredIntervalIsOneThatIsOffered() {
        #expect(SlideshowPlan.intervals.contains(SlideshowPlan.defaultInterval))
        #expect(SlideshowPlan.interval(seconds: 5) == 5)
        #expect(SlideshowPlan.interval(seconds: 4) == 3 || SlideshowPlan.interval(seconds: 4) == 5)
        #expect(SlideshowPlan.interval(seconds: 0) == 2)
        #expect(SlideshowPlan.interval(seconds: 600) == 20)
        #expect(SlideshowPlan.driftDuration(interval: 3) > 3, "the slow zoom does not stop before the cross-fade")
    }

    @Test func showInLibraryFindsThePhotoItsStackOrItsDay() {
        let day: TimeInterval = 86_400
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // Newest first, as the timeline is.
        let tiles: [(id: Int, date: Date, stack: [Int])] = [
            (id: 5, date: base.addingTimeInterval(3 * day), stack: []),
            (id: 4, date: base.addingTimeInterval(2 * day), stack: [4, 40]),
            (id: 2, date: base, stack: []),
        ]
        #expect(TimelineReveal.target(for: 5, date: base, in: tiles) == .tile(5))
        #expect(TimelineReveal.target(for: 40, date: base, in: tiles) == .tile(4), "a copy is shown by its stack's tile")
        // Archived, or in a hidden folder: the tile closest in time, so the Library opens at that day.
        #expect(TimelineReveal.target(for: 9, date: base.addingTimeInterval(2.2 * day), in: tiles) == .nearest(4))
        #expect(TimelineReveal.target(for: 9, date: base.addingTimeInterval(-9 * day), in: tiles) == .nearest(2))
        #expect(TimelineReveal.target(for: 9, date: base, in: [(id: Int, date: Date, stack: [Int])]()) == nil)
        #expect(TimelineReveal.Target<Int>.nearest(4).id == 4)
    }
}
