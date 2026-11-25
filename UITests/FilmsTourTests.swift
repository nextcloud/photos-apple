// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import XCTest

#if os(iOS)
    /// Round 6 films on an iPhone (SPEC §16.6): a memory film in every style, SharePlay without a FaceTime call, the
    /// export's style note, and "Through the years" in Memories (without Recognize on the server it says what is needed).
    /// Same requirements as `SmokeTests`; with `PHOTOS_UITEST_SHOTS=<directory>` the screenshots are written there.
    @MainActor
    final class FilmsTourTests: XCTestCase {
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

        private func showControls() {
            if !app.buttons["Style"].waitForExistence(timeout: 1) || !app.buttons["Style"].isHittable { app.tap() }
            _ = app.buttons["Style"].waitForExistence(timeout: 5)
        }

        func testAMemoryFilmInEveryStyleAndSharePlay() {
            app.open(URL(string: "nextcloudphotos://memories")!)
            XCTAssertTrue(app.navigationBars["Memories"].waitForExistence(timeout: Self.wait), "The Memories screen did not open")
            pause(3)
            // Through the years: the row explains what it needs, or lists the named people.
            for _ in 0..<20 where !app.staticTexts["Through the years"].isHittable { app.swipeUp() }
            pause(1)
            shot("20-memories-through-the-years")
            app.open(URL(string: "nextcloudphotos://memories")!)
            pause(2)
            let card = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] ', memory,'")).firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 20), "No memory")
            card.tap()
            let play = app.buttons["Play slideshow"].firstMatch
            XCTAssertTrue(play.waitForExistence(timeout: 20), "No Play button")
            play.tap()
            pause(6)
            shot("21-film-cinematic")
            for (index, style) in ["Super 8", "Black & White", "Upbeat", "Calm"].enumerated() {
                // A short memory may have ended: from the start again.
                let again = app.buttons["Play Again"].firstMatch
                if again.exists { again.tap() }
                showControls()
                app.buttons["Style"].firstMatch.tap()
                let item = app.buttons[style].firstMatch
                XCTAssertTrue(item.waitForExistence(timeout: 5), "No style \(style)")
                if index == 0 { shot("22-style-menu") }
                item.tap()
                pause(4)
                shot(
                    "2\(index + 3)-film-\(style.lowercased().replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "&", with: "and"))"
                )
            }
            // SharePlay without a FaceTime call: what is needed.
            if app.buttons["Play Again"].exists { app.buttons["Play Again"].firstMatch.tap() }
            showControls()
            app.buttons["SharePlay"].firstMatch.tap()
            pause(3)
            shot("27-shareplay-without-call")
            let ok = app.alerts.buttons.firstMatch
            if ok.waitForExistence(timeout: 5) { ok.tap() }
            // The export says which style the video is made in.
            showControls()
            app.buttons["Export video…"].firstMatch.tap()
            XCTAssertTrue(app.buttons["Export"].firstMatch.waitForExistence(timeout: 10), "No export sheet")
            shot("28-export-style-note")
            app.buttons["Done"].firstMatch.tap()
            pause(1)
            showControls()
            app.buttons["Close"].firstMatch.tap()
        }
    }
#endif
