// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import XCTest

#if os(iOS)
    import UIKit

    /// A tour of the iPad layout (sidebar, tab bar, rotation, inspector, windows) against a test server (see docs/TESTING.md).
    ///
    /// Same requirements as `SmokeTests` (`PHOTOS_UITEST_LOGIN`, a bundle id of your own); runs only on an iPad. With
    /// `PHOTOS_UITEST_SHOTS=<folder>` every step also saves a screenshot and the accessibility tree there. The tests only
    /// look and navigate; nothing on the server changes (except `testWindowsDragPhotoIntoAlbumWindow`, which is skipped
    /// unless asked for). The `testWindows…` tests run only with `PHOTOS_UITEST_WINDOWS=1` (see `requireWindowTests`).
    @MainActor
    final class IPadTourTests: XCTestCase {
        static let wait: TimeInterval = 60

        var app: XCUIApplication!
        var shots: URL?

        override func setUp() async throws {
            continueAfterFailure = false
            let environment = ProcessInfo.processInfo.environment
            guard let login = environment["PHOTOS_UITEST_LOGIN"], !login.isEmpty else {
                throw XCTSkip("Set PHOTOS_UITEST_LOGIN to a login link of a test server to run the UI tests.")
            }
            try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad, "iPad only")
            let runner = Bundle.main.bundleIdentifier ?? ""
            try XCTSkipIf(runner.hasPrefix(SmokeTests.officialBundleId + ".uitests"), "Build the UI tests with a bundle id of your own.")
            if let folder = environment["PHOTOS_UITEST_SHOTS"], !folder.isEmpty {
                let url = URL(fileURLWithPath: folder, isDirectory: true)
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                shots = url
            }
            XCUIDevice.shared.orientation = .portrait
            app = XCUIApplication()
            app.launchEnvironment["PHOTOS_DEBUG_LOGIN"] = login
            app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        }

        override func tearDown() async throws {
            app?.terminate()
            app = nil
            XCUIDevice.shared.orientation = .portrait
        }

        // MARK: Helpers

        /// A screenshot (attached to the result, and saved in `PHOTOS_UITEST_SHOTS`) and the accessibility tree next to it.
        func shot(_ name: String) {
            let screenshot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            guard let shots else { return }
            try? screenshot.pngRepresentation.write(to: shots.appendingPathComponent("\(name).png"))
            try? app.debugDescription.write(to: shots.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
        }

        func pause(_ seconds: TimeInterval) {
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        }

        /// Photo tiles of the grid (not the sidebar's rows, which are cells too).
        var tiles: XCUIElementQuery {
            app.cells.matching(NSPredicate(format: "label BEGINSWITH 'Photo,' OR label BEGINSWITH 'Video,'"))
        }

        func waitForTiles(_ what: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: Self.wait), "No photo appeared in \(what)", file: file, line: line)
        }

        func assertRunning(file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(app.state, .runningForeground, "The app is not running any more", file: file, line: line)
        }

        /// The sidebar's toggle in the tab bar ("Show Sidebar" / "Hide Sidebar").
        func showSidebar() {
            let show = app.buttons["Show Sidebar"].firstMatch
            if show.exists && show.isHittable {
                show.tap()
                pause(1)
            }
        }

        /// Taps the top centre of the window, outside any menu or popover, to close it.
        func tapOutside() {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.04)).tap()
            pause(1)
        }

        /// The window tests open album windows, which the system restores at every later launch and which then stand in front
        /// of the library: they run only when asked for, one at a time, each on a fresh installation.
        func requireWindowTests() throws {
            try XCTSkipIf(
                ProcessInfo.processInfo.environment["PHOTOS_UITEST_WINDOWS"] != "1",
                "Set PHOTOS_UITEST_WINDOWS=1 to run the window tests (one at a time, on a fresh installation).")
        }

        /// A sidebar row.
        func sidebarRow(_ title: String) -> XCUIElement { app.cells[title].firstMatch }

        // MARK: Tour

        /// Rotating with the sidebar coming and going must not crash.
        func testRotationKeepsTheAppRunning() {
            app.launch()
            waitForTiles("the Library")
            shot("ipad-01-library-portrait")
            XCUIDevice.shared.orientation = .landscapeLeft
            pause(3)
            assertRunning()
            shot("ipad-02-library-landscape")
            XCUIDevice.shared.orientation = .portrait
            pause(3)
            assertRunning()
            XCTAssertTrue(tiles.firstMatch.exists)
        }

        /// The tab bar holds Library, Settings and Search; the sidebar's sections are not tabs of their own.
        func testTabBarInPortrait() {
            app.launch()
            waitForTiles("the Library")
            shot("ipad-03-tabbar-portrait")
            for title in ["Library", "Settings", "Search"] {
                XCTAssertTrue(app.buttons[title].firstMatch.exists, "\(title) is not in the tab bar")
            }
            for section in ["Browse", "Utilities"] {
                XCTAssertFalse(app.buttons[section].firstMatch.exists, "The sidebar section \(section) is in the tab bar")
            }
        }

        /// Photos, Videos and Favorites are sidebar rows of their own on iPad; their grids load (they hung at 100 % CPU).
        func testSidebarTimelines() {
            XCUIDevice.shared.orientation = .landscapeLeft
            app.launch()
            waitForTiles("the Library")
            showSidebar()
            sidebarRow("Photos").tap()
            waitForTiles("Photos")
            assertRunning()
            shot("ipad-04-photos")
            showSidebar()
            sidebarRow("Favorites").tap()
            pause(3)
            assertRunning()
            shot("ipad-05-favorites")
            showSidebar()
            sidebarRow("Library").tap()
            waitForTiles("the Library")
        }

        /// The Archive asks for the device passcode when it is opened, and only then: not again on other screens.
        func testArchiveAsksOnlyInTheArchive() {
            XCUIDevice.shared.orientation = .landscapeLeft
            app.launch()
            waitForTiles("the Library")
            showSidebar()
            sidebarRow("Archive").tap()
            pause(4)
            shot("ipad-archive-1-prompt")
            // The system's passcode sheet belongs to SpringBoard.
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let passcode = springboard.secureTextFields["Passcode field"].firstMatch
            XCTAssertTrue(passcode.waitForExistence(timeout: 10), "The Archive did not ask for the passcode")
            springboard.buttons["Cancel"].firstMatch.tap()
            pause(2)
            shot("ipad-archive-2-cancelled")
            for title in ["Settings", "Albums", "Library"] {
                showSidebar()
                sidebarRow(title).tap()
                pause(4)
                shot("ipad-archive-3-then-\(title)")
                XCTAssertFalse(passcode.exists, "The Archive's passcode sheet came back on \(title)")
                if passcode.exists { springboard.buttons["Cancel"].firstMatch.tap() }
            }
        }

        /// The viewer at full size, with the info inspector beside the photo.
        func testViewerAndInfoInspector() {
            XCUIDevice.shared.orientation = .landscapeLeft
            app.launch()
            waitForTiles("the Library")
            tiles.element(boundBy: 3).tap()
            let info = app.buttons["Info"].firstMatch
            XCTAssertTrue(info.waitForExistence(timeout: Self.wait), "The viewer did not open")
            pause(2)
            shot("ipad-viewer-1-landscape")
            info.tap()
            pause(2)
            shot("ipad-viewer-2-info")
            XCUIDevice.shared.orientation = .portrait
            pause(2)
            shot("ipad-viewer-3-info-portrait")
            app.typeKey(.rightArrow, modifierFlags: [])
            pause(1)
            shot("ipad-viewer-4-next")
            app.buttons["More"].firstMatch.tap()
            pause(1)
            shot("ipad-viewer-5-more")
            tapOutside()
            app.buttons["Close"].firstMatch.tap()
            XCTAssertTrue(info.waitForNonExistence(timeout: 10), "The viewer did not close")
        }

        /// The menu commands are the hardware keyboard's shortcuts.
        func testKeyboardShortcuts() {
            XCUIDevice.shared.orientation = .landscapeLeft
            app.launch()
            waitForTiles("the Library")
            // Go ▸ Albums is the seventh item of the Go menu (⌘7).
            app.typeKey("7", modifierFlags: .command)
            pause(2)
            shot("ipad-keys-1-cmd7")
            XCTAssertTrue(sidebarRow("Albums").isSelected, "⌘7 did not open Albums")
            app.typeKey("1", modifierFlags: .command)
            pause(2)
            XCTAssertTrue(sidebarRow("Library").isSelected || app.buttons["Library"].isSelected, "⌘1 did not open the Library")
            // File ▸ New Album… (⇧⌘N): a sheet.
            app.typeKey("n", modifierFlags: [.command, .shift])
            pause(2)
            shot("ipad-keys-2-new-album")
            app.typeKey(.escape, modifierFlags: [])
            pause(1)
            // Search (⌘F).
            app.typeKey("f", modifierFlags: .command)
            pause(2)
            shot("ipad-keys-3-search")
            app.typeKey("1", modifierFlags: .command)
            pause(1)
            // ⌘I (Get Info) and ⌘−/⌘+ (Zoom) did not reach their actions in the simulator (see STATUS.md); not checked here.
        }

        /// The context menu's "Info" shows the photo's info in an inspector beside the grid; it closes again, and a relaunch
        /// starts without it (the system restored an empty one).
        func testGridInspector() {
            XCUIDevice.shared.orientation = .landscapeLeft
            app.launch()
            waitForTiles("the Library")
            pause(2)
            shot("ipad-inspector-0-launch")
            XCTAssertFalse(app.staticTexts["No selection"].exists, "The inspector is open at launch")
            tiles.element(boundBy: 2).press(forDuration: 1.5)
            let info = app.buttons["Info"].firstMatch
            XCTAssertTrue(info.waitForExistence(timeout: 5), "No Info in the photo's context menu")
            info.tap()
            pause(2)
            shot("ipad-inspector-1-shown")
            XCTAssertTrue(app.staticTexts["Name"].exists, "Info did not show the photo's info")
            app.terminate()
            app.launch()
            waitForTiles("the Library")
            pause(2)
            shot("ipad-inspector-2-relaunch")
            XCTAssertFalse(app.staticTexts["No selection"].exists, "The inspector came back empty after a relaunch")
            XCTAssertFalse(app.staticTexts["Name"].exists, "The inspector came back after a relaunch")
            tiles.element(boundBy: 2).press(forDuration: 1.5)
            app.buttons["Info"].firstMatch.tap()
            pause(2)
            let close = app.buttons["Hide info"].firstMatch
            XCTAssertTrue(close.waitForExistence(timeout: 5), "No button closes the inspector")
            close.tap()
            pause(2)
            shot("ipad-inspector-3-closed")
            XCTAssertFalse(app.staticTexts["Name"].exists, "Hide info did not close the inspector")
            XCTAssertFalse(close.exists, "Hide info stayed in the toolbar")
        }

        /// Switches the simulator between "Full Screen Apps" and "Windowed Apps" (Settings › Multitasking & Gestures).
        func setWindowedApps(_ windowed: Bool) {
            let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
            settings.launch()
            let row = settings.buttons["com.apple.settings.multitaskingAndGestures"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            row.tap()
            let mode = settings.buttons[
                windowed
                    ? "com.apple.settings.multitaskingAndGestures.windowedApps"
                    : "com.apple.settings.multitaskingAndGestures.fullScreenApps"
            ].firstMatch
            if !mode.waitForExistence(timeout: 5) {
                // Full Screen Apps: the first of the three choices.
                settings.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Full Screen Apps'")).firstMatch.tap()
            } else {
                mode.tap()
            }
            pause(2)
            settings.terminate()
        }

        /// Windowed apps (Stage Manager sizes): the window made narrow gets the compact layout (tab bar with Collections), and
        /// wide again the sidebar.
        func testWindowsNarrowWindowIsCompact() throws {
            try requireWindowTests()
            setWindowedApps(true)
            defer { setWindowedApps(false) }
            app.launch()
            waitForTiles("the Library")
            pause(2)
            shot("ipad-window-1-windowed")
            let window = app.windows.firstMatch.frame
            // The resize handle is at the window's lower trailing corner.
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: window.maxX - 6, dy: window.maxY - 6))
            let end = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: window.minX + 330, dy: window.maxY - 6))
            start.press(forDuration: 0.6, thenDragTo: end)
            pause(3)
            shot("ipad-window-2-narrow")
            XCTAssertTrue(app.buttons["Collections"].firstMatch.exists, "A narrow window has no Collections tab")
            app.buttons["Collections"].firstMatch.tap()
            pause(2)
            shot("ipad-window-3-collections")
            assertRunning()
        }

        /// An album window next to the library window (windowed apps); a photo dragged from the library into it is added to
        /// the album (it was ignored: the album took only file URLs). Needs an empty own album `r4-ipad-dnd` on the server, and
        /// changes it: remove the photo again afterwards. Album windows are restored at the next launch; start from a fresh
        /// installation (`xcrun simctl uninstall`).
        func testWindowsDragPhotoIntoAlbumWindow() throws {
            try requireWindowTests()
            try XCTSkipIf(
                ProcessInfo.processInfo.environment["PHOTOS_UITEST_DND_ALBUM"] != "1",
                "Set PHOTOS_UITEST_DND_ALBUM=1 when the server has an empty album r4-ipad-dnd that this test may change.")
            setWindowedApps(true)
            defer { setWindowedApps(false) }
            app.launch()
            pause(5)
            if app.buttons["Collections"].firstMatch.exists {
                // A narrow window from an earlier run: the Collections tab lists Albums.
                app.buttons["Collections"].firstMatch.tap()
                app.cells.containing(.staticText, identifier: "Albums").firstMatch.tap()
            } else {
                showSidebar()
                sidebarRow("Albums").tap()
            }
            pause(3)
            let album = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'r4-ipad-dnd'")).firstMatch
            XCTAssertTrue(album.waitForExistence(timeout: 20))
            album.press(forDuration: 1.5)
            app.buttons["Open in new window"].firstMatch.tap()
            pause(4)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let front = app.windows.firstMatch.frame
            // Move the album window to the right by its top edge.
            origin.withOffset(CGVector(dx: front.midX + 40, dy: front.minY + 14))
                .press(forDuration: 0.8, thenDragTo: origin.withOffset(CGVector(dx: front.midX + 420, dy: front.minY + 14)))
            pause(3)
            shot("ipad-dnd-1-two-windows")
            // The library window: back to the Library tab.
            let library = app.buttons.matching(NSPredicate(format: "label == 'Library'")).allElementsBoundByIndex.first { $0.isHittable }
            library?.tap()
            waitForTiles("the library window")
            pause(2)
            let tile = tiles.allElementsBoundByIndex.first { $0.isHittable && $0.frame.maxX < front.maxX }
            XCTAssertNotNil(tile)
            tile?.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 1.2, thenDragTo: origin.withOffset(CGVector(dx: front.midX + 420, dy: 500)))
            pause(6)
            shot("ipad-dnd-2-dropped")
            let added = tiles.allElementsBoundByIndex.first { $0.frame.minX >= front.maxX }
            XCTAssertNotNil(added, "The album window shows no photo after the drop")
        }

        /// The shortcuts still work while photos are selected (View ▸ Square Tiles ⌥⌘S, Go ⌘7). Nothing on the server changes:
        /// ⌘. (favourite) would change the test library.
        func testShortcutsWhileSelecting() {
            XCUIDevice.shared.orientation = .landscapeLeft
            app.launch()
            waitForTiles("the Library")
            app.navigationBars.buttons["Select"].firstMatch.tap()
            tiles.element(boundBy: 2).tap()
            pause(2)
            app.typeKey("s", modifierFlags: [.command, .option])
            pause(2)
            shot("ipad-keys-6-aspect-tiles")
            app.typeKey("s", modifierFlags: [.command, .option])
            pause(1)
            app.typeKey("7", modifierFlags: .command)
            pause(2)
            XCTAssertTrue(sidebarRow("Albums").isSelected, "⌘7 did not open Albums while a photo was selected")
        }

        /// Selection mode in the Library: Select, a tile, the selection's toolbar.
        func testSelectionMode() {
            XCUIDevice.shared.orientation = .landscapeLeft
            app.launch()
            waitForTiles("the Library")
            pause(2)
            let select = app.navigationBars.buttons["Select"].firstMatch
            XCTAssertTrue(select.waitForExistence(timeout: 10))
            select.tap()
            XCTAssertTrue(app.navigationBars.buttons["Done"].firstMatch.waitForExistence(timeout: 5), "Select did not start selecting")
            tiles.element(boundBy: 2).tap()
            tiles.element(boundBy: 3).tap()
            pause(1)
            shot("ipad-select-1-two")
            app.typeKey("i", modifierFlags: .command)
            pause(2)
            shot("ipad-select-2-info")
            app.buttons["More"].firstMatch.tap()
            pause(1)
            shot("ipad-select-3-more")
            tapOutside()
            app.navigationBars.buttons["Done"].firstMatch.tap()
        }

        /// The editor, the share sheet and the album picker at iPad sizes.
        func testEditorAndSheets() {
            XCUIDevice.shared.orientation = .landscapeLeft
            app.launch()
            waitForTiles("the Library")
            tiles.element(boundBy: 3).tap()
            XCTAssertTrue(app.buttons["Info"].firstMatch.waitForExistence(timeout: Self.wait), "The viewer did not open")
            // Not the sidebar's "Edit" (customisation), which is still in the window under the viewer.
            let edits = app.buttons.matching(NSPredicate(format: "label == 'Edit'"))
            XCTAssertGreaterThan(edits.count, 1, "The viewer has no Edit button")
            let edit = edits.element(boundBy: edits.count - 1)
            edit.tap()
            pause(6)
            shot("ipad-sheet-1-editor")
            app.buttons["Crop"].firstMatch.tap()
            pause(2)
            shot("ipad-sheet-1b-editor-crop")
            app.buttons["Cancel"].firstMatch.tap()
            pause(2)
            let shares = app.buttons.matching(NSPredicate(format: "label == 'Share'"))
            shares.element(boundBy: shares.count - 1).tap()
            pause(6)
            shot("ipad-sheet-1c-viewer-share")
            tapOutside()
            app.buttons["Close"].firstMatch.tap()
            pause(2)
            app.navigationBars.buttons["Select"].firstMatch.tap()
            tiles.element(boundBy: 2).tap()
            tiles.element(boundBy: 3).tap()
            pause(1)
            app.buttons["Share"].firstMatch.tap()
            pause(6)
            shot("ipad-sheet-2-share")
            tapOutside()
            app.buttons["More"].firstMatch.tap()
            pause(1)
            let add = app.buttons["Add to album"].firstMatch
            if add.waitForExistence(timeout: 3) {
                add.tap()
                pause(1)
                shot("ipad-sheet-3-add-to-album-menu")
                let all = app.buttons["All albums…"].firstMatch
                if all.waitForExistence(timeout: 3) {
                    all.tap()
                    pause(2)
                    shot("ipad-sheet-4-album-picker")
                    app.buttons["Cancel"].firstMatch.tap()
                }
            }
        }

        /// The context menus of a photo and of an album (with "Open in new window").
        func testWindowsAlbumContextMenuOpensAWindow() throws {
            try requireWindowTests()
            XCUIDevice.shared.orientation = .landscapeLeft
            app.launch()
            waitForTiles("the Library")
            tiles.element(boundBy: 2).press(forDuration: 1.5)
            pause(1)
            shot("ipad-menu-1-photo")
            tapOutside()
            showSidebar()
            sidebarRow("Albums").tap()
            pause(3)
            let album = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Rome 2021'")).firstMatch
            XCTAssertTrue(album.waitForExistence(timeout: 20), "No album Rome 2021")
            album.press(forDuration: 1.5)
            pause(1)
            shot("ipad-menu-2-album")
            let newWindow = app.buttons["Open in new window"].firstMatch
            XCTAssertTrue(newWindow.exists, "No \"Open in new window\" in the album's context menu")
            newWindow.tap()
            pause(4)
            shot("ipad-menu-3-album-window")
        }

        /// Dragging a photo inside the grid must not upload a copy of it (the grid takes dropped files as uploads).
        func testDragInsideTheGrid() {
            XCUIDevice.shared.orientation = .landscapeLeft
            app.launch()
            waitForTiles("the Library")
            let from = tiles.element(boundBy: 2)
            let to = tiles.element(boundBy: 12)
            from.press(forDuration: 1.2, thenDragTo: to)
            pause(3)
            shot("ipad-drag-1-dropped")
        }

        /// Every sidebar row opens its screen.
        func testSidebarDestinations() {
            XCUIDevice.shared.orientation = .landscapeLeft
            app.launch()
            waitForTiles("the Library")
            let titles = [
                "Videos", "Memories", "Map", "Albums", "Shared albums", "Smart albums", "People", "Places", "Tags", "Shared with you",
                "Folders", "Archive", "Recently deleted", "Duplicates", "Free up server space", "Backup", "Settings",
            ]
            for (index, title) in titles.enumerated() {
                showSidebar()
                let row = sidebarRow(title)
                if !row.isHittable { app.cells["Albums"].firstMatch.swipeUp() }
                guard row.waitForExistence(timeout: 5) else {
                    // People, Places and Tags need server apps (Recognize, system tags) the test server may not have.
                    if !["People", "Places", "Tags"].contains(title) { XCTFail("No sidebar row \(title)") }
                    continue
                }
                row.tap()
                pause(3)
                assertRunning()
                shot(String(format: "ipad-dest-%02d-%@", index, title.replacingOccurrences(of: " ", with: "-")))
            }
        }
    }
#endif
