// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import XCTest

#if os(iOS)
    /// The app's chrome on iPhone (SPEC §17.3): the selection bar that the tab bar morphs into, the tab bar that minimises
    /// while scrolling, the progress accessory above it, and the screens around the grid. Needs `PHOTOS_UITEST_LOGIN`;
    /// with `PHOTOS_UITEST_SHOTS` the screenshots are written there too. Nothing on the server changes (the selection is
    /// only made and dropped, the accessory plays a made-up activity: `PHOTOS_DEBUG_ACTIVITY`).
    @MainActor
    final class ChromeTourTests: XCTestCase {
        var app: XCUIApplication!

        func launch(activity: String? = nil) throws {
            let environment = ProcessInfo.processInfo.environment
            guard let login = environment["PHOTOS_UITEST_LOGIN"], !login.isEmpty else {
                throw XCTSkip("Set PHOTOS_UITEST_LOGIN to a login link of a test server to run the UI tests.")
            }
            try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone, "The tour is the iPhone's.")
            continueAfterFailure = true
            app = XCUIApplication()
            app.launchEnvironment["PHOTOS_DEBUG_LOGIN"] = login
            if let activity { app.launchEnvironment["PHOTOS_DEBUG_ACTIVITY"] = activity }
            app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            app.launch()
        }

        override func tearDown() async throws {
            app?.terminate()
            app = nil
        }

        func shot(_ name: String) {
            let screenshot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            if let folder = ProcessInfo.processInfo.environment["PHOTOS_UITEST_SHOTS"], !folder.isEmpty {
                try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appending(path: "\(name).png"))
            }
        }

        func pause(_ seconds: TimeInterval) {
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        }

        var tiles: XCUIElementQuery { app.collectionViews.cells }

        func waitForTimeline() {
            XCTAssertTrue(tiles.element(boundBy: 6).waitForExistence(timeout: 60), "No photos in the timeline")
            pause(2)
        }

        func tab(_ name: String) {
            let button = app.tabBars.buttons[name].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 10), "No tab \(name)")
            button.tap()
            pause(2)
        }

        /// Select → the tab bar becomes the selection bar; Done → back.
        func testSelectionBarMorph() throws {
            try launch()
            waitForTimeline()
            shot("chrome-01-library")
            app.navigationBars.buttons["Select"].firstMatch.tap()
            // The tab bar turning into the bar, caught on the way.
            shot("chrome-02a-select-morphing")
            pause(0.1)
            shot("chrome-02b-select-morphing")
            pause(1.2)
            shot("chrome-02-select-empty")
            XCTAssertTrue(app.otherElements["selection-action-bar"].firstMatch.exists, "No selection bar")
            tiles.element(boundBy: 4).tap()
            // The capsule splitting into Share, the count and the actions.
            shot("chrome-02c-select-splitting")
            for index in [5, 9] { tiles.element(boundBy: index).tap() }
            pause(1)
            shot("chrome-03-select-3")
            XCTAssertTrue(app.staticTexts["3 selected"].firstMatch.exists, "No rolling count in the selection bar")
            XCTAssertTrue(app.buttons["Add to album"].firstMatch.exists, "No Add to album in the selection bar")
            tiles.element(boundBy: 10).tap()
            pause(1)
            shot("chrome-04-select-4")
            XCTAssertTrue(app.buttons["More"].firstMatch.exists, "No More menu in the selection bar")
            // Unselecting every photo melts the bar back into its one capsule.
            for index in [4, 5, 9, 10] { tiles.element(boundBy: index).tap() }
            pause(1.2)
            shot("chrome-05b-select-emptied")
            if app.buttons["Done"].firstMatch.exists { app.buttons["Done"].firstMatch.tap() }
            pause(1.2)
            shot("chrome-06-select-done")
            XCTAssertTrue(app.tabBars.buttons["Library"].firstMatch.waitForExistence(timeout: 5), "The tab bar did not come back")
        }

        /// Scrolling down minimises the tab bar; scrolling up brings it back.
        func testTabBarMinimizes() throws {
            try launch()
            waitForTimeline()
            app.collectionViews.firstMatch.swipeUp(velocity: .slow)
            pause(1.5)
            shot("chrome-10-tabbar-minimized")
            app.collectionViews.firstMatch.swipeDown(velocity: .slow)
            pause(1.5)
            shot("chrome-11-tabbar-back")
        }

        /// The accessory with a made-up backup: above the tab bar, beside the minimised one, its end, and a tap.
        func testActivityAccessory() throws {
            try launch(activity: "backup")
            waitForTimeline()
            let accessory = app.buttons["activity-accessory"].firstMatch
            XCTAssertTrue(accessory.waitForExistence(timeout: 20), "No accessory above the tab bar")
            pause(4)
            shot("chrome-20-accessory-expanded")
            app.collectionViews.firstMatch.swipeUp(velocity: .slow)
            pause(1.5)
            shot("chrome-21-accessory-inline")
            app.collectionViews.firstMatch.swipeDown(velocity: .slow)
            pause(1)
            // The made-up backup runs about 20 seconds, then shows its check mark.
            let done = app.buttons["Backup up to date"].firstMatch
            XCTAssertTrue(done.waitForExistence(timeout: 40), "The accessory did not show the finished backup")
            shot("chrome-22-accessory-done")
            done.tap()
            pause(2)
            shot("chrome-23-accessory-opened-backup")
        }

        /// The accessory while uploading, opened as the uploads list.
        func testUploadAccessory() throws {
            try launch(activity: "upload")
            waitForTimeline()
            let accessory = app.buttons["activity-accessory"].firstMatch
            XCTAssertTrue(accessory.waitForExistence(timeout: 20), "No accessory above the tab bar")
            pause(5)
            shot("chrome-24-accessory-upload")
        }

        /// The screens the grid does not own, edge to edge under the bars.
        func testOtherScreens() throws {
            try launch()
            waitForTimeline()
            tab("Collections")
            shot("chrome-30-collections")
            // Places opens on its map (SPEC §19.1): no row of its own for the map any more.
            for (row, name) in [("People", "people"), ("Places", "places"), ("Memories", "memories")] {
                let link = app.buttons[row].firstMatch
                guard link.waitForExistence(timeout: 5) else { continue }
                link.tap()
                pause(4)
                if name != "places" { app.swipeUp(velocity: .slow) }
                pause(1)
                shot("chrome-31-\(name)")
                app.navigationBars.buttons.element(boundBy: 0).tap()
                pause(1)
            }
            app.swipeUp()
            let backup = app.buttons["Backup"].firstMatch
            if backup.waitForExistence(timeout: 5) {
                backup.tap()
                pause(3)
                shot("chrome-32-backup")
                app.navigationBars.buttons.element(boundBy: 0).tap()
                pause(1)
            }
            tab("Search")
            shot("chrome-33-search")
            app.openSettings()
            app.swipeUp(velocity: .slow)
            pause(1)
            shot("chrome-34-settings")
        }
    }
#endif
