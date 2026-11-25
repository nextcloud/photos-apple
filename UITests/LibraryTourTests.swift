// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import XCTest

/// A tour of the Library's moments, story cards, scrub to peek and range selection (SPEC §16.1), on iPhone and iPad.
///
/// Like `SmokeTests` it needs `PHOTOS_UITEST_LOGIN`. The moments need a library with places (the test library has them);
/// the peek needs a video in the library (any recent one). With `PHOTOS_UITEST_SHOTS` set to a folder, it saves a
/// screenshot of every step there as well as attaching it to the test.
@MainActor
final class LibraryTourTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let login = environment["PHOTOS_UITEST_LOGIN"], !login.isEmpty else {
            throw XCTSkip("Set PHOTOS_UITEST_LOGIN to a login link of a test server to run the UI tests.")
        }
        try XCTSkipIf(
            (Bundle.main.bundleIdentifier ?? "").hasPrefix(SmokeTests.officialBundleId + ".uitests"),
            "Build the UI tests with a bundle id of your own (PHOTOS_BUNDLE_ID).")
        app = XCUIApplication()
        app.launchEnvironment["PHOTOS_DEBUG_LOGIN"] = login
        app.launchArguments += [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-libraryZoomLevel", "all",
            // Playing story cards keep the app from being idle, which slows every query of the other tests.
            "-memoriesStyle", name.contains("StoryCards") ? "stories" : "strip",
            "-showsMoments", "YES",
        ]
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
        if let folder = ProcessInfo.processInfo.environment["PHOTOS_UITEST_SHOTS"], !folder.isEmpty {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
        }
    }

    func waitForTiles() {
        XCTAssertTrue(app.collectionViews.cells.firstMatch.waitForExistence(timeout: 60), "No photos in the timeline")
    }

    /// Swipes the grid (or the days) up until `element` is on screen.
    @discardableResult
    func scroll(to element: XCUIElement, in scrollable: XCUIElement, swipes: Int = 12) -> Bool {
        let screen = app.windows.firstMatch.frame
        func shown() -> Bool {
            // On screen, clear of the bars, the memories and the level picker.
            element.exists && element.frame.minY > screen.height * 0.2 && element.frame.maxY < screen.height * 0.75
        }
        for _ in 0..<swipes {
            if shown() { return true }
            scrollable.swipeUp()
        }
        if !shown() { print(scrollable.debugDescription) }
        return shown()
    }

    /// A moment titled after one of the test library's places.
    var momentTitle: NSPredicate {
        NSPredicate(format: "label CONTAINS 'Lisbon' OR label CONTAINS 'Sintra' OR label CONTAINS 'Kópavogur'")
    }

    func testStoryCardsAndMoments() {
        waitForTiles()
        sleep(3)
        shot("10-story-cards")
        // A tap on the right of the card in front goes on to its next photo.
        let cards = app.buttons.matching(NSPredicate(format: "label MATCHES '.*Photo [0-9]+ of [0-9]+$'"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 10), "No story cards")
        // The card in front: the one at the leading edge.
        var front = cards.firstMatch
        for index in 0..<cards.count where cards.element(boundBy: index).frame.minX < 100 {
            front = cards.element(boundBy: index)
            break
        }
        do {
            let story = front
            let before = story.label
            story.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.4)).tap()
            shot("11-story-next-photo")
            XCTAssertNotEqual(story.label, before, "The tap did not go on to another photo")
            // The classic strip from the card's context menu (it also keeps the playing cards from slowing the queries
            // below down: XCUITest waits for the app to be idle).
            story.press(forDuration: 1.2)
            let strip = app.buttons["Show as strip"].firstMatch
            XCTAssertTrue(strip.waitForExistence(timeout: 5))
            shot("11b-story-menu")
            strip.tap()
            sleep(1)
            shot("11c-strip")
        }

        // The days show the moments' titles above their newest day.
        app.buttons["Days"].firstMatch.tap()
        let summary = app.scrollViews["librarySummary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        let dayMoment = summary.buttons.matching(momentTitle).firstMatch
        XCTAssertTrue(scroll(to: dayMoment, in: summary), "No moment title in the days")
        shot("12-days-with-moments")
        dayMoment.tap()
        sleep(2)
        shot("13-moment-opened-from-days")
        app.navigationBars.buttons.firstMatch.tap()
        sleep(1)

        // All Photos: the title is on the moment's newest day header and opens the moment.
        app.buttons["All Photos"].firstMatch.tap()
        sleep(2)
        let grid = app.collectionViews.firstMatch
        let header = grid.buttons.matching(momentTitle).firstMatch
        XCTAssertTrue(scroll(to: header, in: grid), "No moment title on a day header")
        shot("14-grid-moment-header")
        header.tap()
        sleep(2)
        shot("15-moment-opened-from-header")
        XCTAssertTrue(app.buttons["Play slideshow"].firstMatch.waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
    }

    /// Screenshots of the days and the grid while scrolling through the library (looking, no assertions).
    func testScrollShots() {
        waitForTiles()
        app.buttons["Days"].firstMatch.tap()
        sleep(2)
        for step in 0..<8 {
            app.swipeUp(velocity: .fast)
            sleep(1)
            shot("40-days-\(step)")
        }
    }

    /// Hold a video's tile, then slide across it: frames in place, nothing opens. Screenshots during the hold come from
    /// outside (`xcrun simctl io … screenshot`); the test holds the finger at the end for that.
    func testScrubToPeekAndContextMenu() {
        waitForTiles()
        let video = app.collectionViews.cells.matching(NSPredicate(format: "label BEGINSWITH 'Video'")).firstMatch
        XCTAssertTrue(scroll(to: video, in: app.collectionViews.firstMatch, swipes: 10), "No video in the library")
        shot("20-before-peek")
        let start = video.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        let end = video.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        start.press(forDuration: 0.3, thenDragTo: end, withVelocity: 150, thenHoldForDuration: 4)
        sleep(1)
        shot("21-after-peek")
        // Nothing opened: the grid is still there with its Select button.
        XCTAssertTrue(app.buttons["Select"].firstMatch.exists)
        // Held still, the context menu comes as before.
        video.press(forDuration: 1.5)
        sleep(1)
        shot("22-context-menu")
        XCTAssertTrue(app.buttons["Open"].firstMatch.waitForExistence(timeout: 5), "No context menu")
    }

    /// In the selection mode, a finger sliding sideways selects the range from where it started.
    func testRangeSelection() {
        waitForTiles()
        app.buttons["Select"].firstMatch.tap()
        sleep(1)
        let cells = app.collectionViews.firstMatch.cells
        // A cell in the middle of the screen, and one three tiles on and two rows down.
        var first: XCUIElement?
        for index in 0..<min(cells.count, 40) {
            let cell = cells.element(boundBy: index)
            if cell.frame.minY > 500, cell.frame.minX < 10 {
                first = cell
                break
            }
        }
        guard let first else { return XCTFail("No cell to start on") }
        let side = first.frame.width
        let start = first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: side * 3, dy: side * 2))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: 400, thenHoldForDuration: 0.5)
        sleep(1)
        shot("31-range-selected")
        let title = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH ' selected'")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Nothing selected")
    }
}
