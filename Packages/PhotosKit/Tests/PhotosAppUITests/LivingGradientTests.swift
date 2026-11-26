// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import SwiftUI
import Testing

@testable import PhotosAppUI

/// Living gradients (SPEC §17.6.1).
@Suite struct LivingGradientTests {
    @Test func meshCornersStayAndEdgePointsSlideAlongTheirEdge() {
        for time in stride(from: 0.0, through: 60, by: 0.37) {
            let points = LivingMesh.points(at: time)
            #expect(points.count == LivingMesh.width * LivingMesh.height)
            #expect(points[0] == SIMD2(0, 0))
            #expect(points[2] == SIMD2(1, 0))
            #expect(points[6] == SIMD2(0, 1))
            #expect(points[8] == SIMD2(1, 1))
            // Top and bottom edge points keep their y, left and right ones their x: the mesh always fills the rectangle.
            #expect(points[1].y == 0)
            #expect(points[7].y == 1)
            #expect(points[3].x == 0)
            #expect(points[5].x == 1)
            for point in points {
                #expect(point.x >= 0 && point.x <= 1 && point.y >= 0 && point.y <= 1)
            }
            // The free coordinates stay near the middle.
            for value in [points[1].x, points[7].x, points[3].y, points[5].y, points[4].x, points[4].y] {
                #expect(abs(value - 0.5) <= LivingMesh.amplitude + 0.0001)
            }
        }
    }

    @Test func meshDriftLoopsWithoutASeamAndMovesSlowly() {
        for time in [0.0, 3.3, 11, 17.9] {
            let now = LivingMesh.points(at: time)
            let oneCycleLater = LivingMesh.points(at: time + LivingMesh.period)
            for (a, b) in zip(now, oneCycleLater) {
                #expect(abs(a.x - b.x) < 0.0001 && abs(a.y - b.y) < 0.0001)
            }
            // One frame at 30 Hz moves a point by a tiny fraction of the size: calm, never a jump.
            let nextFrame = LivingMesh.points(at: time + LivingMotion.frameInterval)
            for (a, b) in zip(now, nextFrame) {
                #expect(abs(a.x - b.x) < 0.003 && abs(a.y - b.y) < 0.003)
            }
        }
        // It does move.
        #expect(LivingMesh.points(at: 0) != LivingMesh.points(at: LivingMesh.period / 4))
    }

    @Test func clockPausesWhereItIsAndGoesOnFromThere() {
        let start = Date(timeIntervalSince1970: 1_000)
        var clock = LivingClock()
        #expect(clock.elapsed(at: start) == 0)
        clock.run(at: start)
        #expect(clock.isRunning)
        #expect(clock.elapsed(at: start.addingTimeInterval(5)) == 5)
        clock.pause(at: start.addingTimeInterval(5))
        #expect(!clock.isRunning)
        // Paused for a minute: still at 5 seconds, and it goes on from 5, not from 65.
        #expect(clock.elapsed(at: start.addingTimeInterval(65)) == 5)
        clock.run(at: start.addingTimeInterval(65))
        #expect(clock.elapsed(at: start.addingTimeInterval(67)) == 7)
        // Running or pausing twice changes nothing.
        clock.run(at: start.addingTimeInterval(100))
        #expect(clock.elapsed(at: start.addingTimeInterval(100)) == 40)
        clock.pause(at: start.addingTimeInterval(100))
        clock.pause(at: start.addingTimeInterval(200))
        #expect(clock.elapsed(at: start.addingTimeInterval(300)) == 40)
    }

    @Test func gradientsMoveOnlyWhenShownActiveAndWithoutReduceMotion() {
        #expect(LivingMotion.moves(isActive: true, isOnScreen: true, reduceMotion: false, scenePhase: .active))
        #expect(!LivingMotion.moves(isActive: true, isOnScreen: true, reduceMotion: true, scenePhase: .active))
        #expect(!LivingMotion.moves(isActive: true, isOnScreen: false, reduceMotion: false, scenePhase: .active))
        #expect(!LivingMotion.moves(isActive: false, isOnScreen: true, reduceMotion: false, scenePhase: .active))
        #expect(!LivingMotion.moves(isActive: true, isOnScreen: true, reduceMotion: false, scenePhase: .inactive))
        #expect(!LivingMotion.moves(isActive: true, isOnScreen: true, reduceMotion: false, scenePhase: .background))
    }

    /// Text on the gradients stays readable: the system's primary text colour on the wash (black in light mode, white in
    /// dark mode) and white on the hero, at least WCAG AA (4.5:1) everywhere, AAA (7:1) for the wash.
    @Test func textOnEveryGradientColourIsReadable() {
        for increased in [false, true] {
            for color in LivingPalette.rgb(.wash, dark: false, increasedContrast: increased) {
                #expect(color.contrast(with: .black) >= 7)
            }
            for color in LivingPalette.rgb(.wash, dark: true, increasedContrast: increased) {
                #expect(color.contrast(with: .white) >= 7)
            }
            for dark in [false, true] {
                for color in LivingPalette.rgb(.hero, dark: dark, increasedContrast: increased) {
                    #expect(color.contrast(with: .white) >= (increased ? 7 : 4.5))
                }
            }
        }
        #expect(LivingPalette.rgb(.wash, dark: false, increasedContrast: false).count == 9)
        #expect(LivingPalette.rgb(.hero, dark: false, increasedContrast: false).count == 9)
    }

    @Test func increaseContrastMakesTheWashNearlyPlain() {
        func spread(_ colors: [LivingRGB]) -> Double {
            let values = colors.map(\.luminance)
            return (values.max() ?? 0) - (values.min() ?? 0)
        }
        for dark in [false, true] {
            let normal = LivingPalette.rgb(.wash, dark: dark, increasedContrast: false)
            let increased = LivingPalette.rgb(.wash, dark: dark, increasedContrast: true)
            #expect(spread(increased) < spread(normal))
            #expect(spread(increased) < 0.05)
        }
    }

    @Test func contrastRatioMatchesWCAG() {
        #expect(abs(LivingRGB.white.contrast(with: .black) - 21) < 0.001)
        #expect(LivingRGB(0.5, 0.5, 0.5).contrast(with: LivingRGB(0.5, 0.5, 0.5)) == 1)
        // Nextcloud blue on white: about 4.2, too little for body text, which is why the hero blues are darker.
        #expect(abs(LivingRGB(0, 130 / 255, 201 / 255).contrast(with: .white) - 4.17) < 0.05)
    }

    @Test func yearCardBlendStaysBetweenItsTwoColours() {
        let fractions = LivingPalette.blendFractions
        #expect(fractions.count == 9)
        #expect(fractions.allSatisfy { $0 >= 0 && $0 <= 1 })
        // Diagonal like the flat gradient it replaces: the first colour at the top leading corner, the second at the
        // bottom trailing one.
        #expect(fractions.first == 0 && fractions.last == 1)
        #expect(LivingPalette.blend(.red, .blue).colors(dark: true, increasedContrast: false).count == 9)
    }

    @MainActor @Test func otherCardDotsAreBrighterWithIncreaseContrast() {
        #expect(YearInReviewScreen.otherDotOpacity(increasedContrast: true) > YearInReviewScreen.otherDotOpacity(increasedContrast: false))
        // 60 % white on black: well over the 3:1 a non-text element needs (35 % was right at the limit).
        let gray = 0.6
        #expect(LivingRGB(gray, gray, gray).contrast(with: .black) >= 3)
    }
}
