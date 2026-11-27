// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import XCTest

#if os(iOS) || os(visionOS)
    /// The screenshots of the README (`scripts/readme-screenshots.sh`): the main features on iPhone, iPad and Vision Pro,
    /// from the real app against a test server with the sample library. Each test writes
    /// `<PHOTOS_UITEST_SHOT_PREFIX><name>.png` to `PHOTOS_UITEST_SHOTS`. Needs `PHOTOS_UITEST_LOGIN`.
    ///
    /// Nothing on the server changes: the editor is left without Done (the app is ended, no recipe is written), and the
    /// backup shot holds every upload (`PHOTOS_DEBUG_BACKUP_HOLD`); its backup folder is removed at the end.
    @MainActor
    final class ReadmeScreenshots: XCTestCase {
        var app: XCUIApplication!
        private var server: TestServer?
        private var backupFolder: String?

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
            server = TestServer(login: login, folder: "/Photos/readme-backup")
            app = XCUIApplication()
            app.launchEnvironment["PHOTOS_DEBUG_LOGIN"] = login
            app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            // Tidy screens: albums by name, no invitation card in Memories (argument domain, nothing is stored).
            app.launchArguments += ["-albumsSortOrder", "name", "-weeklyPromptsInvitationDismissed", "YES"]
            #if os(iOS)
                if environment["PHOTOS_UITEST_LANDSCAPE"] == "1" { XCUIDevice.shared.orientation = .landscapeLeft }
            #endif
        }

        override func tearDown() async throws {
            app?.terminate()
            app = nil
            if backupFolder != nil { try? await server?.removeFolder() }
        }

        var tiles: XCUIElementQuery { app.collectionViews.cells }

        /// The first element of `query` that is on screen (a query can also match cards outside the window, whose frame
        /// is infinite).
        func onScreen(_ query: XCUIElementQuery) -> XCUIElement? {
            let screen = app.windows.firstMatch.frame
            for index in 0..<min(query.count, 24) {
                let element = query.element(boundBy: index)
                let frame = element.frame
                if frame.minX.isFinite, frame.minY.isFinite, frame.height > 40, screen.intersects(frame) { return element }
            }
            return nil
        }

        func pause(_ seconds: TimeInterval) {
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        }

        func launch(destination: String? = nil) {
            if let destination { app.launchEnvironment["PHOTOS_DEBUG_DESTINATION"] = destination }
            app.launch()
        }

        func waitForTimeline() {
            // The zoom level is kept across launches: back to the photos.
            if !tiles.firstMatch.waitForExistence(timeout: 20) { _ = tapButton("All Photos", timeout: 5) }
            XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 240), "No photos in the timeline")
            pause(10)
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

        /// The photo the viewer shots open (`PHOTOS_UITEST_SHOT_PHOTO`, a file id), else the ninth tile of the Library.
        var photoId: String? { environment("PHOTOS_UITEST_SHOT_PHOTO") }
        /// The photo the editor shots open (`PHOTOS_UITEST_SHOT_EDIT_PHOTO`, a file id).
        var editPhotoId: String? { environment("PHOTOS_UITEST_SHOT_EDIT_PHOTO") }

        func tapButton(_ label: String, timeout: TimeInterval = 10) -> Bool {
            let button = app.buttons[label].firstMatch
            guard button.waitForExistence(timeout: timeout) else { return false }
            button.tap()
            return true
        }

        /// Opens a photo by its link (`nextcloudphotos://photo/<id>`), or the ninth tile of the Library.
        func openViewer(_ id: String?) {
            waitForTimeline()
            if let id, let url = URL(string: "nextcloudphotos://photo/\(id)") {
                app.open(url)
                #if os(iOS)
                    let confirm = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"].firstMatch
                    if confirm.waitForExistence(timeout: 4) { confirm.tap() }
                #endif
            } else {
                tiles.element(boundBy: 8).tap()
            }
            XCTAssertTrue(app.buttons["Close"].firstMatch.waitForExistence(timeout: 30), "The viewer did not open")
            pause(6)
        }

        /// The viewer's Edit button (an iPad's sidebar has an "Edit" of its own, above it).
        var viewerEditButton: XCUIElement {
            let buttons = app.buttons.matching(identifier: "Edit").allElementsBoundByIndex
            return buttons.max { $0.frame.minY < $1.frame.minY } ?? app.buttons["Edit"].firstMatch
        }

        func testLibrary() {
            launch()
            waitForTimeline()
            pause(10)
            shot("library")
            for level in ["Days", "Months", "Years"] where tapButton(level, timeout: 3) {
                pause(6)
                shot("library-\(level.lowercased())")
            }
            _ = tapButton("All Photos", timeout: 3)
            pause(3)
        }

        /// The Library around one year (`PHOTOS_UITEST_SHOT_YEAR`, default 2025, and `PHOTOS_UITEST_SHOT_MONTH`, default
        /// November): the years scrolled past the newest one, the year’s months, and the month’s days.
        func testLibraryYear() {
            app.launchArguments += ["-libraryZoomLevel", "years"]
            launch()
            let year = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", (environment("PHOTOS_UITEST_SHOT_YEAR") ?? "2025") + ",")
            )
            .firstMatch
            XCTAssertTrue(year.waitForExistence(timeout: 240), "No year card")
            pause(15)
            let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62))
            top.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.32)))
            pause(5)
            shot("library-years-scrolled")
            year.tap()
            pause(6)
            shot("library-year-months")
            let months = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", environment("PHOTOS_UITEST_SHOT_MONTH") ?? "November"))
            let month = months.firstMatch
            // A pinch in on the month (a tap opens the days at the top); XCUIElement has no pinch on visionOS.
            #if os(iOS)
                if month.waitForExistence(timeout: 5), let card = onScreen(months) {
                    card.pinch(withScale: 1.25, velocity: 1)
                    pause(6)
                    shot("library-month-days")
                }
            #endif
        }

        func testViewer() {
            launch()
            openViewer(photoId)
            shot("viewer")
            if tapButton("Info") {
                pause(4)
                shot("viewer-info")
            }
        }

        func testEditor() {
            launch()
            openViewer(editPhotoId ?? photoId)
            viewerEditButton.tap()
            XCTAssertTrue(app.buttons["Done"].firstMatch.waitForExistence(timeout: 30), "The editor did not open")
            pause(5)
            shot("editor-adjust")
            for tool in ["Presets", "Curves", "Color", "Masks", "Erase"] {
                let button = app.buttons[tool].firstMatch
                guard button.waitForExistence(timeout: 3) else { continue }
                // The tool row scrolls sideways: bring the tool on screen first.
                for _ in 0..<3 where button.frame.maxX > app.frame.maxX - 8 {
                    let adjust = app.buttons["Adjust"].firstMatch
                    let from = adjust.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 220, dy: 0))
                    from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: -200, dy: 0)))
                    pause(1)
                }
                button.tap()
                pause(3)
                showOff(tool)
                pause(3)
                shot("editor-\(tool.lowercased())")
            }
            // No Done: the app is ended, nothing is saved.
        }

        /// A visible change in the tool, so that its shot shows what it does (never saved: there is no Done).
        func showOff(_ tool: String) {
            switch tool {
            case "Presets":
                _ = tapButton("Warm", timeout: 3)
            case "Curves":
                // An S curve: the shadows down, the highlights up (the graph's place on an iPhone screen).
                #if os(iOS)
                    if UIDevice.current.userInterfaceIdiom == .phone {
                        for (x, y, dy) in [(0.637, 0.771, -0.03), (0.363, 0.897, 0.025)] {
                            let start = app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
                            start.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y + dy)))
                            pause(1)
                        }
                    }
                #endif
            case "Color":
                if tapButton("Oranges", timeout: 3) {
                    let saturation = app.sliders["Saturation"].firstMatch
                    if saturation.waitForExistence(timeout: 3) { saturation.adjust(toNormalizedSliderPosition: 0.8) }
                }
            default:
                break
            }
        }

        func testMemories() {
            launch(destination: "memories")
            pause(20)
            shot("memories")
            let memory = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'years ago' OR label CONTAINS[c] 'trip'")).firstMatch
            guard memory.waitForExistence(timeout: 10) else { return }
            memory.tap()
            pause(10)
            shot("memory")
            if tapButton("Play slideshow", timeout: 5) || tapButton("Play", timeout: 3) {
                pause(9)
                shot("memory-film")
            }
        }

        func testDestinations() {
            let environment = ProcessInfo.processInfo.environment
            let list = environment["PHOTOS_UITEST_DESTINATIONS"] ?? "collections,albums,map,places,cleanUp"
            for destination in list.split(separator: ",").map(String.init) {
                app.terminate()
                launch(destination: destination)
                pause(destination == "map" ? 25 : 18)
                shot("destination-\(destination)")
            }
        }

        func testSearch() {
            launch(destination: "search")
            pause(8)
            let field = app.searchFields.firstMatch
            if !field.waitForExistence(timeout: 5) { app.collectionViews.firstMatch.swipeDown() }
            XCTAssertTrue(field.waitForExistence(timeout: 10), "No search field")
            field.tap()
            let words = environment("PHOTOS_UITEST_SHOT_SEARCH") ?? "Lisbon 2025"
            field.typeText(words)
            pause(3)
            shot("search-typed")
            let understood = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Search for")).firstMatch
            if understood.waitForExistence(timeout: 10) { understood.tap() }
            pause(3)
            // The results, not the keyboard.
            #if os(iOS)
                if app.keyboards.firstMatch.exists { app.collectionViews.firstMatch.swipeDown(velocity: .slow) }
                pause(1)
                if app.keyboards.firstMatch.exists { field.typeText("\n") }
            #endif
            pause(12)
            shot("search-results")
        }

        /// The camera in search: typing a camera's name (`PHOTOS_UITEST_SHOT_CAMERA`, default "nikon d50") suggests it as a
        /// Camera chip, which finds the photos taken with it.
        func testCameraChip() {
            launch(destination: "search")
            pause(20)
            let field = app.searchFields.firstMatch
            if !field.waitForExistence(timeout: 5) { app.collectionViews.firstMatch.swipeDown() }
            XCTAssertTrue(field.waitForExistence(timeout: 10), "No search field")
            field.tap()
            field.typeText(environment("PHOTOS_UITEST_SHOT_CAMERA") ?? "nikon d50")
            let suggestion = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Camera'")).firstMatch
            let anyCamera = app.staticTexts["Camera"].firstMatch
            XCTAssertTrue(suggestion.waitForExistence(timeout: 15) || anyCamera.waitForExistence(timeout: 5), "No camera suggestion")
            pause(2)
            shot("search-camera-suggestion")
            if suggestion.exists { suggestion.tap() } else { anyCamera.tap() }
            pause(3)
            #if os(iOS)
                if app.keyboards.firstMatch.exists { app.collectionViews.firstMatch.swipeDown(velocity: .slow) }
                pause(1)
                if app.keyboards.firstMatch.exists { app.searchFields.firstMatch.typeText("\n") }
            #endif
            pause(10)
            shot("search-camera")
        }

        func environment(_ name: String) -> String? {
            ProcessInfo.processInfo.environment[name].flatMap { $0.isEmpty ? nil : $0 }
        }

        #if os(iOS)
            /// The first run's backup step, on a fresh install (`xcrun simctl uninstall` first: the debug login only signs
            /// in an app without an account). Left with Not now: nothing is uploaded.
            func testFirstRun() throws {
                app.launchEnvironment["PHOTOS_DEBUG_OFFER_BACKUP"] = "1"
                launch()
                let turnOn = app.buttons["first-run-backup"]
                guard turnOn.waitForExistence(timeout: 120) else {
                    throw XCTSkip("No backup step: the app already had an account (uninstall it first) or backup is set up.")
                }
                pause(3)
                shot("first-run")
                _ = tapButton("first-run-not-now", timeout: 5)
                pause(2)
            }

            /// Free up space on this device, after a backup that a run of `FreeUpTourTests` (or the app) has made: the account
            /// menu's summary, the Backup screen's offer and the free-up screen. Only looks: nothing is removed.
            func testFreeUp() {
                // With a folder: the backup of the photos of the last 90 days runs first (the device's photos are added
                // with `simctl addmedia` beforehand, photo access granted with `simctl privacy`).
                if let folder = environment("PHOTOS_UITEST_BACKUP_FOLDER") {
                    app.launchEnvironment["PHOTOS_DEBUG_BACKUP"] = folder
                    app.launchEnvironment["PHOTOS_DEBUG_BACKUP_RESET"] = "1"
                    app.launchEnvironment["PHOTOS_DEBUG_BACKUP_SINCE"] = Date().addingTimeInterval(-90 * 86_400).ISO8601Format()
                    launch()
                    pause(Double(environment("PHOTOS_UITEST_BACKUP_WAIT") ?? "") ?? 90)
                    app.terminate()
                    for name in ["PHOTOS_DEBUG_BACKUP", "PHOTOS_DEBUG_BACKUP_RESET", "PHOTOS_DEBUG_BACKUP_SINCE"] {
                        app.launchEnvironment[name] = nil
                    }
                }
                launch()
                let account = app.buttons["account-menu"].firstMatch
                XCTAssertTrue(account.waitForExistence(timeout: 60), "No account button")
                pause(15)
                account.tap()
                pause(3)
                shot("account-menu")
                app.terminate()
                launch(destination: "backup")
                pause(15)
                shot("backup-screen")
                let offer = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Free up'")).firstMatch
                guard offer.waitForExistence(timeout: 20) else {
                    XCTFail("No free-up offer on the Backup screen")
                    return
                }
                offer.tap()
                let headline = app.descendants(matching: .any)["freeUp.headline"].firstMatch
                XCTAssertTrue(headline.waitForExistence(timeout: 120), "Free up did not open")
                pause(4)
                shot("free-up")
            }

            /// Backup you can see: the device's photos in the Library with their badge, and the account menu's summary.
            /// Every upload is held and the backup folder is removed at the end. Backup stays turned on in the app's
            /// settings, so run this test last and uninstall the app afterwards (the script does), or the next launch
            /// uploads the device's photos.
            func testBackup() {
                backupFolder = "/Photos/readme-backup"
                app.launchEnvironment["PHOTOS_DEBUG_BACKUP"] = backupFolder
                app.launchEnvironment["PHOTOS_DEBUG_BACKUP_HOLD"] = "1"
                app.launchEnvironment["PHOTOS_DEBUG_BACKUP_RESET"] = "1"
                // Photos dated now, so that they are at the top of the Library (`scripts/readme-screenshots.sh` adds real
                // ones with `simctl addmedia`; else the app adds plain coloured ones).
                if let samples = environment("PHOTOS_UITEST_BACKUP_SAMPLES"), samples != "0" {
                    app.launchEnvironment["PHOTOS_DEBUG_BACKUP_SAMPLES"] = samples
                }
                addUIInterruptionMonitor(withDescription: "Photos access") { alert in
                    for title in ["Allow Full Access", "Allow Access to All Photos", "Allow"] where alert.buttons[title].exists {
                        alert.buttons[title].tap()
                        return true
                    }
                    return false
                }
                launch()
                let account = app.buttons["account-menu"].firstMatch
                XCTAssertTrue(account.waitForExistence(timeout: 60), "No account button")
                let tile = app.cells.matching(NSPredicate(format: "label CONTAINS 'Not backed up'")).firstMatch
                XCTAssertTrue(tile.waitForExistence(timeout: 90), "No device photo in the Library")
                pause(20)
                shot("backup-library")
                account.tap()
                pause(3)
                shot("backup-account-menu")
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
                pause(2)
                tile.tap()
                pause(6)
                shot("backup-viewer")
            }
        #endif
    }
#endif
