// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import SwiftUI
import Testing

@testable import PhotosAppUI

/// The photo wall behind the login and the welcome into the Library (SPEC §17.6.2, §17.6.3).

@Suite struct WelcomeWallTests {
    @Test func tilesVaryAndNeighboursNeverRepeatAScene() {
        for column in 0..<12 {
            let tiles = WelcomeWall.tiles(column: column)
            #expect(tiles.count == WelcomeWall.tilesPerColumn)
            for (above, below) in zip(tiles, tiles.dropFirst()) {
                #expect(above.scene != below.scene)
            }
            // The column wraps: the last tile is followed by the first.
            #expect(tiles.last?.scene != tiles.first?.scene)
            #expect(Set(tiles.map(\.aspect)).count > 1)
            #expect(tiles.allSatisfy { WelcomeWall.scenes.indices.contains($0.scene) })
        }
        // Side by side, columns don't start alike.
        #expect(WelcomeWall.tiles(column: 0).first != WelcomeWall.tiles(column: 1).first)
        // The same on every launch.
        #expect(WelcomeWall.tiles(column: 3) == WelcomeWall.tiles(column: 3))
    }

    @Test func columnsCoverTheWallAtEveryShift() {
        let wall = 1300.0
        let count = WelcomeWall.columns(width: wall)
        #expect(count >= 4)
        let columnWidth = (wall - WelcomeWall.spacing * Double(count - 1)) / Double(count)
        for column in 0..<count {
            let loop = WelcomeWall.loopHeight(column: column, columnWidth: columnWidth)
            let rounds = WelcomeWall.rounds(loop: loop, wallHeight: wall)
            for elapsed in stride(from: 0.0, through: 600, by: 7.1) {
                let shift = WelcomeWall.shift(column: column, elapsed: elapsed, loop: loop)
                #expect(shift <= 0 && shift >= -loop)
                // From the shift down, the drawn rounds reach past the bottom of the wall.
                #expect(shift + loop * Double(rounds) >= wall)
            }
        }
    }

    @Test func neighbouringColumnsDriftOppositeWaysAndWrapSmoothly() {
        let loop = 1000.0
        let even0 = WelcomeWall.shift(column: 0, elapsed: 1, loop: loop)
        let even1 = WelcomeWall.shift(column: 0, elapsed: 2, loop: loop)
        let odd0 = WelcomeWall.shift(column: 1, elapsed: 1, loop: loop)
        let odd1 = WelcomeWall.shift(column: 1, elapsed: 2, loop: loop)
        #expect(even1 < even0)  // up
        #expect(odd1 > odd0)  // down
        // Slowly: a few points a second.
        #expect(abs(even1 - even0) < 12 && abs(odd1 - odd0) < 12)
        #expect(WelcomeWall.shift(column: 0, elapsed: 5, loop: 0) == 0)
    }

    @Test func welcomeIsShortAndOnlyFadesWithReduceMotion() {
        let motion = WelcomeTiming(reduceMotion: false)
        let still = WelcomeTiming(reduceMotion: true)
        #expect(motion.total <= 1.2)
        #expect(still.total <= 1.2)
        #expect(still.iconEndScale == 1)
        #expect(motion.iconEndScale > 1)
        #expect(still.revealStartScale == 1)
        #expect(motion.revealDuration <= 0.4)
    }

    @Test func greetingUsesTheNameWhenThereIsOne() {
        #expect(FirstLaunchWelcome.greeting(name: "Anna") == "Welcome, Anna")
        #expect(FirstLaunchWelcome.greeting(name: "") == "Welcome")
    }
}

@Suite struct WelcomeHoldTests {
    @Test func aBusyMomentStartsTheHoldAgain() {
        var calm = 0.0
        calm = WelcomeTiming.calmTime(after: calm, step: 0.05, took: 0.05)
        calm = WelcomeTiming.calmTime(after: calm, step: 0.05, took: 0.06)
        #expect(abs(calm - 0.11) < 0.0001)
        // The main thread was busy for a second: nothing was seen meanwhile.
        #expect(WelcomeTiming.calmTime(after: calm, step: 0.05, took: 1) == 0)
    }

    @Test func theHoldEndsAndNeverWaitsLongerThanItsLimit() async {
        let clock = ContinuousClock()
        let start = clock.now
        await WelcomeTiming.holdCalmly(0.2, limit: 1)
        let took = clock.now - start
        #expect(took >= .milliseconds(200))
        #expect(took < .seconds(2))
    }
}
