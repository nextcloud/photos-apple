// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import XCTest

#if os(iOS)
    /// Round 11's proof tour (SPEC §21.2): the iPhone and iPad behaviour STATUS.md listed as "compiled, not run" — viewer
    /// gestures, Show in folder / Show in library, the slideshow, pull to refresh, photo links, adding photos to an album,
    /// the share and tag sheets, square tiles off, archive and undo. Each step leaves a screenshot (and with
    /// `PHOTOS_UITEST_SHOTS=<folder>` its accessibility tree) as evidence.
    ///
    /// Same requirements as `SmokeTests` (`PHOTOS_UITEST_LOGIN`, a bundle id of your own). Steps that change something
    /// work only on what the test brings: photos it uploads into a folder of its own and an album it creates, both
    /// removed at the end (never the test library).
    @MainActor
    final class VerifyTourTests: XCTestCase {
        static let wait: TimeInterval = 60
        var app: XCUIApplication!

        var prefix: String { ProcessInfo.processInfo.environment["PHOTOS_UITEST_SHOT_PREFIX"] ?? "verify-" }
        var login: String { ProcessInfo.processInfo.environment["PHOTOS_UITEST_LOGIN"] ?? "" }
        var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

        override func setUp() async throws {
            continueAfterFailure = true
            guard !login.isEmpty else {
                throw XCTSkip("Set PHOTOS_UITEST_LOGIN to a login link of a test server to run the UI tests.")
            }
            let runner = Bundle.main.bundleIdentifier ?? ""
            try XCTSkipIf(
                runner.hasPrefix(SmokeTests.officialBundleId + ".uitests"),
                "Build the UI tests with a bundle id of your own (PHOTOS_BUNDLE_ID), not \(SmokeTests.officialBundleId).")
            app = XCUIApplication()
            app.launchEnvironment["PHOTOS_DEBUG_LOGIN"] = login
            app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            // App lock off for this launch whatever is stored (the argument domain comes first): a lock that
            // `testAppLock` could not turn off again must not cover the app for the other tests. That test drops it.
            app.launchArguments += ["-appLockEnabled", "NO"]
        }

        override func tearDown() async throws {
            app?.terminate()
            app = nil
        }

        // MARK: Helpers

        /// A screenshot, attached and written with the accessibility tree.
        func shot(_ name: String) {
            let screenshot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = prefix + name
            attachment.lifetime = .keepAlways
            add(attachment)
            guard let folder = ProcessInfo.processInfo.environment["PHOTOS_UITEST_SHOTS"], !folder.isEmpty else { return }
            let directory = URL(fileURLWithPath: folder)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: directory.appending(path: "\(prefix)\(name).png"))
            try? Data(app.debugDescription.utf8).write(to: directory.appending(path: "\(prefix)\(name).txt"))
        }

        func pause(_ seconds: TimeInterval) {
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        }

        var tiles: XCUIElementQuery { app.collectionViews.cells }

        /// Opens a link of the app, answering the system's "Open in …?" question.
        func open(_ link: String) {
            guard let url = URL(string: link) else { return XCTFail("Bad link \(link)") }
            app.open(url)
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let confirm = springboard.buttons["Open"].firstMatch
            if confirm.waitForExistence(timeout: 4) { confirm.tap() }
            pause(2)
        }

        /// Launches the app and waits for the Library's photos.
        func launchToLibrary() {
            app.launch()
            unlockIfLocked()
            let library = app.tabBars.buttons["Library"].firstMatch
            _ = library.waitForExistence(timeout: 20)
            pause(2)
            open("nextcloudphotos://library")
            if library.exists && library.isHittable { library.tap() }
            XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: Self.wait), "No photo appeared in the timeline")
            pause(3)
        }

        /// Opens the app lock's cover if it is there (an app lock left on by `testAppLock`): the host's Face ID match opens it.
        func unlockIfLocked() {
            let unlock = app.buttons["Unlock Nextcloud Photos"].firstMatch
            guard unlock.waitForExistence(timeout: 3) else { return }
            unlock.tap()
            let gone = NSPredicate(format: "exists == false")
            let opened = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: gone, object: unlock)], timeout: 30) == .completed
            XCTAssertTrue(opened, "The app lock did not open")
        }

        /// Turns the app lock off again, whatever state `testAppLock` stopped in.
        func turnAppLockOff() {
            if let folder = ProcessInfo.processInfo.environment["PHOTOS_UITEST_SHOTS"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: folder).appending(path: "faceid.hold"))
            }
            app.activate()
            unlockIfLocked()
            app.openSettings(page: "privacy")
            let toggle = app.switches.matching(NSPredicate(format: "label BEGINSWITH 'Lock with'")).firstMatch
            if toggle.waitForExistence(timeout: 5), (toggle.value as? String) == "1" { toggle.switches.firstMatch.tap() }
            pause(1)
            closeSettings()
        }

        /// The first tile that is a photo of the grid (not a placeholder) and on screen.
        func firstVisibleTile(after skip: Int = 0) -> XCUIElement {
            let visible = tiles.allElementsBoundByIndex.filter { $0.isHittable }
            return visible.dropFirst(skip).first ?? tiles.element(boundBy: skip)
        }

        /// Asks the host to capture the simulator's screen while `body` runs (a gesture in progress, which a test cannot
        /// screenshot itself): writes `capture.request` into the shots folder, which `capture.sh` on the Mac watches.
        func captureFrames(_ name: String, during body: () -> Void) {
            guard let folder = ProcessInfo.processInfo.environment["PHOTOS_UITEST_SHOTS"], !folder.isEmpty else { return body() }
            let request = URL(fileURLWithPath: folder).appending(path: "capture.request")
            try? Data((prefix + name).utf8).write(to: request)
            pause(0.8)
            body()
            try? FileManager.default.removeItem(at: request)
        }

        /// Closes an open menu without choosing anything.
        func dismissMenu() {
            let region = app.otherElements["PopoverDismissRegion"].firstMatch
            if region.exists {
                region.tap()
            } else {
                app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.03)).tap()
            }
            pause(1)
        }

        /// Closes Settings from any of its pages (Done is on the first page only).
        func closeSettings() {
            let done = app.buttons["settings-done"].firstMatch
            for _ in 0..<3 where !(done.exists && done.isHittable) {
                let back = app.navigationBars.buttons.firstMatch
                guard back.exists else { break }
                back.tap()
                pause(1)
            }
            if done.exists { done.tap() }
            pause(1)
        }

        /// Opens the viewer on a tile and waits for its toolbar.
        @discardableResult
        func openViewer(_ tile: XCUIElement) -> Bool {
            tile.tap()
            let opened = app.buttons["Info"].firstMatch.waitForExistence(timeout: Self.wait)
            XCTAssertTrue(opened, "The viewer did not open")
            pause(2)
            return opened
        }

        /// The viewer's More menu, then one of its items.
        func viewerMenu(_ item: String) -> Bool {
            let more = app.buttons["More"].firstMatch
            guard more.waitForExistence(timeout: 5) else {
                XCTFail("No More button in the viewer")
                return false
            }
            more.tap()
            pause(1)
            let button = app.buttons[item].firstMatch
            for _ in 0..<3 where !(button.exists && button.isHittable) {
                app.swipeUp(velocity: .slow)
            }
            guard button.waitForExistence(timeout: 5) else {
                shot("menu-without-\(item)")
                XCTFail("No \(item) in the viewer's More menu")
                return false
            }
            button.tap()
            pause(1.5)
            return true
        }

        // MARK: Viewer gestures (STATUS M1: VW-1 iOS, swipe down / up, zoom transition)

        /// Double tap zooms in and out, swipe up shows the info panel, swipe down hides it and closes the viewer, and the
        /// grid is back with the tile it was opened from.
        func testViewerGestures() {
            launchToLibrary()
            let tile = firstVisibleTile(after: 2)
            openViewer(tile)
            shot("01-viewer")
            let photo = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            photo.doubleTap()
            pause(1.5)
            shot("02-viewer-double-tap-zoomed")
            // A zoomed photo pans instead of paging: the same page is still shown after a swipe.
            app.swipeLeft()
            pause(1)
            shot("03-viewer-zoomed-panned")
            photo.doubleTap()
            pause(1.5)
            shot("04-viewer-zoomed-out")
            // Swipe up: the info panel.
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
                .press(forDuration: 0.05, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)))
            pause(2)
            shot("05-viewer-swipe-up-info")
            app.swipeDown()
            pause(1.5)
            shot("06-viewer-info-closed")
            // Swipe down: the page follows the finger and the viewer closes (zoom back into the tile).
            captureFrames("07-viewer-swipe-down") {
                app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
                    .press(
                        forDuration: 0.05, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)),
                        withVelocity: .slow, thenHoldForDuration: 0.3)
                pause(1)
            }
            pause(1)
            shot("07-viewer-closed")
            XCTAssertFalse(app.buttons["Info"].firstMatch.exists, "The viewer is still open after swiping down")
            XCTAssertTrue(tiles.firstMatch.exists, "The grid is not back")
        }

        /// With the info card open, a swipe down closes the card, not the viewer (SPEC §17.1): on the card itself and on the
        /// photo above it.
        func testInfoCardSwipeDown() {
            launchToLibrary()
            openViewer(firstVisibleTile(after: 2))
            let window = app.windows.firstMatch
            for (index, start) in [CGFloat(0.62), 0.3].enumerated() {
                // The card's first row; the Info button would close a card that is still open.
                if !app.staticTexts["Name"].firstMatch.exists { app.buttons["Info"].firstMatch.tap() }
                pause(2)
                shot("08-info-card-\(index)")
                if index == 0 {
                    // A flick on the card itself (a slow drag there scrolls the card's content).
                    app.swipeDown()
                } else {
                    window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: start))
                        .press(
                            forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: start + 0.3)),
                            withVelocity: .slow, thenHoldForDuration: 0.1)
                }
                pause(2)
                shot("09-info-card-swiped-\(index)")
                guard app.buttons["Info"].firstMatch.waitForExistence(timeout: 3) else {
                    return XCTFail("A swipe down on the info card (start \(start)) closed the viewer")
                }
                XCTAssertFalse(app.staticTexts["Name"].firstMatch.exists, "The swipe down (start \(start)) left the card open")
            }
        }

        // MARK: Show in folder / Show in library (VW-3)

        func testShowInFolder() {
            launchToLibrary()
            openViewer(firstVisibleTile(after: 1))
            guard viewerMenu("Show in folder") else { return }
            pause(2)
            shot("10-show-in-folder")
            XCTAssertFalse(app.buttons["Info"].firstMatch.exists, "The viewer stayed open")
            // The folder screen is pushed with a screen for each folder above it: its title is the photo's folder.
            let titled = app.navigationBars.firstMatch
            XCTAssertTrue(titled.waitForExistence(timeout: 10), "No folder screen")
            XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 20), "The folder shows no photo")
            app.navigationBars.buttons.firstMatch.tap()
            pause(1.5)
            shot("11-show-in-folder-back")
        }

        /// From a grid other than the Library (Favorites), "Show in library" closes the viewer and opens the Library at
        /// the photo.
        func testShowInLibrary() {
            launchToLibrary()
            open("nextcloudphotos://folders/Photos")
            pause(3)
            shot("12-folders")
            // Go down to the first folder with photos.
            for folder in ["Test library", "Everyday"] where !tiles.firstMatch.exists {
                let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", folder)).firstMatch
                guard row.waitForExistence(timeout: 10) else { break }
                row.tap()
                pause(3)
            }
            guard tiles.firstMatch.waitForExistence(timeout: 20) else {
                shot("12-folders-no-photo")
                return XCTFail("No photo in the folder")
            }
            openViewer(firstVisibleTile(after: 4))
            guard viewerMenu("Show in library") else { return }
            pause(3)
            shot("13-show-in-library")
            XCTAssertFalse(app.buttons["Info"].firstMatch.exists, "The viewer stayed open")
            XCTAssertTrue(isPad || app.tabBars.buttons["Library"].firstMatch.isSelected, "The Library is not the tab shown")
        }

        // MARK: Slideshow (VW-5)

        func testSlideshowFromTheViewer() {
            launchToLibrary()
            openViewer(firstVisibleTile(after: 1))
            guard viewerMenu("Slideshow") else { return }
            pause(2)
            shot("20-slideshow")
            pause(4)
            shot("21-slideshow-advanced")
            // The controls come back with a tap.
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            pause(1)
            shot("22-slideshow-controls")
            let options = app.buttons["Slideshow options"].firstMatch
            if options.waitForExistence(timeout: 3) {
                options.tap()
                pause(1)
                shot("23-slideshow-options")
                let ten = app.buttons["10 seconds"].firstMatch
                if ten.waitForExistence(timeout: 2) {
                    ten.tap()
                } else {
                    app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
                }
                pause(1)
            }
            let close = app.buttons["Close"].firstMatch
            if !close.isHittable { app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
            XCTAssertTrue(close.waitForExistence(timeout: 5), "No Close in the slideshow")
            close.tap()
            pause(2)
            shot("24-slideshow-closed")
            XCTAssertTrue(app.buttons["Info"].firstMatch.waitForExistence(timeout: 5), "The viewer is not back after the slideshow")
        }

        // MARK: Grid (pull to refresh, square tiles)

        func testPullToRefresh() {
            launchToLibrary()
            let grid = app.collectionViews.firstMatch
            // From below the memories strip, held for a while so that the host captures the refresh control.
            captureFrames("30-pull-to-refresh") {
                grid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
                    .press(
                        forDuration: 0.05, thenDragTo: grid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)),
                        withVelocity: .slow, thenHoldForDuration: 2.5)
            }
            shot("30-pull-to-refresh")
            pause(4)
            shot("31-refreshed")
            XCTAssertTrue(tiles.firstMatch.exists, "The grid is empty after refreshing")
        }

        func testSquareTilesOff() {
            launchToLibrary()
            app.openSettings(page: "library")
            let toggle = app.switches["Square tiles"].firstMatch
            for _ in 0..<4 where !(toggle.exists && toggle.isHittable) { app.swipeUp(velocity: .slow) }
            guard toggle.waitForExistence(timeout: 5) else {
                shot("32-settings-without-square-tiles")
                return XCTFail("No Square tiles switch")
            }
            let wasOn = (toggle.value as? String) == "1"
            if wasOn { toggle.switches.firstMatch.tap() }
            pause(1)
            shot("32-square-tiles-off")
            closeSettings()
            pause(3)
            shot("33-library-aspect-ratio")
            openViewer(firstVisibleTile(after: 2))
            app.swipeDown()
            pause(1)
            // Back to the setting the device had.
            app.openSettings(page: "library")
            for _ in 0..<4 where !(toggle.exists && toggle.isHittable) { app.swipeUp(velocity: .slow) }
            if wasOn, (toggle.value as? String) == "0" { toggle.switches.firstMatch.tap() }
            pause(1)
            closeSettings()
            pause(2)
            shot("34-library-square-again")
        }

        // MARK: Links (photo links, public album links)

        func testPhotoLink() async throws {
            let folder = "Photos/r11-verify link \(UUID().uuidString.prefix(6))"
            let server = try XCTUnwrap(TestServer(login: login, folder: folder))
            let dav = try XCTUnwrap(VerifyDAV(login: login))
            addTeardownBlock { try? await server.removeFolder() }
            let names = try await server.uploadPhotos(1, prefix: "r11-verify-link")
            let id = try await dav.fileId(of: "\(folder)/\(names[0])")
            let fileId = try XCTUnwrap(id, "No file id for the uploaded photo")
            launchToLibrary()
            XCTAssertTrue(app.staticTexts["Today"].firstMatch.waitForExistence(timeout: Self.wait), "The uploaded photo did not arrive")
            open("nextcloudphotos://photo/\(fileId)")
            XCTAssertTrue(app.buttons["Info"].firstMatch.waitForExistence(timeout: 20), "The photo link did not open the viewer")
            pause(2)
            shot("40-photo-link")
            // An unknown id opens nothing.
            app.swipeDown()
            pause(1)
            open("nextcloudphotos://photo/999999999")
            pause(2)
            shot("41-photo-link-unknown")
            XCTAssertFalse(app.buttons["Info"].firstMatch.exists, "An unknown photo id opened the viewer")
        }

        // MARK: Albums (add photos, toolbar while selecting)

        func testAddPhotosToAnAlbum() async throws {
            let dav = try XCTUnwrap(VerifyDAV(login: login))
            let name = "r11-verify album \(UUID().uuidString.prefix(6))"
            // Three photos of its own, the newest of the library: the first three tiles of the picker.
            let folder = "Photos/r11-verify add \(UUID().uuidString.prefix(6))"
            let server = try XCTUnwrap(TestServer(login: login, folder: folder))
            addTeardownBlock { try? await server.removeFolder() }
            _ = try await server.uploadPhotos(3, prefix: "r11-verify-add")
            try await dav.createAlbum(name)
            addTeardownBlock { try? await dav.deleteAlbum(name) }
            launchToLibrary()
            XCTAssertTrue(app.staticTexts["Today"].firstMatch.waitForExistence(timeout: Self.wait), "The uploaded photos did not arrive")
            open("nextcloudphotos://albums/\(name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name)")
            pause(3)
            shot("50-empty-album")
            // At compact width the album's actions are one menu (Album options).
            let add = app.buttons["Add photos"].firstMatch
            if !add.waitForExistence(timeout: 5) {
                let options = app.buttons["Album options"].firstMatch
                if options.waitForExistence(timeout: 10) { options.tap() }
                pause(1)
                shot("50-album-options")
            }
            guard add.waitForExistence(timeout: 10) else { return XCTFail("No Add photos in the album") }
            add.tap()
            pause(3)
            shot("51-add-photos-picker")
            let picker = app.collectionViews.cells
            XCTAssertTrue(picker.firstMatch.waitForExistence(timeout: 20), "The picker shows no photo")
            let visible = picker.allElementsBoundByIndex.filter { $0.isHittable }
            for cell in visible.prefix(3) { cell.tap() }
            pause(1)
            shot("52-add-photos-picked")
            let confirm = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Add'")).allElementsBoundByIndex
                .filter { $0.isHittable && $0.label != "Add photos" }
            XCTAssertFalse(confirm.isEmpty, "No Add button in the picker")
            confirm.first?.tap()
            pause(3)
            shot("53-album-after-add")
            // On the server first (the outbox sends the adds), then in the album's grid.
            var onServer = 0
            for _ in 0..<10 where onServer < 3 {
                onServer = (try? await dav.albumCount(name)) ?? 0
                if onServer < 3 { pause(2) }
            }
            XCTAssertEqual(onServer, 3, "The server's album does not have the 3 photos")
            let shown = tiles.element(boundBy: 2).waitForExistence(timeout: 20)
            shot("53-album-with-photos")
            XCTAssertTrue(shown, "The album does not show the added photos")
            // Selecting keeps the album's title; the count is the subtitle.
            let select = app.buttons["Select"].firstMatch
            // Only with the photos shown: a failed tap in an async test stops its teardown (XCTest waits for ever).
            if shown, select.waitForExistence(timeout: 5) {
                select.tap()
                pause(1)
                tiles.element(boundBy: 0).tap()
                tiles.element(boundBy: 1).tap()
                pause(1)
                shot("54-album-selecting")
                XCTAssertTrue(
                    app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", String(name.prefix(14)))).firstMatch.exists,
                    "The album lost its title while selecting")
                app.buttons["Done"].firstMatch.tap()
            }
        }

        // MARK: Sheets (share, tags, share via Nextcloud)

        func testShareAndTagSheets() {
            launchToLibrary()
            let tile = firstVisibleTile(after: 1)
            tile.press(forDuration: 1.2)
            pause(1)
            shot("60-context-menu")
            let share = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Share'")).firstMatch
            if share.waitForExistence(timeout: 3) {
                share.tap()
                pause(4)
                shot("61-share-sheet")
                // The system's share sheet: close it.
                let close = app.buttons["Close"].firstMatch
                if close.waitForExistence(timeout: 5) { close.tap() } else { app.swipeDown(velocity: .fast) }
                pause(1.5)
            } else {
                XCTFail("No Share in the context menu")
                app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
            }
            openViewer(firstVisibleTile(after: 1))
            if viewerMenu("Tags…") {
                pause(2)
                shot("62-tags-sheet")
                XCTAssertTrue(app.navigationBars["Tags"].firstMatch.waitForExistence(timeout: 5), "No Tags sheet")
                let done = app.buttons["Done"].firstMatch
                if done.waitForExistence(timeout: 3) { done.tap() } else { app.swipeDown(velocity: .fast) }
                pause(1)
            }
            // Share via Nextcloud (SH-7) is in the grid's context menu.
            app.swipeDown()
            pause(1.5)
            firstVisibleTile(after: 1).press(forDuration: 1.2)
            pause(1)
            let nextcloud = app.buttons["Share via Nextcloud…"].firstMatch
            for _ in 0..<3 where !(nextcloud.exists && nextcloud.isHittable) { app.swipeUp(velocity: .slow) }
            if nextcloud.waitForExistence(timeout: 3) {
                nextcloud.tap()
                pause(3)
                shot("63-share-via-nextcloud")
                let close = app.buttons.matching(NSPredicate(format: "label IN {'Done', 'Cancel', 'Close'}")).firstMatch
                if close.waitForExistence(timeout: 3) { close.tap() } else { app.swipeDown(velocity: .fast) }
                pause(1)
            } else {
                XCTFail("No Share via Nextcloud… in the context menu")
            }
        }

        // MARK: Stacks and bursts (TL-6, VW-6) on the test's own photos

        /// Two copies of one shot (same name, other extension) are one tile with a stack badge; the viewer's strip picks
        /// the copy. Three frames a camera named as a burst are one tile. Deleting the stacked tile names what is behind it.
        func testStacksAndBursts() async throws {
            let folder = "Photos/r11-verify stacks \(UUID().uuidString.prefix(6))"
            let server = try XCTUnwrap(TestServer(login: login, folder: folder))
            let dav = try XCTUnwrap(VerifyDAV(login: login))
            addTeardownBlock { try? await server.removeFolder() }
            try await dav.makeFolder(folder)
            let now = Int(Date().timeIntervalSince1970)
            try await dav.put("\(folder)/R11STACK.jpg", data: TestServer.jpeg(hue: 0.1), mtime: now)
            try await dav.put("\(folder)/R11STACK.jpeg", data: TestServer.jpeg(hue: 0.15), mtime: now - 1)
            try await dav.put("\(folder)/R11_BURST001_COVER.jpg", data: TestServer.jpeg(hue: 0.5), mtime: now - 20)
            try await dav.put("\(folder)/R11_BURST002.jpg", data: TestServer.jpeg(hue: 0.55), mtime: now - 21)
            try await dav.put("\(folder)/R11_BURST003.jpg", data: TestServer.jpeg(hue: 0.6), mtime: now - 22)
            launchToLibrary()
            XCTAssertTrue(app.staticTexts["Today"].firstMatch.waitForExistence(timeout: Self.wait), "The uploaded photos did not arrive")
            pause(3)
            shot("100-stacks-in-library")
            let stack = tiles.matching(NSPredicate(format: "label CONTAINS[c] '2 copies'")).firstMatch
            let burst = tiles.matching(NSPredicate(format: "label CONTAINS[c] 'Burst of 3'")).firstMatch
            XCTAssertTrue(stack.waitForExistence(timeout: 10), "No tile with 2 copies")
            XCTAssertTrue(burst.exists, "No burst tile")
            guard stack.exists else { return }
            stack.tap()
            XCTAssertTrue(app.buttons["Info"].firstMatch.waitForExistence(timeout: 20), "The viewer did not open")
            pause(2)
            shot("101-stack-viewer-strip")
            let copy = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Copy 2 of 2'")).firstMatch
            if copy.waitForExistence(timeout: 5) {
                copy.tap()
                pause(1.5)
                shot("102-stack-second-copy")
            } else {
                XCTFail("No strip of the stack's copies")
            }
            app.buttons["Close"].firstMatch.tap()
            pause(1.5)
            if burst.exists {
                burst.tap()
                pause(2)
                shot("103-burst-viewer")
                let close = app.buttons["Close"].firstMatch
                if close.waitForExistence(timeout: 5) { close.tap() }
                pause(1.5)
            }
            // Delete the stacked tile: the confirmation counts both and says one is stacked behind (not confirmed here).
            stack.press(forDuration: 1.2)
            pause(1)
            let delete = app.buttons["Delete…"].firstMatch
            for _ in 0..<3 where !(delete.exists && delete.isHittable) { app.swipeUp(velocity: .slow) }
            if delete.waitForExistence(timeout: 3) {
                delete.tap()
                pause(1.5)
                shot("104-stack-delete-confirmation")
                XCTAssertTrue(
                    app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'stacked'")).firstMatch.exists
                        || app.buttons.matching(NSPredicate(format: "label CONTAINS[c] '2 items'")).firstMatch.exists,
                    "The confirmation does not name the stacked copy")
                let cancel = app.buttons["Cancel"].firstMatch
                if cancel.exists { cancel.tap() } else { dismissMenu() }
            } else {
                XCTFail("No Delete… in the stack's context menu")
            }
        }

        // MARK: Album sharing (collaborators with sharee search, link), offline; metadata sheet

        func testAlbumSharingAndOffline() async throws {
            let dav = try XCTUnwrap(VerifyDAV(login: login))
            let name = "r11-verify share \(UUID().uuidString.prefix(6))"
            try await dav.createAlbum(name)
            addTeardownBlock { try? await dav.deleteAlbum(name) }
            launchToLibrary()
            open("nextcloudphotos://albums/\(name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name)")
            pause(3)
            let share = app.buttons["Share album"].firstMatch
            if !share.waitForExistence(timeout: 5) {
                app.buttons["Album options"].firstMatch.tap()
                pause(1)
                shot("110-album-options")
            }
            guard share.waitForExistence(timeout: 5) else { return XCTFail("No Share album") }
            share.tap()
            pause(2)
            shot("111-album-share-sheet")
            let field = app.textFields["Search users or groups"].firstMatch
            if field.waitForExistence(timeout: 5) {
                field.tap()
                field.typeText("a")
                pause(3)
                shot("112-sharee-search")
            } else {
                XCTFail("No sharee search field")
            }
            let done = app.buttons.matching(NSPredicate(format: "label IN {'Done', 'Cancel', 'Close'}")).firstMatch
            if done.waitForExistence(timeout: 3) { done.tap() } else { app.swipeDown(velocity: .fast) }
            pause(1.5)
            app.buttons["Album options"].firstMatch.tap()
            pause(1)
            let offline = app.buttons["Make available offline"].firstMatch
            if offline.waitForExistence(timeout: 3) {
                offline.tap()
                pause(2)
                shot("113-album-offline")
            } else {
                shot("113-album-options-without-offline")
                dismissMenu()
            }
        }

        func testEditDateAndLocationSheet() async throws {
            let folder = "Photos/r11-verify meta \(UUID().uuidString.prefix(6))"
            let server = try XCTUnwrap(TestServer(login: login, folder: folder))
            addTeardownBlock { try? await server.removeFolder() }
            _ = try await server.uploadPhotos(1, prefix: "r11-verify-meta")
            launchToLibrary()
            XCTAssertTrue(app.staticTexts["Today"].firstMatch.waitForExistence(timeout: Self.wait), "The uploaded photo did not arrive")
            openViewer(tiles.element(boundBy: 0))
            guard viewerMenu("Edit date and location") else { return }
            pause(2)
            shot("120-edit-date-and-location")
            let cancel = app.buttons["Cancel"].firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: 5), "The sheet did not open")
            cancel.tap()
        }

        // MARK: Memories (ME-4 slideshow and menu), map (MP-1)

        func testMemorySlideshowAndMenu() {
            launchToLibrary()
            open("nextcloudphotos://memories")
            pause(3)
            let card = app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] 'ago' OR label CONTAINS[c] 'trip' OR label CONTAINS[c] 'year'")
            )
            .allElementsBoundByIndex.first { $0.isHittable }
            guard let card else {
                shot("80-memories-without-card")
                return XCTFail("No memory card")
            }
            card.tap()
            pause(3)
            shot("80-memory")
            let play = app.buttons["Play slideshow"].firstMatch
            guard play.waitForExistence(timeout: 5) else { return XCTFail("No Play slideshow in the memory") }
            play.tap()
            pause(2)
            shot("82-memory-slideshow-title")
            pause(5)
            shot("83-memory-slideshow-next")
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            pause(1)
            shot("84-memory-slideshow-controls")
            let close = app.buttons["Close"].firstMatch
            XCTAssertTrue(close.waitForExistence(timeout: 5), "No Close in the memory slideshow")
            close.tap()
            pause(2)
            shot("85-memory-after-slideshow")
            let more = app.buttons["More"].firstMatch
            if more.waitForExistence(timeout: 5) {
                more.tap()
                pause(1)
                shot("81-memory-menu")
                XCTAssertTrue(app.buttons["Save as album"].firstMatch.exists, "No Save as album in the memory's menu")
                XCTAssertTrue(app.buttons["Share as link…"].firstMatch.exists, "No Share as link… in the memory's menu")
                dismissMenu()
                pause(1)
            } else {
                XCTFail("No More in the memory's toolbar")
            }
        }

        func testMapClustersAndTimeRange() {
            launchToLibrary()
            open("nextcloudphotos://map")
            pause(6)
            shot("86-map")
            let range = app.buttons["Time range"].firstMatch
            if range.waitForExistence(timeout: 5) {
                range.tap()
                pause(2)
                shot("87-map-time-range")
                let slider = app.sliders.firstMatch
                if slider.waitForExistence(timeout: 3) {
                    slider.adjust(toNormalizedSliderPosition: 0.7)
                    pause(2)
                    shot("88-map-time-range-moved")
                }
                let all = app.buttons["All time"].firstMatch
                if all.exists { all.tap() }
            } else {
                XCTFail("No Time range on the map")
            }
            // A cluster lists its photos.
            let marker = app.otherElements.matching(NSPredicate(format: "label CONTAINS[c] 'photo'")).allElementsBoundByIndex
                .first { $0.isHittable && $0.frame.width < 120 }
            if let marker {
                marker.tap()
                pause(3)
                shot("89-map-cluster")
            }
        }

        // MARK: Behind the device unlock (recently deleted, app lock)

        // Needs Face ID enrolled in the simulator and a match posted by the host while the test waits
        // (`notifyutil -p com.apple.BiometricKit_Sim.pearl.match`, see ~/aloha-work/photos-tools/r11/verify/faceid.sh).

        func testRecentlyDeletedBehindTheUnlock() {
            launchToLibrary()
            open("nextcloudphotos://recentlyDeleted")
            pause(1)
            shot("90-recently-deleted-asking")
            pause(10)
            shot("91-recently-deleted-unlocked")
            XCTAssertTrue(app.navigationBars["Recently deleted"].firstMatch.waitForExistence(timeout: 10), "No Recently deleted screen")
        }

        func testAppLock() throws {
            // Needs a host that enrols Face ID and posts matches (see faceid.hold below). Without one the lock never
            // opens and every later test would meet a locked app.
            try XCTSkipUnless(
                ProcessInfo.processInfo.environment["PHOTOS_UITEST_FACEID"] == "1",
                "Set PHOTOS_UITEST_FACEID=1 when the host posts simulated Face ID matches")
            // Off again however the test ends: a lock left on would cover the app for every later test.
            addTeardownBlock { @MainActor [self] in turnAppLockOff() }
            app.launchArguments.removeAll { $0 == "-appLockEnabled" || $0 == "NO" }
            launchToLibrary()
            app.openSettings(page: "privacy")
            let toggle = app.switches.matching(NSPredicate(format: "label BEGINSWITH 'Lock with'")).firstMatch
            guard toggle.waitForExistence(timeout: 5) else {
                shot("92-privacy-without-lock")
                return XCTFail("No app lock switch")
            }
            shot("92-privacy")
            if (toggle.value as? String) == "0" { toggle.switches.firstMatch.tap() }
            pause(1)
            shot("93-app-lock-on")
            closeSettings()
            pause(1)
            // To the background and back: the cover asks for the unlock.
            // "Lock after" is 1 minute by default: longer than that in the background. The host holds its Face ID
            // matches back meanwhile (`faceid.hold` in the shots folder), so the lock can be looked at before it opens.
            let hold: URL? = ProcessInfo.processInfo.environment["PHOTOS_UITEST_SHOTS"].map {
                URL(fileURLWithPath: $0).appending(path: "faceid.hold")
            }
            if let hold { try? Data().write(to: hold) }
            XCUIDevice.shared.press(.home)
            pause(70)
            app.activate()
            let covered = app.buttons["Unlock Nextcloud Photos"].firstMatch.waitForExistence(timeout: 10)
            shot("94-app-locked")
            if let hold { try? FileManager.default.removeItem(at: hold) }
            XCTAssertTrue(covered, "No lock cover")
            let unlock = app.buttons["Unlock Nextcloud Photos"].firstMatch
            if unlock.waitForExistence(timeout: 5) { unlock.tap() }
            pause(10)
            shot("95-app-unlocked")
        }

        // MARK: Actions on the test's own photos (archive, undo, delete confirmation)

        func testArchiveAndUndoOnOwnPhotos() async throws {
            let folder = "Photos/r11-verify \(UUID().uuidString.prefix(6))"
            let server = try XCTUnwrap(TestServer(login: login, folder: folder))
            addTeardownBlock { try? await server.removeFolder() }
            _ = try await server.uploadPhotos(2, prefix: "r11-verify")
            launchToLibrary()
            XCTAssertTrue(app.staticTexts["Today"].firstMatch.waitForExistence(timeout: Self.wait), "The uploaded photos did not arrive")
            guard app.staticTexts["Today"].firstMatch.exists else { return }
            app.buttons["Select"].firstMatch.tap()
            pause(1)
            tiles.element(boundBy: 0).tap()
            pause(1)
            let more = app.buttons["More"].firstMatch
            XCTAssertTrue(more.waitForExistence(timeout: 5), "No More in the selection bar")
            more.tap()
            pause(1)
            shot("70-selection-more")
            let archive = app.buttons["Archive"].firstMatch
            guard archive.waitForExistence(timeout: 5) else { return XCTFail("No Archive in the selection's More menu") }
            archive.tap()
            pause(0.4)
            shot("71-archive-sliding")
            pause(2)
            shot("72-archived")
            let undo = app.buttons["Undo"].firstMatch
            XCTAssertTrue(undo.waitForExistence(timeout: 8), "No Undo after archiving")
            undo.tap()
            pause(4)
            shot("73-archive-undone")
        }
    }

    /// The DAV calls the tour needs besides `TestServer`: file ids and an album of its own.
    struct VerifyDAV {
        let server: URL
        let user: String
        let credentials: String

        init?(login: String) {
            guard let range = login.range(of: "server:") else { return nil }
            var values: [String: String] = [:]
            for part in login[range.lowerBound...].split(separator: "&") {
                guard let colon = part.firstIndex(of: ":") else { continue }
                values[String(part[..<colon])] = String(part[part.index(after: colon)...])
            }
            guard let address = values["server"], let server = URL(string: address), let user = values["user"],
                let password = values["password"]
            else { return nil }
            self.server = server
            self.user = user
            credentials = Data("\(user):\(password)".utf8).base64EncodedString()
        }

        private func send(_ method: String, _ url: URL, depth: String? = nil, body: String? = nil) async throws -> (Data, Int) {
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.httpMethod = method
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
            if let depth { request.setValue(depth, forHTTPHeaderField: "Depth") }
            if let body {
                request.httpBody = Data(body.utf8)
                request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        private func files(_ path: String) -> URL {
            var url = server.appending(path: "remote.php/dav/files").appending(path: user)
            for part in path.split(separator: "/") { url = url.appending(path: String(part)) }
            return url
        }

        private var albums: URL { server.appending(path: "remote.php/dav/photos").appending(path: user).appending(path: "albums") }

        private static let fileIdBody =
            #"<?xml version="1.0"?><d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns"><d:prop><oc:fileid/><d:getcontenttype/></d:prop></d:propfind>"#

        func fileId(of path: String) async throws -> String? {
            let (data, _) = try await send("PROPFIND", files(path), depth: "0", body: Self.fileIdBody)
            return Self.values(of: "fileid", in: data).first
        }

        /// The id of the first JPEG of a folder (read only).
        func firstPhotoId(in path: String) async throws -> String? {
            let (data, _) = try await send("PROPFIND", files(path), depth: "1", body: Self.fileIdBody)
            let ids = Self.values(of: "fileid", in: data)
            let types = Self.values(of: "getcontenttype", in: data, keepEmpty: true)
            // The folder itself comes first (no content type).
            for (index, type) in types.enumerated() where type == "image/jpeg" && index < ids.count { return ids[index] }
            return nil
        }

        func makeFolder(_ path: String) async throws {
            let (_, status) = try await send("MKCOL", files(path))
            guard status == 201 || status == 405 else { throw URLError(.badServerResponse) }
        }

        func put(_ path: String, data: Data, mtime: Int) async throws {
            var request = URLRequest(url: files(path), timeoutInterval: 20)
            request.httpMethod = "PUT"
            request.httpBody = data
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
            request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
            request.setValue(String(mtime), forHTTPHeaderField: "X-OC-MTime")
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
                throw URLError(.badServerResponse)
            }
        }

        func createAlbum(_ name: String) async throws {
            let (_, status) = try await send("MKCOL", albums.appending(path: name))
            guard status == 201 || status == 405 else { throw URLError(.badServerResponse) }
        }

        /// The number of files in an album of the user (PROPFIND, depth 1, less the album itself).
        func albumCount(_ name: String) async throws -> Int {
            let (data, _) = try await send("PROPFIND", albums.appending(path: name), depth: "1", body: Self.fileIdBody)
            return max(Self.values(of: "getcontenttype", in: data, keepEmpty: true).count - 1, 0)
        }

        func deleteAlbum(_ name: String) async throws {
            _ = try await send("DELETE", albums.appending(path: name))
        }

        /// The texts of every element with that local name, in document order.
        static func values(of element: String, in data: Data, keepEmpty: Bool = false) -> [String] {
            final class Collector: NSObject, XMLParserDelegate {
                let element: String
                let keepEmpty: Bool
                var values: [String] = []
                var text: String?
                var sawElementInResponse = false
                init(element: String, keepEmpty: Bool) {
                    self.element = element
                    self.keepEmpty = keepEmpty
                }
                func parser(
                    _ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]
                ) {
                    if name == "response" { sawElementInResponse = false }
                    if name == element { text = "" }
                }
                func parser(_ parser: XMLParser, foundCharacters string: String) { text? += string }
                func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
                    if name == element, let text {
                        values.append(text)
                        sawElementInResponse = true
                        self.text = nil
                    }
                    if name == "response", keepEmpty, !sawElementInResponse { values.append("") }
                }
            }
            let collector = Collector(element: element, keepEmpty: keepEmpty)
            let parser = XMLParser(data: data)
            parser.shouldProcessNamespaces = true
            parser.delegate = collector
            parser.parse()
            return collector.values
        }
    }
#endif
