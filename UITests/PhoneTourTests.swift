// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import XCTest

#if os(iOS)
    /// A walk through the iPhone screens against a test server (see docs/TESTING.md, "UI smoke tests").
    ///
    /// Same requirements as `SmokeTests` (`PHOTOS_UITEST_LOGIN`, a Debug build with a bundle id of your own). Every step
    /// is attached as a screenshot; with `PHOTOS_UITEST_SHOTS=<directory>` the screenshots and the accessibility tree of
    /// each step are also written there (the simulator can write to the Mac's file system). They only look and
    /// navigate; nothing on the server changes.
    @MainActor
    final class PhoneTourTests: XCTestCase {
        static let wait: TimeInterval = 60

        var app: XCUIApplication!
        private var shotsDirectory: URL?

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
            try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone, "The tour is the iPhone's.")
            if let path = environment["PHOTOS_UITEST_SHOTS"], !path.isEmpty {
                shotsDirectory = URL(fileURLWithPath: path)
                try? FileManager.default.createDirectory(at: URL(fileURLWithPath: path), withIntermediateDirectories: true)
            }
            app = XCUIApplication()
            app.launchEnvironment["PHOTOS_DEBUG_LOGIN"] = login
            app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            app.launch()
        }

        override func tearDown() async throws {
            app?.terminate()
            app = nil
        }

        // MARK: Helpers

        private var tiles: XCUIElementQuery { app.collectionViews.cells }

        private func waitForTimeline(file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertTrue(
                tiles.firstMatch.waitForExistence(timeout: Self.wait), "No photo appeared in the timeline", file: file, line: line)
        }

        /// A screenshot of the step, attached and (with `PHOTOS_UITEST_SHOTS`) written with the accessibility tree.
        private func shot(_ name: String) {
            let screenshot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            guard let shotsDirectory else { return }
            try? screenshot.pngRepresentation.write(to: shotsDirectory.appending(path: "\(name).png"))
            try? Data(app.debugDescription.utf8).write(to: shotsDirectory.appending(path: "\(name).txt"))
        }

        private func pause(_ seconds: TimeInterval) {
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        }

        private func tab(_ name: String) {
            let button = app.tabBars.buttons[name].firstMatch
            if button.waitForExistence(timeout: 10) {
                button.tap()
            } else {
                app.buttons[name].firstMatch.tap()
            }
        }

        // MARK: Library

        /// Scrolling shows the date scrubber at the trailing edge; dragging it jumps through the years.
        func testLibraryAndDateScrubber() {
            waitForTimeline()
            pause(2)
            shot("library-top")
            let grid = app.collectionViews.firstMatch
            grid.swipeUp(velocity: .fast)
            shot("library-scrolling")
            pause(3)
            shot("library-scrolled-still")
            // The scrubber is shown while the grid scrolls; it is grabbed at the trailing edge.
            grid.swipeUp(velocity: .slow)
            let scrubber = app.otherElements["Timeline position"].firstMatch
            XCTAssertTrue(scrubber.waitForExistence(timeout: 5), "No date scrubber")
            let frame = grid.frame
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.maxX - 8, dy: frame.minY + 200))
            let end = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.maxX - 8, dy: frame.maxY - 220))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.6)
            shot("library-scrubbed-to-end")
            pause(3)
            shot("library-at-end")
        }

        func testSelectionAndContextMenu() {
            waitForTimeline()
            // Enabled once the photos are loaded (the first tiles may be the first sync's placeholders).
            let select = app.buttons["Select"].firstMatch
            let enabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: select)
            wait(for: [enabled], timeout: Self.wait)
            select.tap()
            XCTAssertTrue(app.buttons["Done"].firstMatch.waitForExistence(timeout: 10), "The selection mode did not start")
            let cells = tiles.allElementsBoundByIndex.filter { $0.isHittable }
            for cell in cells.prefix(8).dropFirst(2).prefix(3) { cell.tap() }
            shot("selection")
            // iPhone: the selection's actions replace the tab bar.
            XCTAssertFalse(app.tabBars.firstMatch.isHittable, "The tab bar covers the selection's actions")
            XCTAssertTrue(app.buttons["Delete"].firstMatch.isHittable)
            app.buttons["Done"].firstMatch.tap()
            pause(1)
            XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
            tiles.element(boundBy: 3).press(forDuration: 1.2)
            pause(1)
            shot("context-menu")
        }

        // MARK: Viewer

        func testViewer() {
            waitForTimeline()
            tiles.element(boundBy: 3).tap()
            let info = app.buttons["Info"].firstMatch
            XCTAssertTrue(info.waitForExistence(timeout: Self.wait), "The viewer did not open")
            pause(2)
            shot("viewer")
            app.swipeLeft()
            pause(1.5)
            shot("viewer-next")
            info.tap()
            pause(2)
            shot("viewer-info")
            app.swipeDown()
            pause(1)
            let more = app.buttons["More"].firstMatch
            if more.waitForExistence(timeout: 5) {
                more.tap()
                pause(1)
                shot("viewer-more")
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
                pause(1)
            }
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
                .press(forDuration: 0.05, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
            pause(1.5)
            shot("viewer-closed")
        }

        // MARK: Other tabs

        func testCollections() {
            waitForTimeline()
            tab("Collections")
            pause(3)
            shot("collections")
            app.swipeUp()
            pause(1)
            shot("collections-2")
            app.swipeUp()
            pause(1)
            shot("collections-3")
        }

        func testSettings() {
            waitForTimeline()
            app.openSettings()
            pause(2)
            shot("settings")
            for page in 2...5 {
                app.swipeUp()
                pause(1)
                shot("settings-\(page)")
            }
        }

        func testSearch() {
            waitForTimeline()
            tab("Search")
            pause(2)
            shot("search")
            let field = app.searchFields.firstMatch
            if field.waitForExistence(timeout: 5) {
                field.tap()
                field.typeText("dog")
                pause(3)
                shot("search-dog")
            }
        }

        /// Every screen a link leads to (SPEC §4.8), one after the other.
        func testDestinations() throws {
            waitForTimeline()
            let routes =
                ProcessInfo.processInfo.environment["PHOTOS_UITEST_ROUTES"]?.split(separator: ",").map(String.init)
                ?? [
                    "memories", "albums", "sharedalbums", "people", "places", "tags", "folders", "shared", "archive",
                    "recentlyDeleted", "map", "smartAlbums", "backup", "onThisDay", "duplicates", "freeSpace",
                ]
            for route in routes {
                app.open(try XCTUnwrap(URL(string: "nextcloudphotos://\(route)")))
                // The system asks before a link opens the app.
                let open = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"].firstMatch
                if open.waitForExistence(timeout: 5) { open.tap() }
                pause(4)
                shot("link-\(route)")
                // A screen the server cannot fill (People without Recognize, …) explains itself in an alert.
                let alert = app.alerts.firstMatch
                if alert.exists { alert.buttons["OK"].tap() }
            }
        }

        func testMemory() {
            waitForTimeline()
            let memories = app.scrollViews["Memories"].firstMatch
            let card: XCUIElement =
                memories.exists
                ? memories.buttons.firstMatch : app.buttons.matching(NSPredicate(format: "label CONTAINS 'ago'")).firstMatch
            guard card.waitForExistence(timeout: 10) else {
                shot("memory-missing")
                XCTFail("No memory card")
                return
            }
            card.tap()
            pause(3)
            shot("memory")
        }
    }
#endif
