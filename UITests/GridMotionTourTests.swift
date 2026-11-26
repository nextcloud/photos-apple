// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import XCTest

/// A tour of the grid's glass and motion on iPhone (SPEC §17.2): the Library edge to edge with its floating date pill,
/// selecting tiles, an album grid, and — on two photos the test uploads first, dated now, and removes at the end — the
/// heart burst, a delete with its undo. Same requirements as `SmokeTests` (`PHOTOS_UITEST_LOGIN`); screenshots are
/// attached and, with `PHOTOS_UITEST_SHOTS=<folder>`, also written there, prefixed with `PHOTOS_UITEST_SHOT_PREFIX`.
@MainActor
final class GridMotionTourTests: XCTestCase {
    static let wait: TimeInterval = 60
    var app: XCUIApplication!

    var prefix: String { ProcessInfo.processInfo.environment["PHOTOS_UITEST_SHOT_PREFIX"] ?? "grid" }
    var album: String { ProcessInfo.processInfo.environment["PHOTOS_UITEST_ALBUM"] ?? "r7-grid-album" }

    override func setUp() async throws {
        continueAfterFailure = true
        let environment = ProcessInfo.processInfo.environment
        guard let login = environment["PHOTOS_UITEST_LOGIN"], !login.isEmpty else {
            throw XCTSkip("Set PHOTOS_UITEST_LOGIN to a login link of a test server to run the UI tests.")
        }
        #if !os(iOS)
            throw XCTSkip("The tour is written for iPhone.")
        #endif
        app = XCUIApplication()
        app.launchEnvironment["PHOTOS_DEBUG_LOGIN"] = login
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if environment["PHOTOS_UITEST_REDUCE_MOTION"] == "1" {
            app.launchArguments += ["-UIAccessibilityReduceMotionEnabled", "YES"]
        }
        if environment["PHOTOS_UITEST_REDUCE_TRANSPARENCY"] == "1" {
            app.launchArguments += ["-UIAccessibilityReduceTransparencyEnabled", "YES"]
        }
    }

    override func tearDown() async throws {
        app?.terminate()
        app = nil
    }

