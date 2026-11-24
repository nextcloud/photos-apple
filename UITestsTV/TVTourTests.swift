// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import XCTest

/// A tour of the Apple TV app with the Siri Remote (SPEC §15.3) against a test server: home, a memory, the viewer, a
/// slideshow, albums and settings. Runs like the iPhone smoke tests (docs/TESTING.md): only with `PHOTOS_UITEST_LOGIN`,
/// never with the official bundle id. Screenshots are attached, and written to `PHOTOS_SHOTS_DIR` when it is set.
@MainActor
final class TVTourTests: XCTestCase {
    /// The official TV bundle id: its container may hold a real account, which the debug login would not replace.
    static let officialBundleId = "com.nextcloud.photos.tv"
    let remote = XCUIRemote.shared
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = true
        let environment = ProcessInfo.processInfo.environment
        guard let login = environment["PHOTOS_UITEST_LOGIN"], !login.isEmpty else {
            throw XCTSkip("Set PHOTOS_UITEST_LOGIN to a login link of a test server to run the UI tests.")
        }
        let runner = Bundle.main.bundleIdentifier ?? ""
        try XCTSkipIf(
            runner.hasPrefix(Self.officialBundleId + ".uitests"),
            "Build the UI tests with a bundle id of your own (PHOTOS_BUNDLE_ID), not com.nextcloud.photos.")
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
        if let directory = ProcessInfo.processInfo.environment["PHOTOS_SHOTS_DIR"] {
            try? screenshot.pngRepresentation.write(to: URL(filePath: directory).appending(path: "tv-tour-\(name).png"))
        }
    }

    func press(_ button: XCUIRemote.Button, times: Int = 1, wait: TimeInterval = 0.8) {
        for _ in 0..<times {
            remote.press(button)
            Thread.sleep(forTimeInterval: wait)
        }
    }

    func testTour() {
        XCTAssertTrue(app.staticTexts["Memories"].waitForExistence(timeout: 60), "the home screen shows memories")
        Thread.sleep(forTimeInterval: 3)
        // Into the memories shelf.
        press(.down)
        shot("01-home-focus")
        // A memory: its photos and Play.
        press(.select, wait: 3)
        shot("02-memory")
        press(.down, wait: 1.5)
        shot("03-memory-grid-focus")
        // The viewer: next photo, details.
        press(.select, wait: 3)
        shot("04-viewer")
        press(.right, wait: 2.5)
        shot("05-viewer-next")
        press(.select, wait: 1.5)
        shot("06-viewer-info")
        // Play/Pause on a photo: a slideshow from here.
        press(.playPause, wait: 4)
        shot("07-slideshow")
        press(.playPause, wait: 1.5)
        shot("08-slideshow-paused")
        press(.menu, wait: 1.5)
        press(.menu, wait: 1.5)
        press(.menu, wait: 2)
        // Albums tab.
        press(.menu, wait: 1.5)
        press(.right, wait: 3)
        shot("09-albums")
        press(.down, wait: 1.5)
        shot("10-albums-focus")
        press(.select, wait: 4)
        shot("11-album")
        press(.menu, wait: 1.5)
        press(.menu, wait: 1.5)
        // Settings tab.
        press(.right, wait: 3)
        shot("12-settings")
        XCTAssertTrue(app.staticTexts["Nextcloud"].exists || app.buttons["Log Out"].exists, "the settings show the account")
    }
}
