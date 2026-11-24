// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import XCTest

/// A tour of Travel and "Then and now" (SPEC §15.6) against a test server with geotagged photos from several years
/// (the test library). Same requirements as `SmokeTests`; screenshots are attached to the result and, when
/// `PHOTOS_UITEST_SHOTS` names a folder, also written there. Only looks, navigates and plays; nothing on the server
/// changes.
@MainActor
final class PlacesTourTests: XCTestCase {
    static let wait: TimeInterval = 90
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let login = environment["PHOTOS_UITEST_LOGIN"], !login.isEmpty else {
            throw XCTSkip("Set PHOTOS_UITEST_LOGIN to a login link of a test server to run the UI tests.")
        }
        try XCTSkipIf((Bundle.main.bundleIdentifier ?? "").hasPrefix(SmokeTests.officialBundleId + ".uitests"))
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

    func tap(_ element: XCUIElement, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: Self.wait), "\(what) did not appear", file: file, line: line)
        #if os(macOS)
            element.click()
        #else
            element.tap()
        #endif
    }

    /// Places is listed in the Collections tab on iPhone.
    func openPlaces() {
        #if os(iOS)
            tap(app.tabBars.buttons["Collections"].firstMatch, "The Collections tab")
            tap(app.buttons["Places"].firstMatch, "Places")
        #else
            tap(app.outlines.staticTexts["Places"].firstMatch, "Places")
        #endif
    }

    func testTravelGlobeAndCountries() {
        openPlaces()
        let travel = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Travel'")).firstMatch
        XCTAssertTrue(travel.waitForExistence(timeout: Self.wait), "No Travel card in Places")
        shot("01-places")
        tap(travel, "The Travel card")
        XCTAssertTrue(app.staticTexts["All years"].waitForExistence(timeout: Self.wait), "The globe's panel did not appear")
        // Let the globe's imagery load.
        _ = app.staticTexts["never"].waitForExistence(timeout: 8)
        shot("02-globe")
        // A trip of the list flies the globe to it.
        let trip = app.scrollViews.buttons.firstMatch
        if trip.waitForExistence(timeout: 10) {
            trip.tap()
            _ = app.staticTexts["never"].waitForExistence(timeout: 5)
            shot("03-globe-trip")
        }
        tap(app.buttons["Countries"].firstMatch, "Countries")
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label ENDSWITH 'of the world'")).firstMatch.waitForExistence(timeout: Self.wait))
        shot("04-countries")
        // The test server's index has no countries: look them up (the test library's coordinates go to Apple Maps).
        let lookUp = app.buttons["Look up countries with Apple Maps"].firstMatch
        if lookUp.waitForExistence(timeout: 5) {
            lookUp.tap()
            _ = app.staticTexts["never"].waitForExistence(timeout: 40)
            shot("04b-countries-looked-up")
        }
        tap(app.buttons["Scratch map"].firstMatch, "Scratch map")
        _ = app.staticTexts["never"].waitForExistence(timeout: 1)
        shot("05-scratch-map")
    }

    func testThenAndNow() {
        openPlaces()
        let header = app.staticTexts["Then and now"].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: Self.wait), "No Then and now row in Places")
        let card = app.buttons.matching(NSPredicate(format: "label MATCHES '.*[0-9]{4} · [0-9]{4}.*'")).firstMatch
        tap(card, "A Then and now card")
        let play = app.buttons["Play time-lapse"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: Self.wait), "The spot did not open")
        // Give the view matching a moment.
        _ = app.staticTexts["never"].waitForExistence(timeout: 6)
        shot("06-then-and-now")
        play.tap()
        _ = app.staticTexts["never"].waitForExistence(timeout: 3)
        shot("07-time-lapse")
        _ = app.staticTexts["never"].waitForExistence(timeout: 1.6)
        shot("08-time-lapse-fade")
        tap(app.buttons["Close"].firstMatch, "Close")
        tap(app.buttons["Export video…"].firstMatch, "Export video")
        XCTAssertTrue(app.buttons["Share"].waitForExistence(timeout: 240), "The video was not made")
        _ = app.staticTexts["never"].waitForExistence(timeout: 2)
        shot("09-exported-video")
        tap(app.buttons["Done"].firstMatch, "Done")

        // A year opens its photos in the viewer, whose More menu offers Then and now for them.
        tap(app.buttons.matching(NSPredicate(format: "label MATCHES '^[0-9]{4}, .*'")).firstMatch, "A year")
        tap(app.buttons["More"].firstMatch, "More")
        tap(app.buttons["Then and now"].firstMatch, "Then and now in the More menu")
        XCTAssertTrue(app.buttons["Play time-lapse"].waitForExistence(timeout: Self.wait), "Then and now did not open from the viewer")
        _ = app.staticTexts["never"].waitForExistence(timeout: 6)
        shot("10-from-viewer")
    }
}