    func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "\(prefix)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["PHOTOS_UITEST_SHOTS"], !folder.isEmpty {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(prefix)-\(name).png"))
        }
    }

    func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    var tiles: XCUIElementQuery { app.collectionViews.cells }

    func waitForTimeline() {
        let library = app.tabBars.buttons["Library"].firstMatch
        _ = library.waitForExistence(timeout: 20)
        pause(2)
        if let link = URL(string: "nextcloudphotos://library") { app.open(link) }
        pause(1)
        if library.exists { library.tap() }
        XCTAssertTrue(app.buttons["Select"].firstMatch.waitForExistence(timeout: Self.wait), "The Library did not show")
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: Self.wait), "No photo appeared in the timeline")
        pause(3)
    }

    /// The Library at the top, scrolled (date pill, content under the bars) and scrolled back up.
    func testLibraryEdgeToEdge() {
        app.launch()
        waitForTimeline()
        shot("01-library-top")
        app.swipeUp(velocity: .slow)
        pause(1.5)
        shot("02-library-scrolled")
        for _ in 0..<3 { app.swipeUp(velocity: .fast) }
        pause(2)
        shot("03-library-scrolled-further")
        app.swipeDown(velocity: .slow)
        pause(0.4)
        shot("04-library-handover")
        pause(1.5)
    }

    /// The memories strip leaves the window when the Library scrolls far and comes back when it scrolls up again: many
    /// times in a row, the app keeps running (a SwiftUI scroll-target trap when the strip came back, round-7 combine).
    func testLibraryHeaderComesBack() {
        app.launch()
        waitForTimeline()
        for _ in 0..<8 {
            for _ in 0..<4 { app.swipeUp(velocity: .fast) }
            pause(0.5)
            for _ in 0..<5 { app.swipeDown(velocity: .fast) }
            pause(0.8)
            XCTAssertEqual(app.state, .runningForeground, "The app stopped while the Library's header came back")
        }
        shot("05-library-header-back")
    }

    /// The Library stays scrolled away long enough for the memory story in front to finish (its photos at 4 s each):
    /// going on to the next story animated the strip's scroll position outside the window and trapped in SwiftUI
    /// (`ResolvedScrollBehavior.updateTarget`); the stories now wait while the strip is off screen (`GridHeaderVisibility`).
    func testLibraryStoriesWhileScrolledAway() {
        app.launch()
        waitForTimeline()
        for _ in 0..<3 {
            for _ in 0..<4 { app.swipeUp(velocity: .fast) }
            pause(40)
            XCTAssertEqual(app.state, .runningForeground, "The app stopped while the Library was scrolled away")
            for _ in 0..<6 { app.swipeDown(velocity: .fast) }
            pause(6)
            XCTAssertEqual(app.state, .runningForeground, "The app stopped when the Library's stories came back")
        }
        shot("06-library-stories-back")
    }

    /// Selection mode: three tiles selected, then one deselected again.
    func testSelection() {
        app.launch()
        waitForTimeline()
        app.buttons["Select"].firstMatch.tap()
        pause(1)
        for index in [0, 1, 2] where index < tiles.count { tiles.element(boundBy: index).tap() }
        pause(0.15)
        shot("10-selection-springing")
        pause(1)
        shot("11-selection-three")
        tiles.element(boundBy: 1).tap()
        pause(1)
        shot("12-selection-two")
        // The context menu stays available in the selection mode (as in Photos).
        tiles.element(boundBy: 0).press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Info"].firstMatch.waitForExistence(timeout: 10) || app.buttons["Adjust"].firstMatch.exists)
        shot("13-selection-menu")
    }

    /// The viewer zooms out of the tile and back into it (the grid now reaches under the bars: the tile's frame must
    /// still be found).
    func testZoomIntoViewerAndBack() {
        app.launch()
        waitForTimeline()
        app.swipeUp(velocity: .slow)
        pause(1.5)
        tiles.element(boundBy: 6).tap()
        pause(0.12)
        shot("40-viewer-opening")
        pause(2)
        shot("41-viewer-open")
        app.swipeDown(velocity: .fast)
        pause(0.15)
        shot("42-viewer-closing")
        pause(1.5)
        shot("43-back-in-grid")
    }

    /// An album's grid: under the bars, with its cover's colour as a wash.
    func testAlbumGrid() {
        app.launch()
        waitForTimeline()
        app.open(URL(string: "nextcloudphotos://albums")!)
        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", album)).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30), "No album \(album)")
        pause(2)
        card.tap()
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 30), "The album showed no photos")
        pause(3)
        shot("20-album-top")
        app.swipeUp(velocity: .slow)
        pause(1.5)
        shot("21-album-scrolled")
    }

    /// Favourite, delete and undo through the selection bar, on two photos the test uploads first (dated now, so they are
    /// the newest of the library and under "Today" whatever day it runs) into a folder of its own, removed at the end.
    func testActionFeedback() async throws {
        let login = ProcessInfo.processInfo.environment["PHOTOS_UITEST_LOGIN"] ?? ""
        let folder = "Photos/UI test actions \(UUID().uuidString.prefix(8))"
        let server = try XCTUnwrap(TestServer(login: login, folder: folder), "PHOTOS_UITEST_LOGIN is not a login link")
        addTeardownBlock { try? await server.removeFolder() }
        _ = try await server.uploadPhotos(2, prefix: "grid-action")
        app.launch()
        waitForTimeline()
        // Only on the test's own photos, never on anything else of the library: they are the newest, under "Today".
        XCTAssertTrue(app.staticTexts["Today"].firstMatch.waitForExistence(timeout: Self.wait), "The uploaded photos did not arrive")
        guard app.staticTexts["Today"].firstMatch.exists else { return }
        app.buttons["Select"].firstMatch.tap()
        pause(1)
        tiles.element(boundBy: 0).tap()
        pause(1)
        let favorite = app.buttons["Add to favorites"].firstMatch
        // A run that stopped half-way may have left the photo a favourite: start from "not a favourite".
        let leftOver = app.buttons["Remove from favorites"].firstMatch
        if !favorite.waitForExistence(timeout: 3), leftOver.exists {
            leftOver.tap()
            pause(2)
        }
        XCTAssertTrue(favorite.waitForExistence(timeout: 5), "No Add to favorites in the selection bar")
        favorite.tap()
        pause(0.3)
        shot("30-heart-burst")
        pause(2)
        let unfavorite = app.buttons["Remove from favorites"].firstMatch
        if unfavorite.waitForExistence(timeout: 5) { unfavorite.tap() }
        pause(2)
        // The first is still selected: the second as well.
        tiles.element(boundBy: 1).tap()
        pause(1)
        app.buttons["Delete"].firstMatch.tap()
        pause(1.5)
        // The confirmation's button: a "Delete" above the selection bar at the bottom (the popover hides the bar's own
        // button from accessibility while it is open).
        let barTop = app.frame.height * 0.8
        let confirm = app.buttons.matching(identifier: "Delete").allElementsBoundByIndex.filter { $0.frame.maxY < barTop }
        XCTAssertFalse(confirm.isEmpty, "No confirmation")
        confirm.min { $0.frame.minY < $1.frame.minY }?.tap()
        pause(0.35)
        shot("31-delete-collapsing")
        pause(2)
        shot("32-deleted")
        let undo = app.buttons["Undo"].firstMatch
        if undo.waitForExistence(timeout: 8) {
            undo.tap()
            pause(8)
            shot("33-undone")
        }
    }
}
