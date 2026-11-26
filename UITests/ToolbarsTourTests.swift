// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import XCTest

#if os(iOS)
    /// The simpler toolbars on iPhone and iPad (SPEC §19.2): three tabs, the Library's filter menu with its chips, the
    /// account button with Settings and Upload, and the Collections tab's "+". Same requirements as `PhoneTourTests`;
    /// with `PHOTOS_UITEST_SHOTS=<directory>` the screenshots are written there. Nothing on the server changes.
    @MainActor
    final class ToolbarsTourTests: XCTestCase {
        static let wait: TimeInterval = 90

        var app: XCUIApplication!
        private var shotsDirectory: URL?

        override func setUp() async throws {
            continueAfterFailure = true
            let environment = ProcessInfo.processInfo.environment
            guard let login = environment["PHOTOS_UITEST_LOGIN"], !login.isEmpty else {
                throw XCTSkip("Set PHOTOS_UITEST_LOGIN to a login link of a test server to run the UI tests.")
            }
            if let path = environment["PHOTOS_UITEST_SHOTS"], !path.isEmpty {
                shotsDirectory = URL(fileURLWithPath: path)
                try? FileManager.default.createDirectory(at: URL(fileURLWithPath: path), withIntermediateDirectories: true)
            }
            app = XCUIApplication()
            app.launchEnvironment["PHOTOS_DEBUG_LOGIN"] = login
            app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        }

        override func tearDown() async throws {
            app?.terminate()
            app = nil
        }

        private var idiom: String { UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone" }

        private func shot(_ name: String) {
            let screenshot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            guard let shotsDirectory else { return }
            try? screenshot.pngRepresentation.write(to: shotsDirectory.appending(path: "\(idiom)-\(name).png"))
            try? Data(app.debugDescription.utf8).write(to: shotsDirectory.appending(path: "\(idiom)-\(name).txt"))
        }

        private func pause(_ seconds: TimeInterval) {
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        }

        private func waitForLibrary() {
            XCTAssertTrue(app.accountMenu.waitForExistence(timeout: Self.wait), "No account button in the Library")
            XCTAssertTrue(app.collectionViews.cells.firstMatch.waitForExistence(timeout: Self.wait), "No photos")
            pause(3)
        }

        /// The Library's top bar: filter menu, Select, account button; three tabs, no Settings tab.
        func testLibraryTopBarAndTabs() {
            app.launch()
            waitForLibrary()
            shot("01-library")
            XCTAssertTrue(app.buttons["library-filter"].firstMatch.exists, "No filter menu")
            XCTAssertTrue(app.buttons["Select"].firstMatch.exists, "No Select")
            XCTAssertFalse(app.buttons["Upload"].firstMatch.exists, "Upload is still in the toolbar")
            if idiom == "iphone" {
                for tab in ["Library", "Collections", "Search"] {
                    XCTAssertTrue(app.tabBars.buttons[tab].firstMatch.exists, "No \(tab) tab")
                }
                XCTAssertFalse(app.tabBars.buttons["Settings"].firstMatch.exists, "Settings is still a tab")
            }
            app.buttons["library-filter"].firstMatch.tap()
            pause(1.5)
            shot("02-filter-menu")
            app.buttons["Favorites"].firstMatch.tap()
            pause(3)
            shot("03-favorites-chip")
            let chip = app.buttons["Remove filter Favorites"].firstMatch
            XCTAssertTrue(chip.waitForExistence(timeout: 5), "No Favorites chip under the title")
            chip.tap()
            pause(2)
            XCTAssertFalse(chip.exists, "The chip did not clear the filter")
            shot("04-chip-cleared")
        }

        /// The account menu: name and server, Upload, Settings; Settings opens as a sheet.
        func testAccountMenuAndSettings() {
            app.launch()
            waitForLibrary()
            app.accountMenu.tap()
            pause(1.5)
            shot("10-account-menu")
            XCTAssertTrue(app.buttons["Upload"].firstMatch.exists, "No Upload in the account menu")
            app.buttons["Upload"].firstMatch.tap()
            pause(1.5)
            shot("11-account-upload")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
            pause(1)
            app.openSettings()
            pause(1.5)
            shot("12-settings-sheet")
            app.buttons["settings-done"].firstMatch.tap()
            pause(1.5)
            XCTAssertTrue(app.accountMenu.waitForExistence(timeout: 5), "Settings did not close")
        }

        /// The Collections tab's top bar: "+" (New album, Upload) and the account button (iPhone).
        func testCollectionsAddMenu() throws {
            try XCTSkipIf(idiom != "iphone", "The Collections tab is the iPhone's.")
            app.launch()
            waitForLibrary()
            app.tabBars.buttons["Collections"].firstMatch.tap()
            pause(2)
            shot("20-collections")
            let add = app.buttons["collections-add"].firstMatch
            XCTAssertTrue(add.waitForExistence(timeout: 5), "No + in Collections")
            add.tap()
            pause(1.5)
            shot("21-collections-add")
        }
    }
#endif
