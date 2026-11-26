// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import XCTest

#if os(iOS) || os(visionOS)
    /// App Store screenshots (SPEC §20.6), made from the real app against a test server with the sample library, so
    /// nothing in them is staged. `scripts/app-store-screenshots.sh` runs them on the device sizes App Store Connect
    /// asks for (iPhone 6.9", iPad 13", Vision Pro), with a clean status bar, and collects the images.
    ///
    /// `test0WarmUp` makes no screenshot: it fills the caches first. Each other test is one screenshot, reached by a link (`nextcloudphotos://…`, SPEC §4.8) where there is one, so that the
    /// set does not depend on how the navigation looks. Written as `<PHOTOS_UITEST_SHOT_PREFIX><n>-<name>.png` to
    /// `PHOTOS_UITEST_SHOTS`. Needs `PHOTOS_UITEST_LOGIN`; nothing on the server is changed.
    @MainActor
    final class AppStoreScreenshots: XCTestCase {
        var app: XCUIApplication!

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
            app = XCUIApplication()
            app.launchEnvironment["PHOTOS_DEBUG_LOGIN"] = login
            let language = environment["PHOTOS_UITEST_LANGUAGE"] ?? "en"
            let locale = environment["PHOTOS_UITEST_LOCALE"] ?? "en_US"
            app.launchArguments += ["-AppleLanguages", "(\(language))", "-AppleLocale", locale]
            app.launch()
        }

        override func tearDown() async throws {
            app?.terminate()
            app = nil
        }

        var tiles: XCUIElementQuery { app.collectionViews.cells }

        func pause(_ seconds: TimeInterval) {
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        }

        func waitForTimeline() {
            XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 240), "No photos in the timeline")
            // Until the first sync of the fresh install has settled and the first screen's previews are in.
            pause(15)
        }

        func shot(_ name: String) {
            let environment = ProcessInfo.processInfo.environment
            let prefix = environment["PHOTOS_UITEST_SHOT_PREFIX"] ?? ""
            let screenshot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = prefix + name
            attachment.lifetime = .keepAlways
            add(attachment)
            guard let folder = environment["PHOTOS_UITEST_SHOTS"], !folder.isEmpty else { return }
            let directory = URL(fileURLWithPath: folder)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: directory.appending(path: "\(prefix)\(name).png"))
        }

        /// Opens a link of the app; the system asks once before a link opens an app.
        func open(_ route: String) throws {
            app.open(try XCTUnwrap(URL(string: "nextcloudphotos://\(route)")))
            #if os(iOS)
                let confirm = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"].firstMatch
                if confirm.waitForExistence(timeout: 4) { confirm.tap() }
            #endif
            pause(6)
        }

        /// The tile the viewer shot opens (`PHOTOS_UITEST_SHOT_PHOTO`, default 3): one that looks good full screen.
        var viewerTile: Int {
            Int(ProcessInfo.processInfo.environment["PHOTOS_UITEST_SHOT_PHOTO"] ?? "") ?? 3
        }

        /// Runs first: the first sync and the previews of the screens shot below, so that no picture is still a blur.
        func test0WarmUp() throws {
            waitForTimeline()
            let grid = app.collectionViews.firstMatch
            for _ in 0..<3 {
                grid.swipeUp(velocity: .slow)
                pause(4)
            }
            for _ in 0..<6 { grid.swipeDown(velocity: .fast) }
            for route in ["memories", "albums", "map"] { try open(route) }
            pause(10)
        }

        func test1Library() {
            waitForTimeline()
            // The memory cards and the last tiles of a fresh install.
            pause(15)
            shot("1-library")
        }

        func test2Viewer() {
            waitForTimeline()
            tiles.element(boundBy: viewerTile).tap()
            XCTAssertTrue(app.buttons["Close"].firstMatch.waitForExistence(timeout: 20), "The viewer did not open")
            // Until the full-size preview is in and the controls have settled.
            pause(5)
            shot("2-viewer")
        }

        func test3Memories() throws {
            waitForTimeline()
            try open("memories")
            shot("3-memories")
        }

        func test4Albums() throws {
            waitForTimeline()
            try open("albums")
            shot("4-albums")
        }

        func test5Map() throws {
            waitForTimeline()
            try open("map")
            // Map tiles come from Apple Maps.
            pause(6)
            shot("5-map")
        }

        func test6Search() throws {
            waitForTimeline()
            // By link: a restored screen can hide the tab bar.
            try open("search")
            let field = app.searchFields.firstMatch
            if !field.waitForExistence(timeout: 5) {
                let tab = app.tabBars.buttons["Search"].firstMatch
                if tab.waitForExistence(timeout: 5) { tab.tap() } else { app.buttons["Search"].firstMatch.tap() }
            }
            let text = ProcessInfo.processInfo.environment["PHOTOS_UITEST_SHOT_SEARCH"] ?? "Lisbon"
            // A restored Search screen can keep its field hidden in the navigation bar: pulling down shows it; a recent
            // search with the same text does as well.
            if !field.waitForExistence(timeout: 5) {
                app.collectionViews.firstMatch.swipeDown()
                pause(1)
            }
            if field.waitForExistence(timeout: 5) {
                field.tap()
                field.typeText(text)
            } else if app.buttons[text].firstMatch.exists {
                app.buttons[text].firstMatch.tap()
            } else {
                add(XCTAttachment(string: app.debugDescription))
                return XCTFail("No search field")
            }
            pause(4)
            // The results, not the keyboard.
            #if os(iOS)
                if app.keyboards.firstMatch.exists { app.keyboards.buttons["search"].firstMatch.tap() }
            #endif
            // The results' previews.
            pause(12)
            shot("6-search")
        }

        func test7Backup() throws {
            waitForTimeline()
            try open("backup")
            shot("7-backup")
        }
    }
#endif
