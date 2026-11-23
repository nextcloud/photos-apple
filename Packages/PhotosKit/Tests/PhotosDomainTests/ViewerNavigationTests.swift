// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Testing

@testable import PhotosDomain

@Suite struct ViewerNavigationTests {
    @Test func arrowsStepThroughThePager() {
        #expect(ViewerNavigation.command(for: .leftArrow, isVideo: false) == .previous)
        #expect(ViewerNavigation.command(for: .rightArrow, isVideo: false) == .next)
        #expect(ViewerNavigation.command(for: .rightArrow, isVideo: true) == .next)
    }

    @Test func arrowsAreMirroredInRightToLeftLayouts() {
        #expect(ViewerNavigation.command(for: .leftArrow, isVideo: false, rightToLeft: true) == .next)
        #expect(ViewerNavigation.command(for: .rightArrow, isVideo: false, rightToLeft: true) == .previous)
    }

    @Test func escapeAlwaysCloses() {
        #expect(ViewerNavigation.command(for: .escape, isVideo: false) == .close)
        #expect(ViewerNavigation.command(for: .escape, isVideo: true) == .close)
    }

    @Test func spaceClosesAPhotoAndPlaysOrPausesAVideo() {
        #expect(ViewerNavigation.command(for: .space, isVideo: false) == .close)
        #expect(ViewerNavigation.command(for: .space, isVideo: true) == .togglePlayback)
    }

    @Test func steppingStopsAtTheEnds() {
        let ids = [10, 20, 30]
        #expect(ViewerNavigation.target(in: ids, from: 20, delta: 1) == 30)
        #expect(ViewerNavigation.target(in: ids, from: 20, delta: -1) == 10)
        #expect(ViewerNavigation.target(in: ids, from: 30, delta: 1) == nil)
        #expect(ViewerNavigation.target(in: ids, from: 10, delta: -1) == nil)
        #expect(ViewerNavigation.target(in: ids, from: 99, delta: 1) == nil)
        #expect(ViewerNavigation.target(in: ids, from: nil, delta: 1) == nil)
        #expect(ViewerNavigation.canStep(in: ids, from: 10, delta: 1))
        #expect(!ViewerNavigation.canStep(in: ids, from: 10, delta: -1))
    }

    @Test func neighbourAfterDeleting() {
        #expect(ViewerNavigation.neighbour(in: [10, 20, 30], of: 20) == 30)
        #expect(ViewerNavigation.neighbour(in: [10, 20, 30], of: 30) == 20)
        #expect(ViewerNavigation.neighbour(in: [10], of: 10) == nil)
    }
}
