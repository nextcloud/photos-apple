// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import XCTest

/// Smoke tests of the running app against a real server (see docs/TESTING.md).
///
/// They need a Debug build (the debug login) and a test server with at least one photo, and only run when
/// `PHOTOS_UITEST_LOGIN` holds a login link: `nc://login/server:<url>&user:<user>&password:<app password>`
/// (with xcodebuild: `TEST_RUNNER_PHOTOS_UITEST_LOGIN=…`). They only look and navigate; nothing on the server changes.
///
/// The app has no accessibility identifiers yet, so the tests find things by role and by their English labels.
@MainActor
final class SmokeTests: XCTestCase {
    /// The official bundle id: its container may hold a real account, which the debug login would not replace.
    static let officialBundleId = "com.nextcloud.photos"
    static let wait: TimeInterval = 60

    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let login = environment["PHOTOS_UITEST_LOGIN"], !login.isEmpty else {
            throw XCTSkip("Set PHOTOS_UITEST_LOGIN to a login link of a test server to run the UI tests.")
        }
        // The runner is `<app bundle id>.uitests.xctrunner`.
        let runner = Bundle.main.bundleIdentifier ?? ""
        try XCTSkipIf(
            runner.hasPrefix(Self.officialBundleId + ".uitests"),
            "Build the UI tests with a bundle id of your own (PHOTOS_BUNDLE_ID), not \(Self.officialBundleId).")
        app = XCUIApplication()
        app.launchEnvironment["PHOTOS_DEBUG_LOGIN"] = login
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
    }

    override func tearDown() async throws {
        app?.terminate()
        app = nil
    }

    /// Photo tiles: buttons in the grid on the Mac, cells on iOS.
    private var tiles: XCUIElementQuery {
        #if os(macOS)
            app.collectionViews.buttons
        #else
            app.collectionViews.cells
        #endif
    }

    private func waitForTimeline(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            tiles.firstMatch.waitForExistence(timeout: Self.wait), "No photo appeared in the timeline (login or first sync failed?)",
            file: file, line: line)
    }

    func testLaunchShowsTheTimeline() {
        waitForTimeline()
        XCTAssertGreaterThan(tiles.count, 0)
    }

    func testOpeningAndClosingTheViewer() {
        waitForTimeline()
        let first = tiles.firstMatch
        #if os(macOS)
            first.click()
        #else
            first.tap()
        #endif
        // The viewer's toolbar has an Info button; the grid has none.
        let info = app.buttons["Info"].firstMatch
        XCTAssertTrue(info.waitForExistence(timeout: Self.wait), "The viewer did not open")

        #if os(macOS)
            app.typeKey(.escape, modifierFlags: [])
        #else
            app.buttons["Close"].firstMatch.tap()
        #endif
        XCTAssertTrue(info.waitForNonExistence(timeout: Self.wait), "The viewer did not close")
        XCTAssertTrue(tiles.firstMatch.exists)
    }

    func testSwitchingToAlbums() throws {
        waitForTimeline()
        #if os(macOS)
            let row = app.outlines.staticTexts["Albums"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: Self.wait), "No Albums row in the sidebar")
            row.click()
        #else
            // iPad: sidebar or tab bar. iPhone: the tab is not in the tab bar by default, so the deep link opens it.
            let tab = app.tabBars.buttons["Albums"].firstMatch
            if tab.exists && tab.isHittable {
                tab.tap()
            } else {
                app.open(try XCTUnwrap(URL(string: "nextcloudphotos://albums")))
            }
        #endif
        // The Albums screen is titled "Albums"; with albums it shows them, without it says that there are none.
        let title = app.navigationBars["Albums"].firstMatch
        let windowTitle = app.windows["Albums"].firstMatch
        let heading = app.staticTexts["Albums"].firstMatch
        let deadline = Date().addingTimeInterval(Self.wait)
        var shown = false
        while !shown && Date() < deadline {
            shown = title.exists || windowTitle.exists || heading.exists
            if !shown { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        }
        XCTAssertTrue(shown, "The Albums screen did not appear")
    }
}
