// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Testing

@testable import PhotosAppUI

/// Story cards snap without a scroll target behaviour (SPEC §20.1).
struct MemoryStorySnapTests {
    // Cards of 300 pt with 10 pt between them, after a 12 pt inset: card n begins at 12 + 310 n.
    let stride = 310.0
    let inset = 12.0

    @Test func theNearestCardWins() {
        #expect(MemoryStorySnap.nearest(offset: 0, leadingInset: inset, stride: stride, count: 5) == 0)
        #expect(MemoryStorySnap.nearest(offset: 12 + 150, leadingInset: inset, stride: stride, count: 5) == 0)
        #expect(MemoryStorySnap.nearest(offset: 12 + 160, leadingInset: inset, stride: stride, count: 5) == 1)
        #expect(MemoryStorySnap.nearest(offset: 12 + 310 * 3, leadingInset: inset, stride: stride, count: 5) == 3)
        // Past the end (the last item is narrower) and before the start (rubber band).
        #expect(MemoryStorySnap.nearest(offset: 5000, leadingInset: inset, stride: stride, count: 5) == 4)
        #expect(MemoryStorySnap.nearest(offset: -40, leadingInset: inset, stride: stride, count: 5) == 0)
        #expect(MemoryStorySnap.nearest(offset: 100, leadingInset: inset, stride: 0, count: 5) == 0)
    }

    @Test func aFlingMovesOnByOneCardInItsDirection() {
        let start = 12 + 310.0
        // A short fling forward or back: one card, even a long fling never skips cards.
        #expect(MemoryStorySnap.paged(startIndex: 1, startOffset: start, endOffset: start + 40, speed: 900, stride: stride, count: 5) == 2)
        #expect(MemoryStorySnap.paged(startIndex: 1, startOffset: start, endOffset: start - 40, speed: 900, stride: stride, count: 5) == 0)
        #expect(
            MemoryStorySnap.paged(startIndex: 1, startOffset: start, endOffset: start + 290, speed: 5000, stride: stride, count: 5) == 2)
        // Not past the ends.
        #expect(MemoryStorySnap.paged(startIndex: 4, startOffset: 1252, endOffset: 1300, speed: 900, stride: stride, count: 5) == 4)
        #expect(MemoryStorySnap.paged(startIndex: 0, startOffset: 12, endOffset: -30, speed: 900, stride: stride, count: 5) == 0)
    }

    @Test func aSlowDragGoesOnOnlyPastAThird() {
        let start = 12 + 310.0
        #expect(MemoryStorySnap.paged(startIndex: 1, startOffset: start, endOffset: start + 90, speed: 0, stride: stride, count: 5) == 1)
        #expect(MemoryStorySnap.paged(startIndex: 1, startOffset: start, endOffset: start + 120, speed: 0, stride: stride, count: 5) == 2)
        #expect(MemoryStorySnap.paged(startIndex: 1, startOffset: start, endOffset: start - 120, speed: 0.2, stride: stride, count: 5) == 0)
        // A tap that wobbled is not a fling.
        #expect(MemoryStorySnap.paged(startIndex: 1, startOffset: start, endOffset: start + 3, speed: 900, stride: stride, count: 5) == 1)
    }
}
