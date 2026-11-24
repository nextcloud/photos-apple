// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import XCTest

/// A tour of the round-5 extras on iPhone (SPEC §15.8): Settings › Smart offline and Photo of the Day, Make Sticker, a
/// collage of a selection, the sticker book, and a photo of the day notification. Same requirements as `SmokeTests`
/// (`PHOTOS_UITEST_LOGIN`); screenshots are attached and, with `PHOTOS_UITEST_SHOTS=<folder>`, also written there.
/// Nothing on the server changes.
@MainActor
final class ExtrasTourTests: XCTestCase {
    static let wait: TimeInterval = 60
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = true
        let environment = ProcessInfo.processInfo.environment
        guard let login = environment["PHOTOS_UITEST_LOGIN"], !login.isEmpty else {
            throw XCTSkip("Set PHOTOS_UITEST_LOGIN to a login link of a test server to run the UI tests.")
        }
        #if !os(iOS)
            throw XCTSkip("The tour is written for iPhone.")
        #endif
        app = XCUIApplication()
        app.launchEnvironment["PHOTOS_DEBUG_LOGIN"] = login
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
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
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
        }
    }

    func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    var tiles: XCUIElementQuery { app.collectionViews.cells }

    func waitForTimeline() {
        // The app restores the tab of the last run: start from the Library (the link waits for the restored state).
        let library = app.tabBars.buttons["Library"].firstMatch
        _ = library.waitForExistence(timeout: 20)
        pause(2)
        if let link = URL(string: "nextcloudphotos://library") { app.open(link) }
        pause(1)
        if library.exists { library.tap() }
        XCTAssertTrue(app.buttons["Select"].firstMatch.waitForExistence(timeout: Self.wait), "The Library did not show")
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: Self.wait), "No photo appeared in the timeline")
        pause(3)
    }

    /// Scrolls the Settings list until `element` is on screen.
    func scroll(to element: XCUIElement, maxSwipes: Int = 12) {
        var swipes = 0
        while !(element.exists && element.isHittable) && swipes < maxSwipes {
            app.swipeUp(velocity: .slow)
            swipes += 1
        }
    }

    #if os(iOS)
        func element(_ text: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        }

        func testSmartOfflineSettings() {
            app.launch()
            waitForTimeline()
            app.tabBars.buttons["Settings"].tap()
            scroll(to: element("Space to use"))
            app.swipeUp(velocity: .slow)
            pause(2)
            shot("02-settings-smart-offline")
            XCTAssertTrue(element("Space to use").exists)
        }

        func testMakeSticker() throws {
            app.launch()
            waitForTimeline()
            // A dog in the test library.
            app.open(try XCTUnwrap(URL(string: "nextcloudphotos://photo/2840")))
            let more = app.buttons["More"].firstMatch
            XCTAssertTrue(more.waitForExistence(timeout: Self.wait), "The viewer did not open")
            pause(2)
            more.tap()
            let make = app.buttons["Make sticker"].firstMatch
            XCTAssertTrue(make.waitForExistence(timeout: 10), "No Make sticker in the More menu")
            shot("03-viewer-more-menu")
            make.tap()
            pause(8)
            shot("04-sticker")
        }

        func testCollageOfASelection() {
            app.launch()
            waitForTimeline()
            app.buttons["Select"].firstMatch.tap()
            pause(1)
            for index in [0, 1, 2, 4, 5, 7] where index < tiles.count { tiles.element(boundBy: index).tap() }
            pause(1)
            shot("05a-selection")
            // The context menu of a selected photo has the selection's actions. (The bottom toolbar's More menu lies under
            // the tab bar on iPhone in the iOS 27.2 simulator, a bug of the grid, not reachable here.)
            tiles.element(boundBy: 0).press(forDuration: 1.2)
            pause(1)
            shot("05b-selection-menu")
            let collage = app.buttons["Create collage"].firstMatch
            XCTAssertTrue(collage.waitForExistence(timeout: 10), "No Create collage in the selection's menu")
            collage.tap()
            pause(8)
            shot("06-collage-mosaic")
            for (style, name) in [("Magazine", "07-collage-magazine"), ("Prints", "08-collage-prints"), ("Grid", "09-collage-grid")] {
                let segment = app.buttons[style].firstMatch
                if segment.waitForExistence(timeout: 5) { segment.tap() }
                pause(2)
                shot(name)
            }
            // Swap two photos: the hint appears after the first tap.
            let canvas = app.otherElements["Collage"].firstMatch
            if canvas.exists {
                canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.25)).tap()
                pause(1)
                shot("10-collage-swap-picked")
            }
        }

        func testStickerBook() throws {
            app.launch()
            waitForTimeline()
            app.open(try XCTUnwrap(URL(string: "nextcloudphotos://stickers")))
            pause(3)
            shot("11-sticker-book")
        }

        /// Turns the photo of the day on (the debug build adds one for 25 seconds later), goes to the Home Screen and opens the
        /// notification.
        func testPhotoOfTheDayNotification() throws {
            app.launchEnvironment["PHOTOS_DEBUG_PHOTO_OF_THE_DAY_IN"] = "25"
            app.launch()
            waitForTimeline()
            app.tabBars.buttons["Settings"].tap()
            let toggle = app.switches["Photo of the Day"].firstMatch
            scroll(to: toggle)
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            addUIInterruptionMonitor(withDescription: "notifications") { alert in
                let allow = alert.buttons["Allow"]
                if allow.exists {
                    allow.tap()
                    return true
                }
                return false
            }
            // Off first when an earlier run left it on: turning it on schedules the notifications.
            if toggle.value as? String == "1" {
                toggle.switches.firstMatch.tap()
                pause(1)
            }
            toggle.switches.firstMatch.tap()
            pause(2)
            let allow = springboard.buttons["Allow"]
            if allow.waitForExistence(timeout: 5) { allow.tap() }
            pause(3)
            shot("12-settings-photo-of-the-day")
            XCUIDevice.shared.press(.home)
            let banner = springboard.otherElements["Notification"].descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS[c] 'Photo of the Day'")).firstMatch
            let appeared = banner.waitForExistence(timeout: 60)
            shot("13-photo-of-the-day-banner")
            XCTAssertTrue(appeared, "No photo of the day notification")
            guard appeared else { return }
            // Tapping it opens the photo in the viewer.
            banner.tap()
            let viewer = app.buttons["More"].firstMatch
            XCTAssertTrue(viewer.waitForExistence(timeout: 20), "The notification did not open the photo")
            pause(2)
            shot("15-photo-of-the-day-opened")
            // In Notification Centre, touched and held: the photo, large.
            XCUIDevice.shared.press(.home)
            pause(1)
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.005))
                .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.6)))
            pause(2)
            shot("14a-notification-centre")
            let delivered = springboard.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS[c] 'Photo of the Day'")).firstMatch
            if delivered.waitForExistence(timeout: 5) {
                delivered.press(forDuration: 1.5)
                pause(2)
                shot("14-photo-of-the-day-expanded")
            }
        }
    #endif
}
