// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Testing

@testable import PhotosAppUI

/// Zoom geometry of the viewer (SPEC VW-1): fitted size, limits, zooming to a point, keeping the photo on screen.
@Suite struct ViewerZoomTests {
    let page = CGSize(width: 400, height: 800)

    @Test func photoIsFittedIntoThePageKeepingItsShape() {
        #expect(ViewerZoom.fittedSize(content: CGSize(width: 4000, height: 3000), in: page) == CGSize(width: 400, height: 300))
        #expect(ViewerZoom.fittedSize(content: CGSize(width: 1000, height: 4000), in: page) == CGSize(width: 200, height: 800))
        // A small photo is enlarged to the page as well: scale 1 always means "fitted".
        #expect(ViewerZoom.fittedSize(content: CGSize(width: 40, height: 30), in: page) == CGSize(width: 400, height: 300))
        // Shape not known yet: the placeholder fills the page.
        #expect(ViewerZoom.fittedSize(content: .zero, in: page) == page)
        #expect(ViewerZoom.fittedSize(content: CGSize(width: 4, height: 3), in: .zero) == .zero)
    }

    @Test func scaleStaysBetweenFittedAndMaximum() {
        #expect(ViewerZoom.clamped(0.4) == 1)
        #expect(ViewerZoom.clamped(3) == 3)
        #expect(ViewerZoom.clamped(50) == ViewerZoom.maximumScale)
        #expect(ViewerZoom.clamped(.nan) == 1)
        #expect(!ViewerZoom.isZoomed(1))
        #expect(!ViewerZoom.isZoomed(1.005))
        #expect(ViewerZoom.isZoomed(1.2))
    }

    @Test func zoomStepsEndAtTheLimits() {
        #expect(ViewerZoom.stepped(1, zoomIn: true) == 1.5)
        #expect(ViewerZoom.stepped(1.5, zoomIn: false) == 1)
        #expect(ViewerZoom.stepped(1.2, zoomIn: false) == 1)
        #expect(ViewerZoom.stepped(1, zoomIn: false) == 1)
        #expect(ViewerZoom.stepped(7, zoomIn: true) == ViewerZoom.maximumScale)
        #expect(ViewerZoom.stepped(ViewerZoom.maximumScale, zoomIn: true) == ViewerZoom.maximumScale)
    }

    @Test func commandsFromTheMenuBar() {
        #expect(ViewerZoomCommand(id: 1, kind: .zoomIn).target(from: 2) == 3)
        #expect(ViewerZoomCommand(id: 2, kind: .zoomOut).target(from: 3) == 2)
        #expect(ViewerZoomCommand(id: 3, kind: .fit).target(from: 6) == 1)
        // The same request twice in a row is two requests.
        #expect(ViewerZoomCommand(id: 1, kind: .zoomIn) != ViewerZoomCommand(id: 2, kind: .zoomIn))
    }

    @Test func doubleTapZoomsInAndBackOut() {
        #expect(ViewerZoom.doubleTapTarget(from: 1) == ViewerZoom.doubleTapScale)
        #expect(ViewerZoom.doubleTapTarget(from: 2.5) == 1)
        #expect(ViewerZoom.doubleTapTarget(from: 6) == 1)
    }

    @Test func doubleTapZoomsToThePointThatWasTapped() {
        // A photo that fills the page; tapped left of and above the middle.
        let rect = ViewerZoom.zoomRect(scale: 2, around: CGPoint(x: 150, y: 300), content: page, bounds: page)
        #expect(rect.size == CGSize(width: 200, height: 400))
        // The tapped point is in the middle of what is shown.
        #expect(rect.midX == 150)
        #expect(rect.midY == 300)
    }

    @Test func zoomingToACornerStopsAtThePhotosEdges() {
        let topLeft = ViewerZoom.zoomRect(scale: 2, around: CGPoint(x: 10, y: 20), content: page, bounds: page)
        #expect(topLeft.origin == .zero)
        let bottomRight = ViewerZoom.zoomRect(scale: 2, around: CGPoint(x: 395, y: 790), content: page, bounds: page)
        #expect(bottomRight.maxX == 400)
        #expect(bottomRight.maxY == 800)
    }

    @Test func zoomedLandscapePhotoStaysCentredWhereItIsSmallerThanThePage() {
        // 400 × 300 on a 400 × 800 page at 2×: 800 × 600 — wider than the page, still less high.
        let content = CGSize(width: 400, height: 300)
        let rect = ViewerZoom.zoomRect(scale: 2, around: CGPoint(x: 300, y: 10), content: content, bounds: page)
        #expect(rect.size == CGSize(width: 200, height: 400))
        #expect(rect.minX == 200)
        // Centred vertically: the visible area reaches equally far above and below the photo.
        #expect(rect.midY == 150)
    }

