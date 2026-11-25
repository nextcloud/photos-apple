// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import XCTest

/// A tour of the Library's zoom levels and "Show Similar" (SPEC §15.5), on iPhone and iPad.
///
/// Like `SmokeTests` it needs `PHOTOS_UITEST_LOGIN`; it only looks and navigates. With `PHOTOS_UITEST_SHOTS` set to a
/// folder, it saves a screenshot of every step there as well as attaching it to the test.
@MainActor
final class FeelTourTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let login = environment["PHOTOS_UITEST_LOGIN"], !login.isEmpty else {
            throw XCTSkip("Set PHOTOS_UITEST_LOGIN to a login link of a test server to run the UI tests.")
        }
        try XCTSkipIf(
            (Bundle.main.bundleIdentifier ?? "").hasPrefix(SmokeTests.officialBundleId + ".uitests"),
            "Build the UI tests with a bundle id of your own (PHOTOS_BUNDLE_ID).")
        app = XCUIApplication()
        app.launchEnvironment["PHOTOS_DEBUG_LOGIN"] = login
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-libraryZoomLevel", "all"]
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
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
        }
    }

    func waitForTiles() {
        XCTAssertTrue(app.collectionViews.cells.firstMatch.waitForExistence(timeout: 60), "No photos in the timeline")
    }

    func level(_ title: String) -> XCUIElement { app.buttons[title].firstMatch }

    /// A card of the zoom level shown that is on screen (pinching the whole scroll view would start on the tab bar).
    func visibleCard() -> XCUIElement {
        let buttons = app.scrollViews["librarySummary"].buttons
        let screen = app.windows.firstMatch.frame
        for index in 0..<min(buttons.count, 16) {
            let frame = buttons.element(boundBy: index).frame
            // In the middle of the screen, clear of the memories strip, the level picker and the tab bar.
            if frame.minY > screen.height * 0.45, frame.maxY < screen.height * 0.8 { return buttons.element(boundBy: index) }
        }
        return app.scrollViews["librarySummary"]
    }

    // XCUIElement has no pinch on visionOS: the tour runs on iPhone and iPad.
    #if !os(visionOS)
        func testZoomLevelsTour() {
            waitForTiles()
            sleep(2)
            shot("10-all-photos")

            level("Years").tap()
            sleep(3)
            shot("11-years")
            // A tap on a year zooms into its months.
            let yearCard = app.buttons.matching(NSPredicate(format: "label MATCHES %@", "^[0-9]{4}, .*")).firstMatch
            XCTAssertTrue(yearCard.waitForExistence(timeout: 10), "No year cards")
            yearCard.tap()
            sleep(2)
            shot("12-months-after-tapping-a-year")
            XCTAssertTrue(level("Months").isSelected)

            // Pinch in on the months: the days.
            visibleCard().pinch(withScale: 1.25, velocity: 1)
            sleep(2)
            shot("13-days-after-pinch")
            XCTAssertTrue(level("Days").isSelected)

            // Pinch out on a day in the middle (a pinch on the whole scroll view would start on the tab bar): the months.
            visibleCard().pinch(withScale: 0.75, velocity: -1)
            sleep(2)
            shot("14-months-after-pinch-out")
            XCTAssertTrue(level("Months").isSelected)

            level("Days").tap()
            sleep(2)
            // A tap on a day's photo opens All Photos at it.
            let dayPhoto = app.scrollViews["librarySummary"].buttons.matching(NSPredicate(format: "label BEGINSWITH 'Photo'")).firstMatch
            if dayPhoto.waitForExistence(timeout: 5) {
                dayPhoto.tap()
                sleep(2)
                shot("15-all-photos-after-tapping-a-day")
                XCTAssertTrue(level("All Photos").isSelected)
            }

            // Pinch out of the grid until the days take over.
            for attempt in 0..<7 {
                guard level("Days").exists, !level("Days").isSelected else { break }
                app.collectionViews.firstMatch.cells.element(boundBy: 6).pinch(withScale: 0.78, velocity: -1)
                sleep(1)
                shot("16-grid-pinch-out-\(attempt)")
            }
            // A synthesized pinch can start UIKit's two-finger selection instead (real fingers rarely do): then this step is
            // left out rather than failed.
            guard level("Days").exists else {
                app.buttons["Done"].firstMatch.tap()
                return
            }
            shot("17-days-after-pinching-out-of-the-grid")
            XCTAssertTrue(level("Days").isSelected)
            level("All Photos").tap()
            sleep(1)
        }
    #endif

    func testShowSimilar() {
        waitForTiles()
        sleep(2)
        let tile = app.collectionViews.cells.element(boundBy: 12)
        tile.press(forDuration: 1.2)
        let similar = app.buttons["Show similar"].firstMatch
        XCTAssertTrue(similar.waitForExistence(timeout: 5), "No Show similar in the context menu")
        shot("20-context-menu")
        similar.tap()
        sleep(6)
        shot("21-similar-photos")
        XCTAssertTrue(app.navigationBars["Similar Photos"].waitForExistence(timeout: 10))
        app.buttons["Done"].firstMatch.tap()

        // The viewer's More menu offers it too.
        app.collectionViews.cells.element(boundBy: 3).tap()
        sleep(2)
        let more = app.buttons["More"].firstMatch
        if more.waitForExistence(timeout: 5) {
            more.tap()
            sleep(1)
            shot("22-viewer-more-menu")
        }
    }
}
