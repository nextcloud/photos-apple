// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import XCTest

#if os(iOS)
    /// Backup you can see (SPEC §21.1) on iPhone and iPad: the simulator's own photos stand in the Library with a "not
    /// backed up" badge, the account menu counts them, the viewer opens one and backs it up now, and after a backup the
    /// account menu says "All backed up".
    ///
    /// Needs `PHOTOS_UITEST_LOGIN` like the other tours; the app adds four photos of its own to the simulator's library
    /// (`PHOTOS_DEBUG_BACKUP_SAMPLES`), so it does not depend on what the simulator has. Backup goes to `PHOTOS_UITEST_BACKUP_FOLDER` (default `/Photos/ui-backup-tour`),
    /// which the test removes at the end, also from the trash bin. Debug builds only (`PHOTOS_DEBUG_BACKUP`).
    @MainActor
    final class BackupLibraryTourTests: XCTestCase {
        var app: XCUIApplication!
        private var shotsDirectory: URL?
        private var prefix = ""
        private var server: TestServer?

        override func setUp() async throws {
            continueAfterFailure = false
            let environment = ProcessInfo.processInfo.environment
            guard let login = environment["PHOTOS_UITEST_LOGIN"], !login.isEmpty else {
                throw XCTSkip("Set PHOTOS_UITEST_LOGIN to a login link of a test server to run the UI tests.")
            }
            if let path = environment["PHOTOS_UITEST_SHOTS"], !path.isEmpty {
                shotsDirectory = URL(fileURLWithPath: path)
                try? FileManager.default.createDirectory(at: URL(fileURLWithPath: path), withIntermediateDirectories: true)
            }
            prefix =
                (environment["PHOTOS_UITEST_SHOT_PREFIX"] ?? "") + (UIDevice.current.userInterfaceIdiom == .pad ? "ipad-" : "iphone-")
            let folder = environment["PHOTOS_UITEST_BACKUP_FOLDER"].flatMap { $0.isEmpty ? nil : $0 } ?? "/Photos/ui-backup-tour"
            server = TestServer(login: login, folder: folder)
            app = XCUIApplication()
            app.launchEnvironment["PHOTOS_DEBUG_LOGIN"] = login
            app.launchEnvironment["PHOTOS_DEBUG_BACKUP"] = folder
            // No pass until one is asked for: the photos stay "not backed up" for the first steps.
            app.launchEnvironment["PHOTOS_DEBUG_BACKUP_HOLD"] = "1"
            // An earlier test of the run may have logged in (and an earlier run backed these photos up): backup is turned on
            // for the account that is there, and what it uploaded before is forgotten.
            app.launchEnvironment["PHOTOS_DEBUG_BACKUP_RESET"] = "1"
            // Photos of its own, taken now: the simulator's sample photos may be on the test server already (another run backed
            // them up), and a device photo the server has is shown once, as the server's.
            app.launchEnvironment["PHOTOS_DEBUG_BACKUP_SAMPLES"] = "4"
            app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            // The photo library's permission, when the simulator has not granted it already.
            addUIInterruptionMonitor(withDescription: "Photos access") { alert in
                for title in ["Allow Full Access", "Allow Access to All Photos", "Allow"] where alert.buttons[title].exists {
                    alert.buttons[title].tap()
                    return true
                }
                return false
            }
        }

        override func tearDown() async throws {
            app?.terminate()
            app = nil
            try? await server?.removeFolder()
        }

        private func shot(_ name: String) {
            let screenshot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            guard let shotsDirectory else { return }
            try? screenshot.pngRepresentation.write(to: shotsDirectory.appending(path: "\(prefix)backup-\(name).png"))
        }

        private func pause(_ seconds: TimeInterval) {
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        }

        /// Waits for an element whose label matches; nil after `timeout`.
        private func waitFor(_ query: XCUIElementQuery, _ format: String, timeout: TimeInterval) -> XCUIElement? {
            let element = query.matching(NSPredicate(format: format)).firstMatch
            return element.waitForExistence(timeout: timeout) ? element : nil
        }

        /// Answers the photo library's permission alert, which backup asks for when it is turned on (unless the simulator
        /// granted it already).
        private func allowPhotoAccess() {
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            for _ in 0..<20 {
                for owner in [springboard, app!] {
                    let allow = owner.buttons["Allow Full Access"].firstMatch
                    if allow.exists {
                        allow.tap()
                        return
                    }
                }
                pause(1)
            }
        }

        /// No device photo in the Library: skips when the simulator has none to show (an empty photo library), fails when
        /// backup did not come on or the photos are missing although backup counts them.
        private func explainMissingDevicePhotos(_ account: XCUIElement) throws {
            account.tap()
            let summary = app.buttons.matching(NSPredicate(format: "label CONTAINS 'backed up' OR label CONTAINS 'Backing up'")).firstMatch
            guard summary.waitForExistence(timeout: 10) else {
                XCTFail("No device photo in the Library and no backup summary: backup did not turn on (photo library access?)")
                return
            }
            shot("0-no-device-photos")
            if summary.label == "All backed up" {
                throw XCTSkip(
                    "The simulator's photo library has no photos for backup. Add some first: xcrun simctl addmedia <simulator> <files> (see docs/TESTING.md)."
                )
            }
            XCTFail(
                "Backup counts “\(summary.label)” but the Library shows no device photo (are they on the server already? Then they are shown as the server's)"
            )
        }

        func testDevicePhotosInTheLibraryAndBackUpNow() throws {
            app.launch()
            let account = app.buttons["account-menu"].firstMatch
            XCTAssertTrue(account.waitForExistence(timeout: 60), "No account button")
            allowPhotoAccess()

            // The Library: the device's photos with their badge, merged by date into the server's.
            guard let tile = waitFor(app.cells, "label CONTAINS 'Not backed up'", timeout: 60) else {
                try explainMissingDevicePhotos(account)
                return
            }
            // The first sync brings the server's photos around them.
            pause(20)
            shot("1-library")

            // The account menu counts them.
            account.tap()
            // A menu's buttons are found by their title.
            let summary = app.buttons.matching(NSPredicate(format: "label CONTAINS 'backed up' OR label CONTAINS 'Backing up'")).firstMatch
            XCTAssertTrue(summary.waitForExistence(timeout: 10), "No backup summary in the account menu")
            XCTAssertTrue(summary.label.contains("not backed up"), "Summary says “\(summary.label)”")
            shot("2-account-menu")
            // Closes the menu.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
            pause(1)

            // The viewer opens a device photo; Back Up Now uploads it.
            tile.tap()
            let backUp = app.buttons["Back Up Now"].firstMatch
            XCTAssertTrue(backUp.waitForExistence(timeout: 15), "No Back Up Now in the viewer")
            pause(1)
            shot("3-viewer-not-backed-up")
            backUp.tap()
            let done = waitFor(app.descendants(matching: .any), "label BEGINSWITH 'Backed up'", timeout: 120)
            XCTAssertNotNil(done, "The photo was not backed up")
            shot("4-viewer-backed-up")
            if app.buttons["Close"].exists { app.buttons["Close"].firstMatch.tap() } else { app.swipeDown() }
            pause(2)

            // Back up the rest from the Backup screen, opened from the summary.
            account.tap()
            XCTAssertTrue(summary.waitForExistence(timeout: 10))
            summary.tap()
            let backUpAll = app.buttons["Back up now"].firstMatch
            if backUpAll.waitForExistence(timeout: 15) {
                shot("5-backup-screen")
                backUpAll.tap()
            }
            // Everything on the server: the summary says so.
            var allBackedUp = false
            for _ in 0..<24 where !allBackedUp {
                pause(5)
                let done = NSPredicate(format: "label CONTAINS 'Up to date' OR label CONTAINS 'Backed up'")
                allBackedUp = app.staticTexts.matching(done).firstMatch.exists
            }
            shot("6-backup-done")
            app.terminate()
            app.launchEnvironment["PHOTOS_DEBUG_BACKUP_HOLD"] = nil
            app.launchEnvironment["PHOTOS_DEBUG_BACKUP_RESET"] = nil
            app.launchEnvironment["PHOTOS_DEBUG_BACKUP_SAMPLES"] = nil
            app.launch()
            XCTAssertTrue(account.waitForExistence(timeout: 60))
            // The pass after the launch uploads the rest.
            var label = ""
            for _ in 0..<30 where label != "All backed up" {
                pause(6)
                account.tap()
                if summary.waitForExistence(timeout: 10) { label = summary.label }
                if label != "All backed up" { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap() }
            }
            XCTAssertEqual(label, "All backed up")
            shot("7-account-menu-all-backed-up")
        }
    }
#endif
