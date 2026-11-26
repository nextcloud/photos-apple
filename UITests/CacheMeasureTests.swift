// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import XCTest

#if os(iOS)
    /// Cache measurements on the iPhone (SPEC §18.1.4): each test is one phase in a fresh process, so the counters of
    /// Settings › Server › Cache performance start at zero while the caches on disk carry over from the phases before.
    /// Run them in order on a fresh install: grid, covers, viewer. Each phase ends on the Cache performance screen, which
    /// writes the numbers to `Library/Caches/cache-metrics.json` in the app's container (copied out by the script that
    /// runs the phases). Needs `PHOTOS_UITEST_LOGIN`; nothing on the server is changed.
    @MainActor
    final class CacheMeasureTests: XCTestCase {
        var app: XCUIApplication!

        override func setUp() async throws {
            continueAfterFailure = true
            let environment = ProcessInfo.processInfo.environment
            guard let login = environment["PHOTOS_UITEST_LOGIN"], !login.isEmpty else {
                throw XCTSkip("Set PHOTOS_UITEST_LOGIN to a login link of a test server to run the UI tests.")
            }
            try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone, "Measured on the iPhone.")
            app = XCUIApplication()
            app.launchEnvironment["PHOTOS_DEBUG_LOGIN"] = login
            app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-libraryZoomLevel", "all"]
            if name.contains("NoSmartOffline") {
                // Only the viewer and the caches: smart offline would serve most pages from its own previews.
                app.launchArguments += ["-smartOfflineBudget", "off"]
            }
            app.launch()
        }

        override func tearDown() async throws {
            app?.terminate()
            app = nil
        }

        var prefix: String { ProcessInfo.processInfo.environment["PHOTOS_UITEST_SHOT_PREFIX"] ?? "" }

        func shot(_ name: String) {
            let screenshot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = prefix + name
            attachment.lifetime = .keepAlways
            add(attachment)
            if let folder = ProcessInfo.processInfo.environment["PHOTOS_UITEST_SHOTS"], !folder.isEmpty {
                try? FileManager.default.createDirectory(at: URL(fileURLWithPath: folder), withIntermediateDirectories: true)
                try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(prefix)\(name).png"))
            }
        }

        func pause(_ seconds: TimeInterval) {
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        }

        func tab(_ name: String) {
            let button = app.tabBars.buttons[name].firstMatch
            if !button.waitForExistence(timeout: 3) || !button.isHittable { expandTabBar() }
            if button.waitForExistence(timeout: 10) {
                button.tap()
            } else {
                app.buttons[name].firstMatch.tap()
            }
        }

        func waitForTimeline() {
            // The first sync of a fresh install can take a while on a busy Mac.
            XCTAssertTrue(app.collectionViews.cells.firstMatch.waitForExistence(timeout: 240), "No photos in the timeline")
        }

        /// Opens Settings › Server › Cache performance (or stays there).
        func openMetrics() {
            // Settings is a sheet from the account button (SPEC §19.2).
            if !app.buttons["settings-done"].firstMatch.exists { app.openSettings() }
            pause(1.5)
            if app.navigationBars["Cache performance"].exists { return }
            let link = app.buttons["Cache performance"].firstMatch
            for _ in 0..<12 where !link.isHittable {
                app.swipeUp()
                pause(0.5)
            }
            XCTAssertTrue(link.exists, "No Cache performance link in Settings")
            link.tap()
            pause(1.5)
        }

        /// Counts from zero from here: what loading the first screen did is not part of the phase.
        func resetMetrics() {
            openMetrics()
            let reset = app.buttons["Reset counters"].firstMatch
            for _ in 0..<6 where !reset.isHittable {
                app.swipeUp()
                pause(0.5)
            }
            reset.tap()
            pause(0.5)
            closeSettings()
            expandTabBar()
        }

        /// Scrolling down minimises the tab bar (its buttons are gone then); back at the top it comes back.
        func expandTabBar() {
            for _ in 0..<4 { app.swipeDown(velocity: .fast) }
            pause(1)
        }

        /// Closes the Settings sheet, back to the tabs.
        func closeSettings() {
            let done = app.buttons["settings-done"].firstMatch
            if done.exists { done.tap() }
            pause(1)
        }

        /// Shows the numbers of this phase and writes them out. (No swipes down: in the sheet they would close it.)
        func showMetrics(_ name: String) {
            openMetrics()
            pause(2.5)
            shot("\(name)-metrics")
            app.swipeUp()
            pause(1)
            shot("\(name)-metrics-2")
            app.swipeUp()
            pause(2.5)
            shot("\(name)-metrics-3")
        }

        /// Phase 1: the timeline loads its tiles (and the screens below the first).
        func test1Grid() {
            waitForTimeline()
            pause(6)
            shot("grid")
            // Slow swipes: fast ones can hit a SwiftUI trap in the Library's scroll target (STATUS §M8, seen before).
            let grid = app.collectionViews.firstMatch
            grid.swipeUp(velocity: .slow)
            pause(4)
            grid.swipeUp(velocity: .slow)
            pause(4)
            grid.swipeDown(velocity: .slow)
            grid.swipeDown(velocity: .slow)
            pause(2)
            showMetrics("1-grid")
        }

        /// Phase 2: covers (albums, memories, places, people) of photos the grid has loaded already.
        func test2Covers() {
            waitForTimeline()
            pause(5)
            resetMetrics()
            tab("Collections")
            pause(2)
            for screen in ["Memories", "Albums", "Places"] { visit(screen) }
            showMetrics("2-covers")
        }

        /// Opens a screen of Collections, lets its covers load, scrolls once and goes back.
        func visit(_ screen: String) {
            let row = app.buttons[screen].firstMatch
            for _ in 0..<4 where !row.isHittable {
                app.swipeUp(velocity: .slow)
                pause(0.5)
            }
            guard row.exists else { return XCTFail("No \(screen) in Collections") }
            row.tap()
            pause(6)
            shot("covers-\(screen.lowercased())")
            app.swipeUp(velocity: .slow)
            pause(4)
            app.navigationBars.buttons.firstMatch.tap()
            pause(1.5)
            expandTabBar()
        }

        /// Phase 3: the viewer, paging through ten photos at a calm pace.
        func test3Viewer() {
            waitForTimeline()
            pause(5)
            resetMetrics()
            tab("Library")
            pause(1.5)
            app.collectionViews.cells.element(boundBy: 7).tap()
            XCTAssertTrue(app.buttons["Close"].firstMatch.waitForExistence(timeout: 10), "The viewer did not open")
            pause(2)
            shot("viewer-first")
            for step in 1...10 {
                app.swipeLeft()
                pause(1.5)
                if step == 5 { shot("viewer-5") }
            }
            app.buttons["Close"].firstMatch.tap()
            pause(2)
            showMetrics("3-viewer")
        }

        /// Phase 4, on a fresh install of its own: the viewer without smart offline, paging ten times at one photo every
        /// `PHOTOS_UITEST_PACE` seconds (default 2), so that the neighbours (SPEC §18.1.2) have to come from the server.
        func test4ViewerNoSmartOffline() {
            waitForTimeline()
            pause(8)
            resetMetrics()
            tab("Library")
            pause(1.5)
            app.collectionViews.cells.element(boundBy: 2).tap()
            XCTAssertTrue(app.buttons["Close"].firstMatch.waitForExistence(timeout: 10), "The viewer did not open")
            pause(2)
            let pace: TimeInterval = ProcessInfo.processInfo.environment["PHOTOS_UITEST_PACE"].flatMap(TimeInterval.init) ?? 2
            for _ in 1...10 {
                app.swipeLeft()
                pause(pace)
            }
            pause(1)
            app.buttons["Close"].firstMatch.tap()
            pause(2)
            showMetrics("4-viewer-no-smart-offline")
        }
    }
#endif
