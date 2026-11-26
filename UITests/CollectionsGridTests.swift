// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import XCTest

#if os(iOS)
    /// Grids opened from the Collections tab on iPhone must leave the app idle: a place pushed there (Favorites, a
    /// folder with photos) once re-rendered without end at full CPU, and the app no longer answered (STATUS §20.1).
    /// Each test opens a grid from Collections and taps a photo: the viewer has to open within a few seconds, which it
    /// cannot while the main thread is stuck in a layout loop. Same requirements as `PhoneTourTests`; nothing on the
    /// server changes.
    @MainActor
    final class CollectionsGridTests: XCTestCase {
        static let wait: TimeInterval = 60
        /// How long a tap on a tile may take to show the viewer, the wait for the app to be idle included.
        static let answer: TimeInterval = 15

        var app: XCUIApplication!
        private var shotsDirectory: URL?

        override func setUp() async throws {
            continueAfterFailure = false
            let environment = ProcessInfo.processInfo.environment
            guard let login = environment["PHOTOS_UITEST_LOGIN"], !login.isEmpty else {
                throw XCTSkip("Set PHOTOS_UITEST_LOGIN to a login link of a test server to run the UI tests.")
            }
            try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone, "The Collections tab is the iPhone's.")
            if let path = environment["PHOTOS_UITEST_SHOTS"], !path.isEmpty {
                shotsDirectory = URL(fileURLWithPath: path)
                try? FileManager.default.createDirectory(at: URL(fileURLWithPath: path), withIntermediateDirectories: true)
            }
            app = XCUIApplication()
            app.launchEnvironment["PHOTOS_DEBUG_LOGIN"] = login
            // From the Library, whatever screen the last run left (the app restores it).
            app.launchEnvironment["PHOTOS_DEBUG_DESTINATION"] = "library"
            app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            app.launch()
            XCTAssertTrue(app.collectionViews.cells.firstMatch.waitForExistence(timeout: Self.wait), "No photo in the timeline")
            let tab = app.tabBars.buttons["Collections"].firstMatch
            XCTAssertTrue(tab.waitForExistence(timeout: 10), "No Collections tab")
            tab.tap()
            XCTAssertTrue(app.buttons["collections-shelf-albums"].firstMatch.waitForExistence(timeout: 10), "No Albums shelf")
        }

        override func tearDown() async throws {
            app?.terminate()
            app = nil
        }

        // MARK: Helpers

        private func shot(_ name: String) {
            let screenshot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            guard let shotsDirectory else { return }
            try? screenshot.pngRepresentation.write(to: shotsDirectory.appending(path: "\(name).png"))
        }

        private func pause(_ seconds: TimeInterval) {
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        }

        /// Scrolls the overview until `element` can be tapped.
        private func reveal(_ element: XCUIElement) {
            for _ in 0..<8 where !(element.exists && element.isHittable) {
                app.swipeUp(velocity: .slow)
                pause(0.5)
            }
        }

        /// The grid on screen answers: a tap on its first photo opens the viewer in time, and the viewer closes again.
        private func assertGridAnswers(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
            let tile = app.collectionViews.cells.firstMatch
            XCTAssertTrue(tile.waitForExistence(timeout: 30), "\(name): no photo in the grid", file: file, line: line)
            // Long enough for a loop to start (it began as soon as the grid had its photos).
            pause(3)
            shot("collections-grid-\(name)")
            let start = Date()
            tile.tap()
            let info = app.buttons["Info"].firstMatch
            XCTAssertTrue(info.waitForExistence(timeout: Self.answer), "\(name): the viewer did not open", file: file, line: line)
            let took = Date().timeIntervalSince(start)
            XCTAssertLessThan(took, Self.answer, "\(name): the app took \(Int(took)) s to answer a tap", file: file, line: line)
            let window = app.windows.firstMatch
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
            XCTAssertTrue(
                info.waitForNonExistence(timeout: Self.answer), "\(name): the viewer did not close", file: file, line: line)
        }

        // MARK: Tests

        /// Folders, then into a folder until one shows photos (on Nextcloud 33/34 the root has some; on the default
        /// test server they are in `Photos/Test library/…`).
        func testFolderGrid() {
            let folders = app.buttons["Folders"].firstMatch
            reveal(folders)
            folders.tap()
            let preferred = ["Photos", "Test library", "Everyday"]
            for _ in 0..<4 {
                if app.collectionViews.cells.firstMatch.waitForExistence(timeout: 8) { break }
                let tiles = app.buttons.matching(NSPredicate(format: "label ENDSWITH ', folder'"))
                guard tiles.firstMatch.waitForExistence(timeout: 10) else { break }
                let named = preferred.lazy.map { tiles.matching(NSPredicate(format: "label BEGINSWITH %@", "\($0),")).firstMatch }
                (named.first { $0.exists } ?? tiles.firstMatch).tap()
            }
            assertGridAnswers("folder")
        }

        /// The Favorites card opens Favorites in the Collections stack (SPEC §19.1: a pinned place, also the Library's
        /// filter). A server without favourites shows the empty state: then Back must answer.
        func testFavoritesGrid() {
            let favorites = app.scrollViews["Albums"].buttons.matching(NSPredicate(format: "label BEGINSWITH 'Favorites'")).firstMatch
            XCTAssertTrue(favorites.waitForExistence(timeout: 10), "No Favorites card")
            favorites.tap()
            XCTAssertTrue(app.tabBars.buttons["Collections"].firstMatch.isSelected, "Favorites left the Collections tab")
            if app.collectionViews.cells.firstMatch.waitForExistence(timeout: 20) {
                assertGridAnswers("favorites")
            } else {
                shot("collections-grid-favorites-empty")
            }
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(
                app.buttons["collections-shelf-albums"].firstMatch.waitForExistence(timeout: Self.answer),
                "Back from Favorites did not return to Collections")
        }

        /// An album from its cover (the second card of the Albums shelf; the first is Favorites).
        func testAlbumGrid() {
            let albums = app.scrollViews["Albums"].firstMatch
            XCTAssertTrue(albums.waitForExistence(timeout: 10), "No Albums shelf")
            albums.coordinate(withNormalizedOffset: CGVector(dx: 0.63, dy: 0.5)).tap()
            assertGridAnswers("album")
        }

        /// A memory from the Memories shelf.
        func testMemoryGrid() {
            // The shelf's covers scroll sideways, so a card is tapped by its place in the shelf once the shelf is in view.
            let shelf = app.scrollViews["Memories"].firstMatch
            guard shelf.waitForExistence(timeout: 20), shelf.buttons.firstMatch.waitForExistence(timeout: 20) else {
                shot("collections-grid-memory-missing")
                XCTFail("No memory on the Memories shelf")
                return
            }
            let screen = app.windows.firstMatch.frame
            for _ in 0..<4 where shelf.frame.maxY > screen.maxY - 120 {
                app.swipeUp(velocity: .slow)
                pause(0.5)
            }
            shelf.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
            assertGridAnswers("memory")
        }
    }
#endif
