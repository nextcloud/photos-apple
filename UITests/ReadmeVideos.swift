// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import XCTest

#if os(iOS)
    /// The README's short videos (`scripts/readme-videos.sh`): the interactions that show the app best, played by the test
    /// while the script records the simulator's screen (`simctl io recordVideo`). Needs `PHOTOS_UITEST_LOGIN`.
    ///
    /// Each test does its part between two signals in `PHOTOS_UITEST_VIDEOS` (a folder the script watches): it writes
    /// `<name>.start` when the app is ready and waits for `<name>.recording`, which the script writes once it records; after
    /// the interaction it writes `<name>.stop` and waits for `<name>.done`. Without the folder the tests just play.
    ///
    /// Nothing on the server changes: the editor is left without Done (the app is ended, no recipe is written).
    @MainActor
    final class ReadmeVideos: XCTestCase {
        var app: XCUIApplication!

        override func setUp() async throws {
            continueAfterFailure = true
            guard let login = environment("PHOTOS_UITEST_LOGIN") else {
                throw XCTSkip("Set PHOTOS_UITEST_LOGIN to a login link of a test server to run the UI tests.")
            }
            try XCTSkipIf(
                (Bundle.main.bundleIdentifier ?? "").hasPrefix(SmokeTests.officialBundleId + ".uitests"),
                "Build the UI tests with a bundle id of your own (PHOTOS_BUNDLE_ID), not \(SmokeTests.officialBundleId).")
            app = XCUIApplication()
            app.launchEnvironment["PHOTOS_DEBUG_LOGIN"] = login
            app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            app.launchArguments += ["-albumsSortOrder", "name", "-weeklyPromptsInvitationDismissed", "YES"]
        }

        override func tearDown() async throws {
            // A failure ended the test while recording: the script stops the recorder.
            if let recording, let folder = environment("PHOTOS_UITEST_VIDEOS") {
                FileManager.default.createFile(
                    atPath: URL(fileURLWithPath: folder).appending(path: "\(recording).stop").path, contents: Data())
            }
            app?.terminate()
            app = nil
        }

        /// The video being recorded.
        private var recording: String?

        func environment(_ name: String) -> String? {
            ProcessInfo.processInfo.environment[name].flatMap { $0.isEmpty ? nil : $0 }
        }

        func pause(_ seconds: TimeInterval) {
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        }

        var tiles: XCUIElementQuery { app.collectionViews.cells }

        // MARK: Recording

        /// Plays `body` while the script records the screen.
        func record(_ name: String, _ body: () -> Void) {
            guard let path = environment("PHOTOS_UITEST_VIDEOS") else {
                body()
                return
            }
            let folder = URL(fileURLWithPath: path)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            func signal(_ suffix: String) {
                FileManager.default.createFile(atPath: folder.appending(path: "\(name).\(suffix)").path, contents: Data())
            }
            func wait(for suffix: String) {
                let file = folder.appending(path: "\(name).\(suffix)").path
                let deadline = Date().addingTimeInterval(30)
                while !FileManager.default.fileExists(atPath: file), Date() < deadline { pause(0.2) }
                XCTAssertTrue(FileManager.default.fileExists(atPath: file), "The script did not answer \(name).\(suffix)")
            }
            signal("start")
            recording = name
            wait(for: "recording")
            // The recorder's first frames come a moment after it starts.
            pause(1)
            body()
            pause(0.8)
            signal("stop")
            recording = nil
            wait(for: "done")
        }

        // MARK: Helpers

        func tapButton(_ label: String, timeout: TimeInterval = 10) -> Bool {
            let button = app.buttons[label].firstMatch
            guard button.waitForExistence(timeout: timeout) else { return false }
            button.tap()
            return true
        }

        func waitForTimeline() {
            XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 240), "No photos in the timeline")
            // The previews of the first screens.
            pause(12)
        }

        func level(_ title: String) -> XCUIElement { app.buttons[title].firstMatch }

        /// A card of the level shown in the middle of the screen (a pinch on the whole scroll view would start on the tab
        /// bar).
        func visibleCard() -> XCUIElement {
            let buttons = app.scrollViews["librarySummary"].buttons
            let screen = app.windows.firstMatch.frame
            for index in 0..<min(buttons.count, 16) {
                let frame = buttons.element(boundBy: index).frame
                if frame.minY > screen.height * 0.35, frame.maxY < screen.height * 0.8 { return buttons.element(boundBy: index) }
            }
            return app.scrollViews["librarySummary"]
        }

        /// Opens a photo by its link (`nextcloudphotos://photo/<id>`).
        func openPhoto(_ id: String) {
            guard let url = URL(string: "nextcloudphotos://photo/\(id)") else { return }
            app.open(url)
            let confirm = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"].firstMatch
            if confirm.waitForExistence(timeout: 4) { confirm.tap() }
            XCTAssertTrue(app.buttons["Close"].firstMatch.waitForExistence(timeout: 30), "The viewer did not open")
        }

        // MARK: Videos

        /// Pinching the Library from days out to months and years, into a year's months and back in to its days.
        func testLevels() {
            app.launchArguments += ["-libraryZoomLevel", "days"]
            app.launch()
            XCTAssertTrue(level("Days").waitForExistence(timeout: 240), "No Library")
            if !level("Days").isSelected { level("Days").tap() }
            // The previews of the first screens.
            pause(15)
            record("levels") {
                for (wanted, scale) in [("Months", 0.7), ("Years", 0.7)] {
                    visibleCard().pinch(withScale: scale, velocity: -1.5)
                    pause(2)
                    if !level(wanted).isSelected { level(wanted).tap() }
                    pause(1.5)
                }
                // A year opens its months; a pinch in on them shows the days.
                let year = app.buttons.matching(NSPredicate(format: "label MATCHES %@", "^[0-9]{4}, .*")).element(boundBy: 1)
                if year.waitForExistence(timeout: 5) { year.tap() }
                pause(2)
                visibleCard().pinch(withScale: 1.5, velocity: 1.5)
                pause(2.5)
            }
        }

        /// A memory from the Library's strip: its cover opens it, Play turns it into a film.
        func testMemory() {
            app.launchArguments += ["-libraryZoomLevel", "all"]
            app.launch()
            waitForTimeline()
            let name = environment("PHOTOS_UITEST_VIDEO_MEMORY") ?? "trip"
            let memories = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] 'years ago'", name))
            XCTAssertTrue(memories.firstMatch.waitForExistence(timeout: 30), "No memory in the Library")
            let wanted = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", name)).firstMatch
            let memory = wanted.exists ? wanted : memories.firstMatch
            record("memory") {
                memory.tap()
                pause(2.5)
                if tapButton("Play slideshow", timeout: 5) || tapButton("Play", timeout: 3) {
                    pause(Double(environment("PHOTOS_UITEST_VIDEO_MEMORY_SECONDS") ?? "") ?? 16)
                }
            }
        }

        /// The viewer: a photo from an album, swiped through, zoomed in with a double tap, and swiped down back to its tile.
        func testViewer() {
            app.launchEnvironment["PHOTOS_DEBUG_DESTINATION"] = "albums"
            app.launch()
            let album = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", environment("PHOTOS_UITEST_VIDEO_ALBUM") ?? "Lisbon")
            )
            .firstMatch
            XCTAssertTrue(album.waitForExistence(timeout: 120), "No album")
            pause(6)
            album.tap()
            XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 30), "No photos in the album")
            pause(6)
            record("viewer") {
                tiles.element(boundBy: Int(environment("PHOTOS_UITEST_VIDEO_TILE") ?? "") ?? 0).tap()
                pause(2)
                for _ in 0..<3 {
                    app.swipeLeft(velocity: .default)
                    pause(1.4)
                }
                let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                center.doubleTap()
                pause(1.6)
                center.doubleTap()
                pause(1.2)
                // Swipe down: the photo flies back into its tile.
                center.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
                pause(2)
            }
        }

        /// The editor: presets one after another, then an S curve.
        func testEditor() {
            app.launch()
            waitForTimeline()
            openPhoto(environment("PHOTOS_UITEST_SHOT_EDIT_PHOTO") ?? "2806")
            pause(4)
            record("editor") {
                let buttons = app.buttons.matching(identifier: "Edit").allElementsBoundByIndex
                (buttons.max { $0.frame.minY < $1.frame.minY } ?? app.buttons["Edit"].firstMatch).tap()
                XCTAssertTrue(app.buttons["Done"].firstMatch.waitForExistence(timeout: 30), "The editor did not open")
                pause(2)
                if tapButton("Presets", timeout: 5) {
                    pause(1.5)
                    for preset in ["Vivid", "Warm", "Cool", "Black & White", "Matte", "Warm"] where tapButton(preset, timeout: 2) {
                        pause(1.3)
                    }
                }
                if tapButton("Curves", timeout: 5), UIDevice.current.userInterfaceIdiom == .phone {
                    pause(1.2)
                    // An S curve: the shadows down, the highlights up (the graph's place on an iPhone screen).
                    for (x, y, dy) in [(0.637, 0.771, -0.035), (0.363, 0.897, 0.03)] {
                        let start = app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
                        start.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y + dy)))
                        pause(1.2)
                    }
                }
                pause(1)
                // No Done: the app is ended, nothing is saved.
            }
        }
    }
#endif
