// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import XCTest

/// The Library's zoom levels morphing into each other (SPEC §17.5): years into months, months into days, a day into the
/// grid at the tapped photo, and back out by pinching and with the level picker.
///
/// Like `SmokeTests` it needs `PHOTOS_UITEST_LOGIN`; it only looks and navigates. With `PHOTOS_UITEST_SHOTS` set to a
/// folder, it saves a screenshot of every settled step there. The motion itself is best seen in a screen recording made
/// while it runs (`xcrun simctl io <udid> recordVideo`); the pauses between the steps leave room for that.
@MainActor
final class LevelsTourTests: XCTestCase {
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

    func level(_ title: String) -> XCUIElement { app.buttons[title].firstMatch }

    var summary: XCUIElement { app.scrollViews["librarySummary"] }

    func testLevelsMorph() {
        XCTAssertTrue(app.collectionViews.cells.firstMatch.waitForExistence(timeout: 120), "No photos in the timeline")
        sleep(2)
        shot("levels-01-all-photos")

        level("Years").tap()
        sleep(2)
        shot("levels-02-years")

        // A year opens its months: its key photo travels into its month.
        let yearCard = app.buttons.matching(NSPredicate(format: "label MATCHES %@", "^[0-9]{4}, .*")).firstMatch
        XCTAssertTrue(yearCard.waitForExistence(timeout: 10), "No year cards")
        yearCard.tap()
        sleep(2)
        shot("levels-03-months")
        XCTAssertTrue(level("Months").isSelected)

        // A month opens its days.
        let monthCard = summary.buttons.matching(NSPredicate(format: "label MATCHES %@", "^[A-Z][a-z]+ [0-9]{4}, .*")).firstMatch
        XCTAssertTrue(monthCard.waitForExistence(timeout: 10), "No month cards")
        monthCard.tap()
        sleep(2)
        shot("levels-04-days")
        XCTAssertTrue(level("Days").isSelected)

        // The grid under the days is out of reach, but not the toolbar above it.
        XCTAssertTrue(app.buttons["Select"].firstMatch.isHittable, "The toolbar went with the hidden grid")
        XCTAssertFalse(app.collectionViews.cells.firstMatch.exists, "The grid's tiles are reachable under the days")
        // A day's photo is tappable (the grid under the days used to take the tap) and opens All Photos at it.
        let dayPhoto = summary.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Photo'")).firstMatch
        XCTAssertTrue(dayPhoto.waitForExistence(timeout: 10), "No photos in the days")
        XCTAssertTrue(dayPhoto.isHittable, "The day's photo cannot be tapped")
        dayPhoto.tap()
        sleep(2)
        shot("levels-05-all-photos-at-the-photo")
        XCTAssertTrue(level("All Photos").isSelected)

        // Back up with the picker: the grid's photos travel into the days, the days' into the months.
        level("Days").tap()
        sleep(2)
        shot("levels-06-days-from-the-grid")
        level("Months").tap()
        sleep(2)
        shot("levels-07-months-from-the-days")
        level("Years").tap()
        sleep(2)
        shot("levels-08-years-from-the-months")
        level("All Photos").tap()
        sleep(2)
        shot("levels-09-all-photos-from-the-years")
        XCTAssertTrue(level("All Photos").isSelected)
    }

    /// The text styles (SPEC §17.5) on the screens that use them: date headers, years and days, albums, memories,
    /// Insights. Run it at a large text size too (`xcrun simctl ui <udid> content_size accessibility-large`);
    /// `PHOTOS_UITEST_SHOT_PREFIX` keeps the two sets of screenshots apart.
    func testTypography() throws {
        XCTAssertTrue(app.collectionViews.cells.firstMatch.waitForExistence(timeout: 120), "No photos in the timeline")
        let prefix = ProcessInfo.processInfo.environment["PHOTOS_UITEST_SHOT_PREFIX"] ?? "type"
        sleep(2)
        shot("\(prefix)-01-date-headers")
        level("Years").tap()
        sleep(2)
        shot("\(prefix)-02-years")
        level("Months").tap()
        sleep(2)
        shot("\(prefix)-03-months")
        level("Days").tap()
        sleep(2)
        shot("\(prefix)-04-days")
        level("All Photos").tap()
        sleep(1)
        for route in ["albums", "memories", "insights"] {
            app.open(try XCTUnwrap(URL(string: "nextcloudphotos://\(route)")))
            // The system asks before a link opens the app.
            let open = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"].firstMatch
            if open.waitForExistence(timeout: 5) { open.tap() }
            sleep(4)
            shot("\(prefix)-\(route)")
        }
    }
}
