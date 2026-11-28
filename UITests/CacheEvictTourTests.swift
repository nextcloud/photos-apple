// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import XCTest

/// The importance-aware cache (SPEC §18.2), driven as a user would: photos looked at in the viewer for a while are
/// recorded as recently viewed, quick flicks are not, zooming in loads large previews, and Settings › Storage shows the
/// cache's size and limit. The cache files and the account database are inspected from outside afterwards. Needs
/// `PHOTOS_UITEST_LOGIN`; nothing is changed on the server.
@MainActor
final class CacheEvictTourTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = true
        #if !os(iOS)
            throw XCTSkip("iPhone and iPad tour.")
        #else
            let environment = ProcessInfo.processInfo.environment
            guard let login = environment["PHOTOS_UITEST_LOGIN"], !login.isEmpty else {
                throw XCTSkip("Set PHOTOS_UITEST_LOGIN to a login link of a test server to run the UI tests.")
            }
            app = XCUIApplication()
            app.launchEnvironment["PHOTOS_DEBUG_LOGIN"] = login
            app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-libraryZoomLevel", "all"]
            app.launch()
        #endif
    }

    override func tearDown() async throws {
        app?.terminate()
        app = nil
    }

    var prefix: String { ProcessInfo.processInfo.environment["PHOTOS_UITEST_SHOT_PREFIX"] ?? "" }

    func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = prefix + name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["PHOTOS_UITEST_SHOTS"], !folder.isEmpty {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(prefix)\(name).png"))
        }
    }

    func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Pages through the viewer: the first `looked` photos for two seconds each (zooming into every fourth), then
    /// `flicked` photos quickly.
    func testViewingAndZooming() {
        let looked = Int(ProcessInfo.processInfo.environment["PHOTOS_UITEST_LOOKED"] ?? "") ?? 24
        let flicked = 6
        let tiles = app.collectionViews.cells
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 60), "No photos in the timeline")
        pause(4)
        tiles.element(boundBy: 6).tap()
        XCTAssertTrue(app.buttons["Close"].firstMatch.waitForExistence(timeout: 10), "The viewer did not open")
        pause(2)
        shot("10-viewer")
        let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        for index in 0..<looked {
            if index % 4 == 1 {
                app.pinch(withScale: 3, velocity: 3)
                pause(3)
                if index == 1 { shot("11-viewer-zoomed") }
                center.doubleTap()
                pause(1)
            }
            pause(2)
            app.swipeLeft()
        }
        for _ in 0..<flicked {
            pause(0.3)
            app.swipeLeft()
        }
        pause(2)
        shot("12-viewer-end")
    }

    /// Settings › Storage: "<size>, up to <limit>".
    func testStorageRow() {
        // Settings is a sheet from the account button (SPEC §19.2); the row is on its Storage page (SPEC §20.4).
        app.openSettings(page: "storage")
        pause(1)
        // The row reads "Preview cache" with "<size>, up to <limit>" (one element or two, depending on the system).
        let value = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS ', up to '")).firstMatch
        for _ in 0..<12 where !(value.exists && value.isHittable) {
            app.swipeUp(velocity: .slow)
            pause(0.8)
        }
        XCTAssertTrue(value.exists, "No limit shown")
        pause(1)
        shot("20-settings-storage")
    }
}