    @Test func zoomedPhotoCannotBeDraggedOffScreen() {
        let content = CGSize(width: 1000, height: 600)
        let bounds = CGSize(width: 400, height: 800)
        #expect(ViewerZoom.clampedOffset(CGPoint(x: -250, y: 0), content: content, bounds: bounds).x == 0)
        #expect(ViewerZoom.clampedOffset(CGPoint(x: 5000, y: 0), content: content, bounds: bounds).x == 600)
        #expect(ViewerZoom.clampedOffset(CGPoint(x: 320, y: 0), content: content, bounds: bounds).x == 320)
        // Not as high as the page: no vertical movement at all, it stays in the middle.
        #expect(ViewerZoom.clampedOffset(CGPoint(x: 0, y: 400), content: content, bounds: bounds).y == -100)
        #expect(ViewerZoom.clampedOffset(CGPoint(x: 0, y: -400), content: content, bounds: bounds).y == -100)
    }

    @Test func fittedPhotoSitsInTheMiddleOfThePage() {
        #expect(ViewerZoom.centeredOrigin(content: CGSize(width: 400, height: 300), bounds: page) == CGPoint(x: 0, y: 250))
        #expect(ViewerZoom.centeredOrigin(content: CGSize(width: 1000, height: 2000), bounds: page) == .zero)
    }
}

/// Swipe down to close, swipe up for info (SPEC VW-1, §7.4).
@Suite struct ViewerSwipeTests {
    @Test func onlyDragsThatStartUpOrDownAreSwipes() {
        #expect(ViewerSwipe.isVertical(velocity: CGPoint(x: 20, y: 300)))
        #expect(ViewerSwipe.isVertical(velocity: CGPoint(x: -20, y: -300)))
        // Sideways: the pager's.
        #expect(!ViewerSwipe.isVertical(velocity: CGPoint(x: 300, y: 40)))
        #expect(!ViewerSwipe.isVertical(velocity: CGPoint(x: 100, y: 100)))
    }

    @Test func longOrFastSwipeDownCloses() {
        #expect(ViewerSwipe.outcome(translation: 200, velocity: 0) == .dismiss)
        #expect(ViewerSwipe.outcome(translation: 30, velocity: 1500) == .dismiss)
        #expect(ViewerSwipe.outcome(translation: 60, velocity: 100) == .none)
    }

    @Test func aSwipeDownThatBeganOnTheInfoCardClosesOnlyTheCard() {
        // The card closed itself on the same swipe (an iPhone sheet): the viewer stays.
        #expect(!ViewerSwipe.closesViewer(infoShownAtStart: true, infoShown: false))
        #expect(!ViewerSwipe.closesViewer(infoShownAtStart: true, infoShown: true))
        #expect(!ViewerSwipe.closesViewer(infoShownAtStart: false, infoShown: true))
        #expect(ViewerSwipe.closesViewer(infoShownAtStart: false, infoShown: false))
    }

    @Test func swipeUpShowsInfo() {
        #expect(ViewerSwipe.outcome(translation: -200, velocity: 0) == .showInfo)
        #expect(ViewerSwipe.outcome(translation: -30, velocity: -1500) == .showInfo)
        #expect(ViewerSwipe.outcome(translation: -60, velocity: -100) == .none)
    }

    @Test func aFlickBackDoesNotCountForTheOtherDirection() {
        // Dragged down a little, then flicked up: the finger is still below where it started.
        #expect(ViewerSwipe.outcome(translation: 40, velocity: -2000) == .none)
        #expect(ViewerSwipe.outcome(translation: -40, velocity: 2000) == .none)
    }

    @Test func backdropFadesAndPageShrinksWhileDraggedDown() {
        #expect(ViewerSwipe.dismissProgress(translation: 0, height: 800) == 0)
        #expect(ViewerSwipe.dismissProgress(translation: -100, height: 800) == 0)
        #expect(ViewerSwipe.dismissProgress(translation: 240, height: 800) == 0.5)
        #expect(ViewerSwipe.dismissProgress(translation: 2000, height: 800) == 1)
        #expect(ViewerSwipe.dismissProgress(translation: 100, height: 0) == 0)
        #expect(ViewerSwipe.pageScale(progress: 0) == 1)
        #expect(ViewerSwipe.pageScale(progress: 1) == 0.7)
    }
}
