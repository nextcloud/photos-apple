// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import XCTest

#if os(iOS)
    /// The screens of SPEC §20.4 on iPhone: the Collections overview with its shelves, Settings in pages with its
    /// search, and the Advanced features switch. Same requirements as `PhoneTourTests`; nothing on the server changes
    /// (the switch is on this device and turned back off).
    @MainActor
    final class ScreensTourTests: XCTestCase {
        static let wait: TimeInterval = 60

        var app: XCUIApplication!
        private var shotsDirectory: URL?

        override func setUp() async throws {
            continueAfterFailure = true
            let environment = ProcessInfo.processInfo.environment
            guard let login = environment["PHOTOS_UITEST_LOGIN"], !login.isEmpty else {
                throw XCTSkip("Set PHOTOS_UITEST_LOGIN to a login link of a test server to run the UI tests.")
            }
            try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone, "The Collections tab is the iPhone's.")
            if let path = environment["PHOTOS_UITEST_SHOTS"], !path.isEmpty {
                shotsDirectory = URL(fileURLWithPath: path)
                try? FileManager.default.createDirectory(at: URL(fileURLWithPath: path), withIntermediateDirectories: true)
            }
            app = XCUIApplication()
            app.launchEnvironment["PHOTOS_DEBUG_LOGIN"] = login
            app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        }

        override func tearDown() async throws {
            app?.terminate()
            app = nil
        }

        // MARK: Helpers

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

        private func waitForTimeline() {
            XCTAssertTrue(app.collectionViews.cells.firstMatch.waitForExistence(timeout: Self.wait), "No photo in the timeline")
        }

        private func openCollections() {
            let tab = app.tabBars.buttons["Collections"].firstMatch
            XCTAssertTrue(tab.waitForExistence(timeout: 10), "No Collections tab")
            tab.tap()
            XCTAssertTrue(app.buttons["collections-shelf-albums"].firstMatch.waitForExistence(timeout: 10), "No Albums shelf")
        }

        private func setSwitch(_ toggle: XCUIElement, on: Bool) {
            guard (toggle.value as? String == "1") != on else { return }
            let inner = toggle.switches.firstMatch
            if inner.exists { inner.tap() } else { toggle.tap() }
            pause(1)
            XCTAssertEqual(toggle.value as? String, on ? "1" : "0", "The switch did not change")
        }

        /// Scrolls the overview until `element` can be tapped.
        private func reveal(_ element: XCUIElement) {
            for _ in 0..<6 where !(element.exists && element.isHittable) {
                app.swipeUp(velocity: .slow)
                pause(0.5)
            }
        }

        // MARK: Collections

        /// The shelves, an album opened from its cover and Back to the overview, and the utilities at the end.
        func testCollectionsShelves() {
            app.launch()
            waitForTimeline()
            openCollections()
            pause(4)
            shot("screens-01-collections")
            for shelf in ["albums", "memories", "places"] {
                XCTAssertTrue(app.buttons["collections-shelf-\(shelf)"].firstMatch.exists, "No \(shelf) shelf")
            }
            // The second card of the Albums shelf (the first is Favorites), by its place: the shelf's covers scroll
            // sideways, and the accessibility frames of the ones out of view cannot be hit.
            let albums = app.scrollViews["Albums"].firstMatch
            if albums.waitForExistence(timeout: 10) {
                albums.coordinate(withNormalizedOffset: CGVector(dx: 0.63, dy: 0.5)).tap()
                pause(3)
                shot("screens-02-album-from-shelf")
                XCTAssertFalse(
                    app.buttons["collections-shelf-albums"].firstMatch.isHittable, "The album did not open from its cover")
                app.navigationBars.buttons.firstMatch.tap()
                XCTAssertTrue(
                    app.buttons["collections-shelf-albums"].firstMatch.waitForExistence(timeout: 5),
                    "Back from an album of the shelf does not return to Collections")
            }
            app.swipeUp()
            pause(2)
            shot("screens-03-collections-places")
            let cleanUp = app.buttons["Clean up"].firstMatch
            reveal(cleanUp)
            shot("screens-04-collections-utilities")
            XCTAssertTrue(cleanUp.exists, "No Clean up in the utilities")
            XCTAssertFalse(app.buttons["Stickers"].firstMatch.exists, "Stickers is listed with Advanced features off")
            cleanUp.tap()
            pause(2)
            shot("screens-05-cleanup")
        }

        /// Every card's caption of the overview in German and at the largest accessibility text size (SPEC §20.1): the
        /// Places caption sits at the top of its map, clear of the floating tab bar; Favorites shows its newest photo.
        func testCollectionsCaptionsInGermanAndLargeText() {
            let variants: [(name: String, arguments: [String])] = [
                ("de", ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]),
                ("en-ax", ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]),
                (
                    "de-ax",
                    [
                        "-AppleLanguages", "(de)", "-AppleLocale", "de_DE", "-UIPreferredContentSizeCategoryName",
                        "UICTContentSizeCategoryAccessibilityXXXL",
                    ]
                ),
            ]
            for variant in variants {
                app = XCUIApplication()
                app.launchEnvironment["PHOTOS_DEBUG_LOGIN"] = ProcessInfo.processInfo.environment["PHOTOS_UITEST_LOGIN"]
                app.launchArguments += variant.arguments
                app.launch()
                waitForTimeline()
                // The tab's title is German in German: the second tab.
                let tab = app.tabBars.buttons.element(boundBy: 1)
                XCTAssertTrue(tab.waitForExistence(timeout: 10), "No Collections tab")
                tab.tap()
                XCTAssertTrue(app.buttons["collections-shelf-albums"].firstMatch.waitForExistence(timeout: 10), "No Albums shelf")
                pause(4)
                shot("screens-30-collections-\(variant.name)")
                let places = app.buttons["collections-shelf-places"].firstMatch
                reveal(places)
                app.swipeUp(velocity: .slow)
                pause(2)
                shot("screens-31-collections-places-\(variant.name)")
                app.terminate()
            }
        }

        // Favorites opened from Collections (pushed there again since the loop of STATUS §20.1 is fixed): see
        // `CollectionsGridTests.testFavoritesGrid`.

        // MARK: Settings

        /// The first screen lists the pages; the search finds a setting and opens its page.
        func testSettingsPagesAndSearch() {
            app.launch()
            waitForTimeline()
            app.openSettings()
            pause(1)
            shot("screens-10-settings")
            for page in ["accounts", "library", "notifications", "backup", "storage", "privacy", "advanced", "about"] {
                let row = app.buttons["settings-page-\(page)"].firstMatch
                reveal(row)
                XCTAssertTrue(row.exists, "No \(page) page")
            }
            app.buttons["settings-page-storage"].firstMatch.tap()
            pause(1)
            shot("screens-11-settings-storage")
            XCTAssertTrue(app.staticTexts["Preview cache"].firstMatch.waitForExistence(timeout: 5), "Storage has no preview cache")
            app.navigationBars.buttons.firstMatch.tap()
            let field = app.searchFields.firstMatch
            if !field.waitForExistence(timeout: 3) { app.swipeDown() }
            XCTAssertTrue(field.waitForExistence(timeout: 5), "No search field in Settings")
            field.tap()
            field.typeText("face id")
            pause(1)
            shot("screens-12-settings-search")
            let result = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Privacy'")).firstMatch
            XCTAssertTrue(result.waitForExistence(timeout: 5), "The search does not find the app lock")
            result.tap()
            pause(1)
            shot("screens-13-settings-privacy")
        }

        /// The switch adds Stickers and Insights to Collections and takes them away again.
        func testAdvancedFeaturesSwitch() {
            app.launch()
            waitForTimeline()
            app.openSettings()
            let advanced = app.buttons["settings-page-advanced"].firstMatch
            reveal(advanced)
            advanced.tap()
            let toggle = app.switches["advanced-features"].firstMatch
            XCTAssertTrue(toggle.waitForExistence(timeout: 5), "No Advanced features switch")
            // From a known state: an earlier run may have left it on.
            setSwitch(toggle, on: false)
            shot("screens-20-advanced-off")
            setSwitch(toggle, on: true)
            pause(1)
            shot("screens-21-advanced-on")
            // Done is on the first screen of Settings.
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(app.buttons["settings-done"].firstMatch.waitForExistence(timeout: 5), "No Done on the first screen")
            app.buttons["settings-done"].firstMatch.tap()
            openCollections()
            let stickers = app.buttons["Stickers"].firstMatch
            reveal(stickers)
            shot("screens-22-collections-advanced")
            XCTAssertTrue(stickers.exists, "Stickers is not listed with Advanced features on")
            XCTAssertTrue(app.buttons["Insights"].firstMatch.exists, "Insights is not listed with Advanced features on")
            // Back off, as the next run expects.
            app.openSettings()
            reveal(advanced)
            advanced.tap()
            if toggle.waitForExistence(timeout: 5) { setSwitch(toggle, on: false) }
        }
    }
#endif
