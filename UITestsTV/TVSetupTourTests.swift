// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import XCTest

/// "Set Up with iPhone" on the TV (SPEC §22.2.2), in the simulators: DeviceDiscoveryUI finds no devices there, so the app
/// runs with `PHOTOS_DEBUG_TV_SETUP=bonjour` and finds the iPhone simulator's app (started with the same variable and
/// `PHOTOS_DEBUG_TV_SETUP_AUTO=1`, logged in) over Bonjour. The TV writes the login page it got to
/// `PHOTOS_SHOTS_DIR/tv-setup-login-url.txt`, where a script stands in for the user's browser and grants access; the TV
/// then signs in with its own app password. Runs only with `PHOTOS_UITEST_TV_SETUP=1` and a TV app without an account.
@MainActor
final class TVSetupTourTests: XCTestCase {
    let remote = XCUIRemote.shared
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["PHOTOS_UITEST_TV_SETUP"] == "1", "Set PHOTOS_UITEST_TV_SETUP=1 (needs the iPhone simulator).")
        try XCTSkipIf(
            (Bundle.main.bundleIdentifier ?? "").hasPrefix("com.nextcloud.photos.tv.uitests"),
            "Build the UI tests with a bundle id of your own (PHOTOS_BUNDLE_ID).")
        app = XCUIApplication()
        app.launchEnvironment["PHOTOS_DEBUG_TV_SETUP"] = "bonjour"
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
    }

    func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["PHOTOS_SHOTS_DIR"] {
            try? screenshot.pngRepresentation.write(to: URL(filePath: directory).appending(path: "tv-setup-\(name).png"))
        }
    }

    func press(_ button: XCUIRemote.Button, wait: TimeInterval = 0.8) {
        remote.press(button)
        Thread.sleep(forTimeInterval: wait)
    }

    /// Moves the focus with `direction` until `element` has it (at most `limit` presses).
    func focus(_ element: XCUIElement, by direction: XCUIRemote.Button, limit: Int = 6) -> Bool {
        for _ in 0..<limit {
            if element.hasFocus { return true }
            press(direction)
        }
        return element.hasFocus
    }

    func testSetUpWithIPhone() throws {
        let setUp = app.buttons["tv-setup-with-iphone"]
        XCTAssertTrue(setUp.waitForExistence(timeout: 30), "No Set Up with iPhone on the login screen")
        Thread.sleep(forTimeInterval: 1)
        shot("01-login")
        XCTAssertTrue(focus(setUp, by: .up), "Set Up with iPhone cannot be focused")
        press(.select, wait: 2)
        // The phone simulator's app, found over Bonjour.
        let phone = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Nextcloud Photos'")).firstMatch
        XCTAssertTrue(phone.waitForExistence(timeout: 30), "The iPhone simulator's app was not found")
        shot("02-phones")
        XCTAssertTrue(focus(phone, by: .down))
        press(.select, wait: 2)
        // The test server is http://: the TV asks first, as for a typed address.
        let connect = app.buttons["Connect"]
        if connect.waitForExistence(timeout: 20) {
            shot("03-unencrypted-question")
            XCTAssertTrue(focus(connect, by: .up) || focus(connect, by: .down), "Connect cannot be focused")
            press(.select, wait: 2)
        }
        // The page went to the phone: the TV shows it (and the code) while it waits.
        let title = app.staticTexts["Continue on your iPhone"]
        XCTAssertTrue(title.waitForExistence(timeout: 30), "The TV did not reach the login step")
        let link = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '/login/v2/flow/'")).firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 10), "No login page on the TV")
        shot("04-continue-on-iphone")
        if let directory = ProcessInfo.processInfo.environment["PHOTOS_SHOTS_DIR"] {
            try link.label.write(
                to: URL(filePath: directory).appending(path: "tv-setup-login-url.txt"), atomically: true, encoding: .utf8)
        }
        // Granted in "the browser": the TV is signed in with its own app password and shows the home screen.
        XCTAssertTrue(app.staticTexts["Memories"].waitForExistence(timeout: 180), "The TV did not sign in")
        Thread.sleep(forTimeInterval: 4)
        shot("05-home")
    }
}
