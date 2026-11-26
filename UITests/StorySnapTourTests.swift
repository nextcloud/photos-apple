// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import XCTest

/// The Library's memory stories snap to a card after a swipe on iPhone and iPad (SPEC §20.1) — without a scroll target
/// behaviour, which trapped SwiftUI inside the UIKit-hosted grid header (STATUS §M8). Swipes fast and slow through the
/// cards, back and forth, while an accessibility client (this test) reads the app, as in the runs that used to crash.
/// Same requirements as `SmokeTests` (`PHOTOS_UITEST_LOGIN`); shots with `PHOTOS_UITEST_SHOTS`/`PHOTOS_UITEST_SHOT_PREFIX`.
@MainActor
final class StorySnapTourTests: XCTestCase {
    static let wait: TimeInterval = 60
    var app: XCUIApplication!

    var prefix: String { ProcessInfo.processInfo.environment["PHOTOS_UITEST_SHOT_PREFIX"] ?? "stories" }

    override func setUp() async throws {
        continueAfterFailure = true
        let environment = ProcessInfo.processInfo.environment
        guard let login = environment["PHOTOS_UITEST_LOGIN"], !login.isEmpty else {
            throw XCTSkip("Set PHOTOS_UITEST_LOGIN to a login link of a test server to run the UI tests.")
        }
        #if !os(iOS)
            throw XCTSkip("The tour is written for iPhone and iPad.")
        #endif
        app = XCUIApplication()
        app.launchEnvironment["PHOTOS_DEBUG_LOGIN"] = login
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
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

    /// The story cards ("…, Photo 1 of 6").
    var cards: XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] ', Photo ' AND label CONTAINS[c] ' of '"))
    }

    func waitForStories() {
        let library = app.tabBars.buttons["Library"].firstMatch
        _ = library.waitForExistence(timeout: 20)
        pause(2)
        if let link = URL(string: "nextcloudphotos://library") { app.open(link) }
        pause(1)
        if library.exists { library.tap() }
        // A new login syncs the library first: the stories come after it.
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 3 * Self.wait), "No memory story appeared in the Library")
        pause(2)
    }

    /// The leading edges of the cards on screen, in points from the window's leading edge.
    func cardEdges() -> [CGFloat] {
        let width = app.windows.firstMatch.frame.width
        return cards.allElementsBoundByIndex.map(\.frame).filter { $0.maxX > 0 && $0.minX < width }.map(\.minX).sorted()
    }

    /// A card rests at the strip's leading margin (12 pt) after a swipe has settled, as the first card does at the start.
    func assertSnapped(_ what: String, file: StaticString = #filePath, line: UInt = #line) {
        pause(1.5)
        let edges = cardEdges()
        let snapped = edges.contains { $0 >= 9 && $0 <= 15 }
        XCTAssertTrue(snapped, "\(what): no card at the leading edge, cards at \(edges)", file: file, line: line)
        XCTAssertEqual(app.state, .runningForeground, "\(what): the app stopped", file: file, line: line)
    }

    func testStoriesSnapAfterSwipes() {
        app.launch()
        waitForStories()
        guard let first = cards.allElementsBoundByIndex.first else { return }
        let strip = first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let firstEdge = first.frame.minX
        shot("01-start")
        // A slow, short drag (under a third of a card) falls back; a fling goes on by one card.
        strip.press(forDuration: 0.05, thenDragTo: strip.withOffset(CGVector(dx: -60, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0)
        assertSnapped("short drag")
        XCTAssertEqual(cardEdges().first.map { abs($0 - firstEdge) < 2 } ?? false, true, "A short drag moved the cards on")
        strip.press(forDuration: 0.05, thenDragTo: strip.withOffset(CGVector(dx: -160, dy: 0)), withVelocity: .fast, thenHoldForDuration: 0)
        assertSnapped("fling forward")
        shot("02-after-fling")
        func drag(_ dx: CGFloat, _ velocity: XCUIGestureVelocity) {
            strip.press(
                forDuration: 0.05, thenDragTo: strip.withOffset(CGVector(dx: dx, dy: 0)), withVelocity: velocity, thenHoldForDuration: 0)
        }
        for round in 0..<3 {
            drag(-220, .fast)
            assertSnapped("swipe left \(round)")
            drag(-200, .slow)
            assertSnapped("slow swipe left \(round)")
            drag(220, .fast)
            assertSnapped("swipe right \(round)")
        }
        shot("03-after-swipes")
        // The grid under the strip scrolls as before, and the strip comes back unharmed.
        let grid = app.collectionViews.firstMatch
        grid.swipeUp(velocity: .fast)
        grid.swipeDown(velocity: .fast)
        grid.swipeDown(velocity: .fast)
        pause(2)
        XCTAssertEqual(app.state, .runningForeground, "The app stopped after scrolling the grid")
        shot("04-back")
    }
}
