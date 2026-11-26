// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosMedia

@Suite struct LaunchMetricsTests {
    @Test func reportsTheFirstPictureAndTheFirstScreenOnce() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let metrics = LaunchMetrics(processStart: start)
        let first = try #require(metrics.tileShown(now: start.addingTimeInterval(0.4)))
        #expect(first.milestone == .firstPicture)
        #expect(abs(first.milliseconds - 400) < 0.001)
        for tile in 2..<LaunchMetrics.firstScreenTiles {
            #expect(metrics.tileShown(now: start.addingTimeInterval(0.5)) == nil, "tile \(tile)")
        }
        let screen = try #require(metrics.tileShown(now: start.addingTimeInterval(0.9)))
        #expect(screen.milestone == .firstScreen)
        #expect(abs(screen.milliseconds - 900) < 0.001)
        // Later tiles (scrolling, other screens) are not launch milestones.
        for _ in 0..<100 { #expect(metrics.tileShown(now: start.addingTimeInterval(5)) == nil) }
        let milestones = metrics.milestones
        #expect(milestones.firstPicture.map { abs($0 - 400) < 0.001 } == true)
        #expect(milestones.firstScreen.map { abs($0 - 900) < 0.001 } == true)
    }

    @Test func eachStepOnTheWayIsReportedOnce() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let metrics = LaunchMetrics(processStart: start)
        let appCode = try #require(metrics.reached(.appCode, now: start.addingTimeInterval(0.12)))
        #expect(abs(appCode - 120) < 0.001)
        #expect(metrics.reached(.appCode, now: start.addingTimeInterval(3)) == nil, "once per process")
        #expect(metrics.reached(.mainView, now: start.addingTimeInterval(0.4)) != nil)
        #expect(metrics.reached(.libraryData, now: start.addingTimeInterval(0.41)) != nil)
        #expect(metrics.steps.keys.sorted { $0.rawValue < $1.rawValue } == [.appCode, .libraryData, .mainView])
        #expect(metrics.steps[.appModel] == nil)
        // The steps do not count as tiles.
        #expect(metrics.milestones.firstPicture == nil)
        #expect(LaunchMetrics(processStart: nil).reached(.appCode) == nil)
    }

    @Test func withoutAProcessStartNothingIsReported() {
        let metrics = LaunchMetrics(processStart: nil)
        #expect(metrics.tileShown() == nil)
        #expect(metrics.milestones.firstPicture == nil)
    }

    @Test func theProcessStartIsReadFromTheKernel() throws {
        let start = try #require(LaunchMetrics.processStartDate())
        // This test process started before now, and not days ago.
        #expect(start <= Date())
        #expect(Date().timeIntervalSince(start) < 24 * 3600)
    }
}

@Suite struct FramePacingTests {
    @Test func smoothFramesHaveNoHitches() {
        var pacing = FramePacing()
        for _ in 0..<120 { pacing.frame(interval: 1.0 / 120, nominal: 1.0 / 120) }
        #expect(pacing.frames == 120)
        #expect(abs(pacing.seconds - 1) < 1e-9)
        #expect(pacing.hitches == 0)
        #expect(pacing.hitchTimeRatio == 0)
        #expect(abs(pacing.framesPerSecond - 120) < 1e-6)
    }

    @Test func aLateFrameCountsTheTimeBeyondOneInterval() {
        var pacing = FramePacing()
        let nominal = 1.0 / 60
        for _ in 0..<58 { pacing.frame(interval: nominal, nominal: nominal) }
        // One frame took three intervals: two intervals of hitch time.
        pacing.frame(interval: nominal * 3, nominal: nominal)
        // A little jitter is not a hitch.
        pacing.frame(interval: nominal * 1.2, nominal: nominal)
        #expect(pacing.hitches == 1)
        #expect(abs(pacing.hitchMilliseconds - 2000.0 / 60) < 1e-6)
        #expect(abs(pacing.longestFrameMilliseconds - 50) < 1e-6)
        #expect(abs(pacing.nominalMilliseconds - 1000.0 / 60) < 1e-6)
        #expect(pacing.hitchTimeRatio > 30 && pacing.hitchTimeRatio < 35)
    }

    @Test func emptyOrInvalidIntervalsAreIgnored() {
        var pacing = FramePacing()
        pacing.frame(interval: 0, nominal: 1.0 / 60)
        pacing.frame(interval: 0.01, nominal: 0)
        #expect(pacing.frames == 0)
        #expect(pacing.hitchTimeRatio == 0)
        #expect(pacing.framesPerSecond == 0)
    }
}
