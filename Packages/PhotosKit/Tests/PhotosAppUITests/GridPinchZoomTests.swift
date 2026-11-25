// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosAppUI

/// The Mac grid's continuous trackpad zoom and hover lift (SPEC §17.7): the maths, without a trackpad.
@Suite struct GridPinchZoomTests {
    let sides = GridPinchZoom.Sides(current: 100, larger: 150, smaller: 80)

    @Test func betweenTwoStepsTheGridScalesTowardsTheNextStepsTileSize() {
        var pinch = GridPinchZoom()
        pinch.begin(at: 0)
        #expect(pinch.update(magnification: 0, sides: sides) == .scale(1))
        guard case .scale(let half) = pinch.update(magnification: GridPinchZoom.stepDistance / 2, sides: sides) else {
            Issue.record("expected a scale")
            return
        }
        // Geometric: half way in scale, so zooming in and out feel even.
        #expect(abs(half - (1.5).squareRoot()) < 1e-9)
        guard case .scale(let almost) = pinch.update(magnification: GridPinchZoom.stepDistance * 0.99, sides: sides) else {
            Issue.record("expected a scale")
            return
        }
        // Just before the step the tiles are nearly as large as the next step's: the switch does not jump.
        #expect(abs(almost - 1.5) < 0.01)
    }

    @Test func zoomingOutShrinksTowardsTheSmallerStep() {
        var pinch = GridPinchZoom()
        pinch.begin(at: 0.3)
        guard case .scale(let scale) = pinch.update(magnification: 0.3 - GridPinchZoom.stepDistance / 2, sides: sides) else {
            Issue.record("expected a scale")
            return
        }
        #expect(scale < 1 && scale > 0.8)
        #expect(abs(scale - (0.8).squareRoot()) < 1e-9)
    }

    @Test func aFullStepSwitchesTheLayoutAndTheNextStepStartsUnscaled() {
        var pinch = GridPinchZoom()
        pinch.begin(at: 0)
        #expect(pinch.update(magnification: 0.23, sides: sides) == .step(zoomIn: true))
        // The new step is measured from where the last one was reached.
        #expect(pinch.origin == 0.23)
        #expect(pinch.update(magnification: 0.23, sides: sides) == .scale(1))
        // A long pinch goes through several steps.
        #expect(pinch.update(magnification: 0.46, sides: sides) == .step(zoomIn: true))
        #expect(pinch.update(magnification: 0.2, sides: sides) == .step(zoomIn: false))
    }

    @Test func pastTheLastStepTheGridOnlyStretchesALittle() {
        var pinch = GridPinchZoom()
        let largest = GridPinchZoom.Sides(current: 300, larger: nil, smaller: 200)
        pinch.begin(at: 0)
        guard case .scale(let stretched) = pinch.update(magnification: 1, sides: largest) else {
            Issue.record("expected a stretch, not a step")
            return
        }
        #expect(stretched > 1 && stretched <= 1 + GridPinchZoom.rubberBand)
        // Released there, it springs back.
        #expect(pinch.end(magnification: 1, sides: largest) == nil)
    }

    @Test func outOfTheDensestStepTheLibrarysDaysTakeOver() {
        var pinch = GridPinchZoom()
        let densest = GridPinchZoom.Sides(current: 40, larger: 60, smaller: nil)
        pinch.begin(at: 0)
        // Without anything to take over, only a stretch.
        guard case .scale(let shrunk) = pinch.update(magnification: -0.3, sides: densest) else {
            Issue.record("expected a stretch")
            return
        }
        #expect(shrunk < 1 && shrunk >= 1 - GridPinchZoom.rubberBand)
        pinch.begin(at: 0)
        #expect(pinch.update(magnification: -0.1, sides: densest, pastEnd: true) != .step(zoomIn: false))
        #expect(pinch.update(magnification: -0.3, sides: densest, pastEnd: true) == .step(zoomIn: false))
    }

    @Test func aReleasedPinchSnapsToTheNearerStep() {
        var pinch = GridPinchZoom()
        pinch.begin(at: 0)
        #expect(pinch.end(magnification: 0.12, sides: sides) == true)
        #expect(pinch.end(magnification: 0.05, sides: sides) == nil)
        #expect(pinch.end(magnification: -0.12, sides: sides) == false)
    }

    @Test func theStretchSlowsDownTowardsItsEnd() {
        let first = GridPinchZoom.stretch(progress: 0.5, zoomIn: true) - 1
        let second = GridPinchZoom.stretch(progress: 1, zoomIn: true) - GridPinchZoom.stretch(progress: 0.5, zoomIn: true)
        #expect(first > second)
        #expect(GridPinchZoom.stretch(progress: 0, zoomIn: false) == 1)
    }

    @Test func aLiftedTileGrowsByAFewPointsWhateverItsSize() {
        // A large tile grows by the same few points…
        #expect(abs(GridLiftMetrics.scale(side: 400, reduceMotion: false) - 1.02) < 1e-9)
        #expect(abs(GridLiftMetrics.scale(side: 200, reduceMotion: false) - 1.04) < 1e-9)
        // …a small one by no more than 5 %, so it does not jump.
        #expect(GridLiftMetrics.scale(side: 40, reduceMotion: false) == 1.05)
        // Reduce Motion: no growth, the shadow alone shows the lift.
        #expect(GridLiftMetrics.scale(side: 200, reduceMotion: true) == 1)
        #expect(GridLiftMetrics.scale(side: 0, reduceMotion: false) == 1)
    }
}
