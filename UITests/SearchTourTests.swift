// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import XCTest

/// A tour of the command palette and of searches typed in words (SPEC §16.2), on iPhone and iPad.
///
/// Like `SmokeTests` it needs `PHOTOS_UITEST_LOGIN`. With `PHOTOS_UITEST_SHOTS` set to a folder, it saves a screenshot
/// of every step there as well as attaching it to the test.
@MainActor
final class SearchTourTests: XCTestCase {
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
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
        }
    }

    func openSearch() {
        XCTAssertTrue(app.collectionViews.cells.firstMatch.waitForExistence(timeout: 60), "No photos in the timeline")
        let tab = app.tabBars.buttons["Search"].firstMatch
        if tab.exists { tab.tap() } else { app.buttons["Search"].firstMatch.tap() }
    }

    /// Words become chips; a chip's menu changes it and the results follow.
    func testSearchInWords() {
        openSearch()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("favourite photos from Lisbon in 2025")
        let understood = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Search for")).firstMatch
        XCTAssertTrue(understood.waitForExistence(timeout: 10), "The words were not understood as chips")
        shot("20-understood")
        understood.tap()
        let place = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Lisbon")).firstMatch
        XCTAssertTrue(place.waitForExistence(timeout: 10), "No place chip")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Favorites")).firstMatch.exists)
        sleep(3)
        shot("21-chips-and-results")
        // The date chip's menu: the year before.
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "2025")).firstMatch.tap()
        shot("22-date-chip-menu")
        let earlier = app.buttons["2024"].firstMatch
        XCTAssertTrue(earlier.waitForExistence(timeout: 5), "No earlier year in the chip's menu")
        earlier.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "2024")).firstMatch.waitForExistence(timeout: 5))
        sleep(2)
        shot("23-changed-year")
    }

    /// The palette from the search screen's toolbar: a year, then a place.
    func testCommandPalette() {
        openSearch()
        let button = app.buttons["Quick actions"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
        let field = app.textFields["Quick actions"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        sleep(1)
        shot("30-palette")
        field.typeText("lisbn")
        let place = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Lisbon")).firstMatch
        XCTAssertTrue(place.waitForExistence(timeout: 10), "Lisbon was not found by a typo")
        shot("31-palette-typo")
        field.typeText("\n")
        sleep(3)
        shot("32-opened")
    }
}
