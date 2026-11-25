// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import XCTest

/// First impressions on iPhone and iPad (SPEC §17.6): the login over the drifting photo wall, the welcome into the
/// Library, the living gradients of the empty states and of the year in review. Needs `PHOTOS_UITEST_LOGIN`; nothing is
/// changed on the server. With `PHOTOS_UITEST_SHOTS` the screenshots are written there too, their names ending in
/// `PHOTOS_UITEST_SUFFIX` (e.g. "-dark", "-reduce-motion") when it is set.
@MainActor
final class WelcomeTourTests: XCTestCase {
    var app: XCUIApplication!
    var login = ""

    override func setUp() async throws {
        continueAfterFailure = true
        #if !os(iOS)
            throw XCTSkip("iPhone and iPad tour.")
        #else
            guard let login = ProcessInfo.processInfo.environment["PHOTOS_UITEST_LOGIN"], !login.isEmpty else {
                throw XCTSkip("Set PHOTOS_UITEST_LOGIN to a login link of a test server to run the UI tests.")
            }
            self.login = login
            app = XCUIApplication()
            app.launchEnvironment["PHOTOS_DEBUG_LOGIN"] = login
            app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        #endif
    }

    var suffix: String { ProcessInfo.processInfo.environment["PHOTOS_UITEST_SUFFIX"] ?? "" }

    func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name + suffix
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["PHOTOS_UITEST_SHOTS"], !folder.isEmpty {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appending(path: "\(name)\(suffix).png"))
        }
    }

    func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    func openLink(_ route: String) {
        app.open(URL(string: "nextcloudphotos://\(route)")!)
        let open = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"].firstMatch
        if open.waitForExistence(timeout: 5) { open.tap() }
        pause(3)
    }

    /// The login screen (shown over the logged-in account with `PHOTOS_DEBUG_WELCOME=login`): headline, card, wall.
    func testLoginScreen() {
        app.launchEnvironment["PHOTOS_DEBUG_WELCOME"] = "login"
        app.launch()
        let headline = app.staticTexts["Welcome to Nextcloud Photos"]
        XCTAssertTrue(headline.waitForExistence(timeout: 20), "No welcome headline on the login screen")
        XCTAssertTrue(app.textFields.firstMatch.exists, "No server address field")
        XCTAssertTrue(app.buttons["Log in"].exists, "No Log in button")
        pause(2)
        shot("welcome-01-login")
        // The wall drifts: a second picture a few seconds later.
        pause(4)
        shot("welcome-02-login-later")
        app.textFields.firstMatch.tap()
        pause(1.5)
        shot("welcome-03-login-keyboard")
    }

    /// The welcome into the Library (`PHOTOS_DEBUG_WELCOME=transition`), held for a few seconds
    /// (`PHOTOS_DEBUG_WELCOME_HOLD`) because `launch()` returns only once the app is idle; the Library takes taps while
    /// it plays.
    func testWelcomeIntoTheLibrary() {
        app.launchEnvironment["PHOTOS_DEBUG_WELCOME"] = "transition"
        app.launchEnvironment["PHOTOS_DEBUG_WELCOME_HOLD"] = "4"
        app.launch()
        shot("welcome-10-welcome")
        // Hidden from VoiceOver, and it takes no taps: the tab bar under it works.
        XCTAssertTrue(app.tabBars.buttons["Collections"].firstMatch.isHittable, "The welcome blocks the Library")
        pause(6)
        shot("welcome-13-library")
    }

    /// Empty states on the living wash: no shared albums, the search start screen and a search without results.
    func testEmptyStates() {
        app.launch()
        XCTAssertTrue(app.collectionViews.cells.firstMatch.waitForExistence(timeout: 60), "No photos in the timeline")
        openLink("sharedalbums")
        pause(2)
        shot("welcome-20-no-shared-albums")
        openLink("search")
        pause(2)
        shot("welcome-21-search-start")
        let field = app.searchFields.firstMatch
        if field.waitForExistence(timeout: 10) {
            field.tap()
            field.typeText("videos from 1990")
            let understood = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Search for")).firstMatch
            if understood.waitForExistence(timeout: 10) {
                understood.tap()
                XCTAssertTrue(app.staticTexts["No results"].waitForExistence(timeout: 20), "No empty search result")
                pause(2)
                shot("welcome-22-no-results")
            }
        }
    }

    /// The year in review cards with their moving blend.
    func testYearInReviewCards() {
        app.launch()
        XCTAssertTrue(app.collectionViews.cells.firstMatch.waitForExistence(timeout: 60), "No photos in the timeline")
        openLink("memories")
        let year = app.buttons.matching(NSPredicate(format: "label ENDSWITH ' in review'")).firstMatch
        XCTAssertTrue(year.waitForExistence(timeout: 30), "No year in review")
        year.tap()
        pause(4)
        for index in 1..<5 {
            app.swipeLeft()
            pause(2.5)
            shot(String(format: "welcome-3%d-review-card", index))
        }
    }
}
