// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import XCTest

/// Smoke tests of the running app against a real server (see docs/TESTING.md).
///
/// They need a Debug build (the debug login) and a test server with at least one photo, and only run when
/// `PHOTOS_UITEST_LOGIN` holds a login link: `nc://login/server:<url>&user:<user>&password:<app password>`
/// (with xcodebuild: `TEST_RUNNER_PHOTOS_UITEST_LOGIN=…`). They only look and navigate; nothing on the server changes.
///
/// CI runs them on an iPhone simulator against a fresh server with Nextcloud's sample photos (`ui-smoke` in
/// .github/workflows/ci.yml), so they must not depend on the day they run nor on more than a few photos. Every step is
/// attached as a screenshot; with `PHOTOS_UITEST_SHOTS=<directory>` the screenshots are also written there.
///
/// The tests find things by role, by their English labels and by the few accessibility identifiers the app has.
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

    /// A screenshot of the step, attached to the result and written to `PHOTOS_UITEST_SHOTS` when it is set.
    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let path = ProcessInfo.processInfo.environment["PHOTOS_UITEST_SHOTS"], !path.isEmpty else { return }
        let folder = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: folder.appending(path: "smoke-\(name).png"))
    }

    /// Waits until one of the elements exists.
    private func waitForAny(_ elements: [XCUIElement], timeout: TimeInterval = SmokeTests.wait) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if elements.contains(where: \.exists) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return false
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
        shot("library")
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
        shot("viewer")

        #if os(macOS)
            app.typeKey(.escape, modifierFlags: [])
        #else
            app.buttons["Close"].firstMatch.tap()
        #endif
        XCTAssertTrue(info.waitForNonExistence(timeout: Self.wait), "The viewer did not close")
        XCTAssertTrue(tiles.firstMatch.exists)
        shot("viewer-closed")
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
        XCTAssertTrue(waitForAny([title, windowTitle, heading]), "The Albums screen did not appear")
        shot("albums")
    }

    #if os(iOS)
        private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

        /// Opens a link of the app; the system may ask first.
        private func open(_ route: String) throws {
            app.open(try XCTUnwrap(URL(string: "nextcloudphotos://\(route)")))
            let confirm = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"].firstMatch
            if confirm.waitForExistence(timeout: 3) { confirm.tap() }
        }

        /// The Collections tab (iPhone): its "+" menu is there, and it scrolls.
        func testCollections() throws {
            try XCTSkipUnless(isPhone, "The Collections tab is the iPhone's.")
            waitForTimeline()
            let tab = app.tabBars.buttons["Collections"].firstMatch
            XCTAssertTrue(tab.waitForExistence(timeout: 10), "No Collections tab")
            tab.tap()
            let add = app.buttons["collections-add"].firstMatch
            XCTAssertTrue(add.waitForExistence(timeout: 10), "The Collections tab did not appear")
            shot("collections")
            app.swipeUp()
            XCTAssertEqual(app.state, .runningForeground)
            // The link, not the tab: the tab bar may have minimised while the list scrolled.
            try open("library")
            XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 10), "Back in the Library, no photos")
        }

        /// Settings is a sheet from the account button, and Done closes it.
        func testSettingsSheet() {
            waitForTimeline()
            app.openSettings()
            shot("settings")
            app.buttons["settings-done"].firstMatch.tap()
            XCTAssertTrue(app.buttons["settings-done"].firstMatch.waitForNonExistence(timeout: 10), "Settings did not close")
            XCTAssertTrue(app.accountMenu.waitForExistence(timeout: 10), "Not back in the Library")
        }

        /// The Library's filter menu: Favorites shows a chip under the title, and the chip clears the filter again.
        func testFilterMenu() {
            waitForTimeline()
            let filter = app.buttons["library-filter"].firstMatch
            XCTAssertTrue(filter.waitForExistence(timeout: 10), "No filter menu")
            filter.tap()
            let favorites = app.buttons["Favorites"].firstMatch
            XCTAssertTrue(favorites.waitForExistence(timeout: 10), "No Favorites in the filter menu")
            shot("filter-menu")
            favorites.tap()
            let chip = app.buttons["Remove filter Favorites"].firstMatch
            XCTAssertTrue(chip.waitForExistence(timeout: 10), "No Favorites chip under the title")
            shot("filter-favorites")
            chip.tap()
            XCTAssertTrue(chip.waitForNonExistence(timeout: 10), "The chip did not clear the filter")
            XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 10), "No photos after clearing the filter")
        }

        /// Clean up opens with its sections, and a section opens its review screen.
        func testCleanUp() throws {
            waitForTimeline()
            try open("cleanUp")
            let largeVideos = app.buttons["cleanUp.largeVideos"].firstMatch
            XCTAssertTrue(largeVideos.waitForExistence(timeout: Self.wait), "Clean up did not open")
            XCTAssertTrue(app.buttons["cleanUp.duplicates"].exists, "No Duplicates in Clean up")
            shot("cleanup")
            largeVideos.tap()
            XCTAssertTrue(largeVideos.waitForNonExistence(timeout: 10), "Large videos did not open")
            shot("cleanup-large-videos")
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(largeVideos.waitForExistence(timeout: 10), "Back did not return to Clean up")
        }
    #endif
}
