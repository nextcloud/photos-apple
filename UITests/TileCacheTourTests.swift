// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import XCTest

/// The Library's pre-rendered tiles (SPEC §22.4.1): after a first run has cached the first screen's previews and built
/// the tiles, a new launch shows pictures in its first frames; the same launch with the tiles turned off
/// (`PHOTOS_DEBUG_NO_TILES`, Debug builds) shows BlurHash squares first. Screenshots `tiles-*` (with
/// `PHOTOS_UITEST_SHOTS`), taken as soon as the first tile exists. Needs `PHOTOS_UITEST_LOGIN` like `SmokeTests`.
@MainActor
final class TileCacheTourTests: XCTestCase {
    var app: XCUIApplication!
    var login = ""

    override func setUp() async throws {
        continueAfterFailure = false
        guard let login = ProcessInfo.processInfo.environment["PHOTOS_UITEST_LOGIN"], !login.isEmpty else {
            throw XCTSkip("Set PHOTOS_UITEST_LOGIN to a login link of a test server to run the UI tests.")
        }
        try XCTSkipIf(
            (Bundle.main.bundleIdentifier ?? "").hasPrefix(SmokeTests.officialBundleId + ".uitests"),
            "Build the UI tests with a bundle id of your own (PHOTOS_BUNDLE_ID).")
        self.login = login
        #if os(iOS)
            XCUIDevice.shared.orientation = .portrait
        #endif
    }

    override func tearDown() async throws {
        app?.terminate()
        app = nil
    }

    private func launch(tiles: Bool) {
        app?.terminate()
        app = XCUIApplication()
        app.launchEnvironment["PHOTOS_DEBUG_LOGIN"] = login
        if !tiles { app.launchEnvironment["PHOTOS_DEBUG_NO_TILES"] = "1" }
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
    }

    private var cells: XCUIElementQuery {
        #if os(macOS)
            app.collectionViews.buttons
        #else
            app.collectionViews.cells
        #endif
    }

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let path = ProcessInfo.processInfo.environment["PHOTOS_UITEST_SHOTS"], !path.isEmpty else { return }
        let folder = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: folder.appending(path: "tiles-\(name).png"))
    }

    func testLaunchShowsTilesAtOnce() {
        // First run: sign-in, sync, the first screen's previews; the tiles are built 20 s after the sync.
        launch(tiles: true)
        XCTAssertTrue(cells.firstMatch.waitForExistence(timeout: SmokeTests.firstPhotosWait), "No photo in the timeline")
        RunLoop.current.run(until: Date().addingTimeInterval(45))

        launch(tiles: true)
        XCTAssertTrue(cells.firstMatch.waitForExistence(timeout: SmokeTests.wait))
        shot("1-launch-with-tiles")
        launch(tiles: false)
        XCTAssertTrue(cells.firstMatch.waitForExistence(timeout: SmokeTests.wait))
        shot("2-launch-without-tiles")
        XCTAssertGreaterThan(cells.count, 0)
    }
}
