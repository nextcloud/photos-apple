// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import XCTest

#if os(iOS)
    /// XCTest metrics for the budgets of SPEC §10 (SPEC §20.6): launch, scrolling the Library, paging in the viewer, and
    /// memory while doing so. In the simulator the numbers are indicative only (the Mac's CPU and GPU, no 120 Hz
    /// display); the budgets are for devices. `scripts/measure-performance.sh` runs them, collects the log lines of
    /// `LaunchMetrics` (launch → first pictures) and the cache metrics, and prints a table.
    ///
    /// Needs `PHOTOS_UITEST_LOGIN`; nothing on the server is changed. Run `test0Prepare` first on a fresh install: it
    /// signs in, lets the first sync finish and fills the caches, so that the other tests measure a cached library.
    @MainActor
    final class PerformanceTests: XCTestCase {
        var app: XCUIApplication!

        override func setUp() async throws {
            continueAfterFailure = true
            let environment = ProcessInfo.processInfo.environment
            guard let login = environment["PHOTOS_UITEST_LOGIN"], !login.isEmpty else {
                throw XCTSkip("Set PHOTOS_UITEST_LOGIN to a login link of a test server to run the UI tests.")
            }
            let runner = Bundle.main.bundleIdentifier ?? ""
            try XCTSkipIf(
                runner.hasPrefix(SmokeTests.officialBundleId + ".uitests"),
                "Build the UI tests with a bundle id of your own (PHOTOS_BUNDLE_ID), not \(SmokeTests.officialBundleId).")
            app = XCUIApplication()
            app.launchEnvironment["PHOTOS_DEBUG_LOGIN"] = login
            // The strip instead of playing story cards: XCUITest waits for an idle app before every query.
            app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-memoriesStyle", "strip"]
        }

        override func tearDown() async throws {
            app?.terminate()
            app = nil
        }

        /// Iterations of each measurement (XCTest adds one more at the start that does not count).
        var iterations: Int {
            Int(ProcessInfo.processInfo.environment["PHOTOS_UITEST_ITERATIONS"] ?? "") ?? 5
        }

        var tiles: XCUIElementQuery { app.collectionViews.cells }

        func waitForTimeline(timeout: TimeInterval = 60) {
            XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: timeout), "No photos in the timeline")
        }

        func pause(_ seconds: TimeInterval) {
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        }

        func options(manualStop: Bool = false) -> XCTMeasureOptions {
            let options = XCTMeasureOptions()
            options.iterationCount = iterations
            if manualStop { options.invocationOptions = [.manuallyStop] }
            return options
        }

        /// Sign-in, first sync, the first screens' previews in the cache; the viewer's neighbours once.
        func test0Prepare() {
            app.launch()
            // The first sync of a fresh install can take a while on a busy Mac.
            waitForTimeline(timeout: 240)
            pause(10)
            let grid = app.collectionViews.firstMatch
            for _ in 0..<4 {
                grid.swipeUp(velocity: .slow)
                pause(3)
            }
            for _ in 0..<6 { grid.swipeDown(velocity: .fast) }
            pause(2)
        }

        /// Cold launch of a signed-in app with a cached library: process start to the first frame the user can touch
        /// (`XCTApplicationLaunchMetric`). The time to the Library's first pictures comes from `LaunchMetrics` in the log.
        func test1Launch() {
            app.launch()
            waitForTimeline()
            app.terminate()
            measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: options()) {
                app.launch()
            }
        }

        /// Launch until the first tile is in the accessibility tree, as XCUITest sees it: an upper bound of "cached
        /// timeline visible", including XCUITest's own launch handshake and polling.
        func test2LaunchToTimeline() {
            app.launch()
            waitForTimeline()
            measure(metrics: [XCTClockMetric(), XCTMemoryMetric(application: app)], options: options()) {
                app.launch()
                waitForTimeline(timeout: 30)
            }
        }

        /// Fast flicks through the Library: hitches while dragging and decelerating, frame rate, and memory.
        func test3LibraryScroll() {
            app.launch()
            waitForTimeline()
            pause(5)
            let grid = app.collectionViews.firstMatch
            let metrics: [any XCTMetric] = [
                XCTOSSignpostMetric.scrollDecelerationMetric, XCTOSSignpostMetric.scrollDraggingMetric,
                XCTMemoryMetric(application: app),
                XCTOSSignpostMetric(subsystem: "com.nextcloud.photos", category: "cache", name: "Tile"),
            ]
            measure(metrics: metrics, options: options(manualStop: true)) {
                grid.swipeUp(velocity: .fast)
                grid.swipeUp(velocity: .fast)
                // Until the deceleration has ended.
                pause(2)
                stopMeasuring()
                for _ in 0..<4 { grid.swipeDown(velocity: .fast) }
                pause(2)
            }
        }

        /// Paging through the viewer: hitches of the paging scroll, the viewer's time to a picture, memory. Ends on
        /// Settings › Storage & cache › Cache performance, which writes the time-to-show samples to `Library/Caches/cache-metrics.json`.
        func test4ViewerPaging() {
            app.launch()
            waitForTimeline()
            pause(4)
            tiles.element(boundBy: 7).tap()
            XCTAssertTrue(app.buttons["Close"].firstMatch.waitForExistence(timeout: 10), "The viewer did not open")
            pause(2)
            let metrics: [any XCTMetric] = [
                XCTOSSignpostMetric.scrollDecelerationMetric, XCTMemoryMetric(application: app),
                XCTOSSignpostMetric(subsystem: "com.nextcloud.photos", category: "cache", name: "Viewer"),
            ]
            measure(metrics: metrics, options: options(manualStop: true)) {
                app.swipeLeft()
                pause(1.5)
                stopMeasuring()
            }
            app.buttons["Close"].firstMatch.tap()
            pause(2)
            openCacheMetrics()
        }

        /// Settings › Storage & cache › Cache performance (writes its numbers while it is open; SPEC §20.4 pages).
        func openCacheMetrics() {
            app.openSettings(page: "storage")
            pause(1.5)
            let link = app.buttons["Cache performance"].firstMatch
            for _ in 0..<12 where !link.isHittable {
                app.swipeUp()
                pause(0.5)
            }
            guard link.exists else { return XCTFail("No Cache performance link in Settings") }
            link.tap()
            pause(5)
        }
    }
#endif
