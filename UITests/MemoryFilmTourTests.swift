// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import XCTest

#if os(iOS)
    /// Memory films, their video export and the year in review on an iPhone, against a test server (SPEC §15.1; see
    /// docs/TESTING.md, "UI smoke tests").
    ///
    /// Same requirements as `SmokeTests` (`PHOTOS_UITEST_LOGIN`, a Debug build with a bundle id of your own). Every step is
    /// attached as a screenshot; with `PHOTOS_UITEST_SHOTS=<directory>` the screenshots and the accessibility tree of each
    /// step are also written there. Nothing on the server changes (the exported video is not saved anywhere).
    @MainActor
    final class MemoryFilmTourTests: XCTestCase {
        static let wait: TimeInterval = 60

        var app: XCUIApplication!
        private var shotsDirectory: URL?

        override func setUp() async throws {
            continueAfterFailure = true
            let environment = ProcessInfo.processInfo.environment
            guard let login = environment["PHOTOS_UITEST_LOGIN"], !login.isEmpty else {
                throw XCTSkip("Set PHOTOS_UITEST_LOGIN to a login link of a test server to run the UI tests.")
            }
            let runner = Bundle.main.bundleIdentifier ?? ""
            try XCTSkipIf(
                runner.hasPrefix(SmokeTests.officialBundleId + ".uitests"),
                "Build the UI tests with a bundle id of your own (PHOTOS_BUNDLE_ID), not \(SmokeTests.officialBundleId).")
            if let path = environment["PHOTOS_UITEST_SHOTS"], !path.isEmpty {
                shotsDirectory = URL(fileURLWithPath: path)
                try? FileManager.default.createDirectory(at: URL(fileURLWithPath: path), withIntermediateDirectories: true)
            }
            app = XCUIApplication()
            app.launchEnvironment["PHOTOS_DEBUG_LOGIN"] = login
            app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            app.launch()
            XCTAssertTrue(
                app.collectionViews.cells.firstMatch.waitForExistence(timeout: Self.wait), "No photo appeared in the timeline")
        }

        override func tearDown() async throws {
            app?.terminate()
            app = nil
        }

        private func shot(_ name: String) {
            let screenshot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            guard let shotsDirectory else { return }
            try? screenshot.pngRepresentation.write(to: shotsDirectory.appending(path: "\(name).png"))
            try? Data(app.debugDescription.utf8).write(to: shotsDirectory.appending(path: "\(name).txt"))
        }

        private func pause(_ seconds: TimeInterval) {
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        }

        private func openMemories() {
            app.open(URL(string: "nextcloudphotos://memories")!)
            XCTAssertTrue(app.navigationBars["Memories"].waitForExistence(timeout: Self.wait), "The Memories screen did not open")
            pause(2)
        }

        /// A memory plays as a film: title card, pictures, controls, scrubbing, and the video export.
        func testAMemoryPlaysAsAFilmAndExportsAsAVideo() {
            openMemories()
            shot("10-memories")
            // A trip if there is one, else any memory.
            let trips = app.staticTexts["Trips"]
            let card: XCUIElement
            if trips.exists {
                app.swipeUp()
                card = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] ', memory,'")).element(boundBy: 0)
            } else {
                card = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] ', memory,'")).firstMatch
            }
            XCTAssertTrue(card.waitForExistence(timeout: 20), "No memory")
            card.tap()
            let play = app.buttons["Play slideshow"].firstMatch
            XCTAssertTrue(play.waitForExistence(timeout: 20), "No Play button")
            shot("11-memory")
            play.tap()
            pause(1.5)
            shot("12-film-title")
            pause(4)
            shot("13-film-first-picture")
            pause(4)
            shot("14-film-later")
            XCUIDevice.shared.orientation = .landscapeLeft
            pause(3)
            shot("14b-film-landscape")
            XCUIDevice.shared.orientation = .portrait
            pause(1)
            // Controls come back with a tap; the film pauses with Pause.
            app.tap()
            let pauseButton = app.buttons["Pause"].firstMatch
            if pauseButton.waitForExistence(timeout: 5) { pauseButton.tap() }
            pause(1)
            shot("15-film-paused-controls")
            let slider = app.sliders.firstMatch
            if slider.exists {
                slider.adjust(toNormalizedSliderPosition: 0.6)
                pause(1.5)
                shot("16-film-scrubbed")
            }
            // The controls fade out a few seconds after the last touch: bring them back first if needed.
            let next = app.buttons["Next"].firstMatch
            if !next.waitForExistence(timeout: 1) { app.tap() }
            XCTAssertTrue(next.waitForExistence(timeout: 5), "No Next button")
            next.tap()
            pause(1)
            shot("17-film-skipped")
            // Export.
            let export = app.buttons["Export video…"].firstMatch
            XCTAssertTrue(export.waitForExistence(timeout: 5), "No export button")
            export.tap()
            let start = app.buttons["Export"].firstMatch
            XCTAssertTrue(start.waitForExistence(timeout: 10), "No export sheet")
            shot("18-export-options")
            start.tap()
            pause(2)
            shot("19-export-progress")
            let ready = app.staticTexts["The video is ready."]
            XCTAssertTrue(ready.waitForExistence(timeout: 240), "The export did not finish")
            shot("20-export-done")
            app.buttons["Done"].firstMatch.tap()
            pause(1)
            app.buttons["Close"].firstMatch.tap()
        }

        /// A trip's film; with `PHOTOS_UITEST_TRIP=<part of its title>` that trip (one with stops far apart flies over the
        /// map between them).
        func testATripFilm() {
            openMemories()
            let wanted = ProcessInfo.processInfo.environment["PHOTOS_UITEST_TRIP"] ?? ""
            let predicate =
                wanted.isEmpty
                ? NSPredicate(format: "label CONTAINS ', memory,' AND NOT (label CONTAINS 'ago,') AND NOT (label CONTAINS 'in review')")
                : NSPredicate(format: "label CONTAINS ', memory,' AND label CONTAINS %@", wanted)
            let trip = app.buttons.matching(predicate).firstMatch
            for _ in 0..<6 where !trip.isHittable { app.swipeUp() }
            XCTAssertTrue(trip.waitForExistence(timeout: 20), "No trip")
            trip.tap()
            let play = app.buttons["Play slideshow"].firstMatch
            XCTAssertTrue(play.waitForExistence(timeout: 20), "No Play button")
            play.tap()
            for step in 0..<14 {
                pause(2.5)
                shot(String(format: "5%@-trip-%02d", step < 10 ? "0" : "1", step))
            }
            app.tap()
            app.buttons["Close"].firstMatch.tap()
        }

        /// The year in review: swipe through the cards.
        func testTheYearInReviewCards() {
            openMemories()
            let year = app.buttons.matching(NSPredicate(format: "label ENDSWITH ' in review'")).firstMatch
            XCTAssertTrue(year.waitForExistence(timeout: 20), "No year in review")
            year.tap()
            pause(4)
            shot("30-review-intro")
            for index in 1..<7 {
                app.swipeLeft()
                pause(2)
                shot(String(format: "3%d-review-card-%02d", min(index, 9), index))
            }
            let film = app.buttons["Play film"].firstMatch
            if film.waitForExistence(timeout: 5) {
                film.tap()
                pause(3)
                shot("41-review-film")
                pause(5)
                shot("42-review-film-later")
                app.tap()
                app.buttons["Close"].firstMatch.tap()
                pause(1)
            }
            let share = app.buttons["Share"].firstMatch
            if share.waitForExistence(timeout: 5) {
                share.tap()
                pause(1)
                shot("40-review-share-menu")
                app.tap()
            }
        }
    }
#endif
