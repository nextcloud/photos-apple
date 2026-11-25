// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import XCTest

/// Vision Pro polish (SPEC §17.7): the selection's actions, the viewer's actions and the slideshow's controls as glass
/// ornaments under the window. Needs `PHOTOS_UITEST_LOGIN` like the smoke tests; looks only, changes nothing.
///
/// XCUIScreen does not capture ornaments on visionOS: the tour waits at each place (marked in the log with
/// "PLATFORMS-TOUR <step>") while `xcrun simctl io <udid> screenshot` takes the pictures from outside.
@MainActor
final class PlatformsTourTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        guard let login = ProcessInfo.processInfo.environment["PHOTOS_UITEST_LOGIN"], !login.isEmpty else {
            throw XCTSkip("Set PHOTOS_UITEST_LOGIN to a login link of a test server to run the UI tests.")
        }
        app = XCUIApplication()
        app.launchEnvironment["PHOTOS_DEBUG_LOGIN"] = login
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    }

    override func tearDown() async throws {
        app?.terminate()
        app = nil
    }

    /// How long each place is held for the screenshots taken from outside.
    var hold: UInt32 {
        UInt32(ProcessInfo.processInfo.environment["PHOTOS_UITEST_HOLD"] ?? "") ?? 8
    }

    func mark(_ step: String) {
        print("PLATFORMS-TOUR \(step) \(Date().timeIntervalSince1970)")
    }

    #if os(visionOS)
        func testOrnaments() throws {
            app.launchEnvironment["PHOTOS_DEBUG_DESTINATION"] = "photos"
            app.launch()
            // The grid's tiles, not the sidebar's rows (also cells of a collection view).
            let tiles = app.collectionViews.cells.matching(NSPredicate(format: "label BEGINSWITH 'Photo,' OR label BEGINSWITH 'Video,'"))
            XCTAssertTrue(tiles.element(boundBy: 2).waitForExistence(timeout: 90), "No photos")
            sleep(6)
            mark("grid")
            sleep(hold)

            // Selection: its actions in an ornament under the window.
            app.buttons["Select"].firstMatch.tap()
            tiles.element(boundBy: 2).tap()
            tiles.element(boundBy: 3).tap()
            let delete = app.buttons["Delete"].firstMatch
            if !delete.waitForExistence(timeout: 10) { print("PLATFORMS-TOUR tree", app.debugDescription) }
            XCTAssertTrue(delete.exists, "No selection actions")
            sleep(2)
            mark("selection")
            sleep(hold)
            app.buttons["Done"].firstMatch.tap()
            sleep(2)

            // The viewer: its actions in an ornament.
            tiles.element(boundBy: 2).tap()
            XCTAssertTrue(app.buttons["Info"].firstMatch.waitForExistence(timeout: 20), "No viewer actions")
            sleep(4)
            mark("viewer")
            sleep(hold)

            // The slideshow from the viewer's More menu: playback controls in an ornament.
            app.buttons["More"].firstMatch.tap()
            let slideshow = app.buttons["Slideshow"].firstMatch
            XCTAssertTrue(slideshow.waitForExistence(timeout: 10), "No Slideshow in More")
            slideshow.tap()
            XCTAssertTrue(app.buttons["Pause"].firstMatch.waitForExistence(timeout: 20), "No slideshow controls")
            sleep(3)
            mark("slideshow")
            sleep(hold)
            mark("done")
        }
    #endif
}
