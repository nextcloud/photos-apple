// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import XCTest

/// The viewer as a stage on iPhone and iPad (SPEC §17.1): glass controls, hiding them with a tap, the More menu without
/// a software keyboard, the info card and closing with a drag back into the grid. Needs `PHOTOS_UITEST_LOGIN`; nothing
/// is changed on the server. With `PHOTOS_UITEST_SHOTS` the screenshots are written there too, and
/// `PHOTOS_UITEST_SHOT_PREFIX` names them (e.g. "light-").
@MainActor
final class ViewerStageTourTests: XCTestCase {
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
            if let style = environment["PHOTOS_UITEST_BACKDROP"], !style.isEmpty {
                app.launchArguments += ["-lookViewerBackdrop", style]
            }
            if environment["PHOTOS_UITEST_REDUCE_MOTION"] == "1" {
                app.launchArguments += ["-UIAccessibilityReduceMotionEnabled", "YES"]
            }
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

    /// Opens the viewer on a tile in the middle of the screen.
    func openViewer(tile index: Int = 7) {
        let tiles = app.collectionViews.cells
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 60), "No photos in the timeline")
        pause(3)
        tiles.element(boundBy: index).tap()
        XCTAssertTrue(app.buttons["Close"].firstMatch.waitForExistence(timeout: 10), "The viewer did not open")
        pause(2.5)
    }

    /// The middle of the screen: the photo shown.
    var center: XCUICoordinate { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)) }

    /// The stage, its controls hidden with a tap and back, and the More menu: no software keyboard comes up with it.
    func testStageAndMoreMenu() {
        openViewer()
        shot("10-viewer")
        center.tap()
        pause(1.2)
        shot("11-viewer-controls-hidden")
        XCTAssertFalse(app.buttons["Close"].firstMatch.isHittable, "The controls did not hide")
        center.tap()
        pause(1.2)
        let more = app.buttons["More"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5), "No More button")
        more.tap()
        pause(1.5)
        shot("12-viewer-more-menu")
        XCTAssertEqual(app.keyboards.count, 0, "A software keyboard came up with the More menu")
        // Closes the menu without choosing anything.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.2)).tap()
        pause(1.5)
        XCTAssertEqual(app.keyboards.count, 0, "A software keyboard came up after the More menu")
        shot("13-viewer-after-menu")
    }

    /// The info card at half height with the photo above it, then at full height.
    func testInfoCard() {
        openViewer()
        app.buttons["Info"].firstMatch.tap()
        pause(2.5)
        shot("20-info-card")
        XCTAssertEqual(app.keyboards.count, 0)
        app.swipeUp(velocity: .slow)
        pause(1.5)
        shot("21-info-card-large")
    }

    /// Dragging the photo down: it shrinks and the grid comes back behind it; let go early and it springs back; drag
    /// far and it lands in its tile.
    func testInteractiveDismissal() {
        openViewer()
        let start = center
        // A short drag: cancelled, the viewer stays.
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 60)), withVelocity: .slow, thenHoldForDuration: 0)
        pause(1.5)
        XCTAssertTrue(app.buttons["Close"].firstMatch.exists, "A short drag closed the viewer")
        shot("30-after-cancelled-drag")
        // Halfway: hold to take a picture of the photo on its way, then let go.
        start.press(
            forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 40, dy: 260)), withVelocity: .slow, thenHoldForDuration: 1.5)
        pause(2)
        XCTAssertFalse(app.buttons["Close"].firstMatch.exists, "A long drag did not close the viewer")
        shot("31-after-dismissal")
    }

    /// "3 of 120" of the photo on screen.
    var shownPosition: String? {
        let pages = app.images.matching(NSPredicate(format: "value CONTAINS ' of '"))
        let screen = app.windows.firstMatch.frame
        for index in 0..<pages.count {
            let page = pages.element(boundBy: index)
            let frame = page.frame
            if frame.width > 0, screen.contains(CGPoint(x: frame.midX, y: frame.midY)) { return page.value as? String }
        }
        return nil
    }

    /// Hardware keyboard: the arrow keys page, Escape closes — and no software keyboard comes up.
    func testKeys() {
        openViewer()
        let before = shownPosition
        XCTAssertNotNil(before)
        app.typeKey(.rightArrow, modifierFlags: [])
        pause(1.5)
        shot("50-after-right-arrow")
        XCTAssertNotEqual(before, shownPosition, "The right arrow did not page")
        app.typeKey(.leftArrow, modifierFlags: [])
        pause(1.5)
        XCTAssertEqual(before, shownPosition, "The left arrow did not page back")
        XCTAssertEqual(app.keyboards.count, 0)
        app.typeKey(.escape, modifierFlags: [])
        pause(2)
        if app.buttons["Close"].firstMatch.exists {
            // Escape does not reach apps from XCUITest on the iPhone simulator (see the report); Space closes a photo too.
            app.typeKey(" ", modifierFlags: [])
            pause(2)
        }
        XCTAssertFalse(app.buttons["Close"].firstMatch.exists, "Neither Escape nor Space closed the viewer")
    }

    /// Paging stays smooth with the backdrop following the photo.
    func testPaging() {
        openViewer()
        shot("39-first-photo")
        app.swipeLeft()
        pause(1.5)
        shot("40-next-photo")
        app.swipeLeft()
        pause(1.5)
        shot("41-next-photo")
    }
}
