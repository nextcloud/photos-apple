// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import XCTest

#if os(iOS)
    /// Free up space on this device (SPEC §22.1) on iPhone and iPad: after the backup the account menu offers "All backed
    /// up · Free up …", the free-up screen shows the size, what stays and why, the keep options and a review; the removal
    /// is checked with the server once more and confirmed by the app and the system.
    ///
    /// Needs `PHOTOS_UITEST_LOGIN` and photos of its own in the simulator's library, added with
    /// `xcrun simctl addmedia` before the run: four large ones taken about two months ago and two small ones of the
    /// last days (`PHOTOS_UITEST_FREEUP_MEDIA=1` says they are there). Backup covers only photos of the last 90 days
    /// (`PHOTOS_DEBUG_BACKUP_SINCE`), so the simulator's own sample photos are never backed up and never offered. Backup
    /// goes to `PHOTOS_UITEST_FREEUP_FOLDER` (default `r12-space-freeup`), which the test removes at the end, also from
    /// the trash bin. Removes at most the photos it added. Debug builds only.
    @MainActor
    final class FreeUpTourTests: XCTestCase {
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
            guard environment["PHOTOS_UITEST_FREEUP_MEDIA"] == "1" else {
                throw XCTSkip("Add the tour's photos with xcrun simctl addmedia and set PHOTOS_UITEST_FREEUP_MEDIA=1 (see the class).")
            }
            if let path = environment["PHOTOS_UITEST_SHOTS"], !path.isEmpty {
                shotsDirectory = URL(fileURLWithPath: path)
                try? FileManager.default.createDirectory(at: URL(fileURLWithPath: path), withIntermediateDirectories: true)
            }
            prefix =
                (environment["PHOTOS_UITEST_SHOT_PREFIX"] ?? "") + (UIDevice.current.userInterfaceIdiom == .pad ? "ipad-" : "iphone-")
            let folder = environment["PHOTOS_UITEST_FREEUP_FOLDER"].flatMap { $0.isEmpty ? nil : $0 } ?? "r12-space-freeup"
            server = TestServer(login: login, folder: folder)
            app = XCUIApplication()
            app.launchEnvironment["PHOTOS_DEBUG_LOGIN"] = login
            app.launchEnvironment["PHOTOS_DEBUG_BACKUP"] = "/" + folder
            app.launchEnvironment["PHOTOS_DEBUG_BACKUP_RESET"] = "1"
            app.launchEnvironment["PHOTOS_DEBUG_BACKUP_SINCE"] = Date().addingTimeInterval(-90 * 86_400).ISO8601Format()
            app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
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
            try? screenshot.pngRepresentation.write(to: shotsDirectory.appending(path: "\(prefix)freeup-\(name).png"))
        }

        private func pause(_ seconds: TimeInterval) {
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        }

        private func allowPhotoAccess() {
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            for _ in 0..<10 {
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

        /// What the account menu's summary said last (for the failure message).
        private var lastSummary = "(no summary)"

        /// Opens the account menu and returns its backup summary once it says `contains`; nil after `timeout`.
        private func summary(containing text: String, timeout: TimeInterval) -> XCUIElement? {
            let account = app.buttons["account-menu"].firstMatch
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                account.tap()
                // A menu's buttons are found by their title.
                let summary = app.buttons.matching(NSPredicate(format: "label CONTAINS 'backed up' OR label CONTAINS 'Backing up'"))
                    .firstMatch
                if summary.waitForExistence(timeout: 5) {
                    lastSummary = summary.label
                    if summary.label.contains(text) { return summary }
                }
                // Closes the menu.
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap()
                pause(5)
            }
            return nil
        }

        /// Audits the screen on view with the rules of `AccessibilityAuditTests` (its policy decides which findings are
        /// accepted) and fails on the others; the report goes next to the screenshots.
        private func audit(_ screen: String) throws {
            let screenshot = XCUIScreen.main.screenshot()
            let bars = AccessibilityAuditPolicy.Bars(
                tabBar: app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame : nil,
                navigationBars: app.navigationBars.allElementsBoundByIndex.map(\.frame), sidebarEdge: nil,
                scrollAreas: (app.collectionViews.allElementsBoundByIndex + app.scrollViews.allElementsBoundByIndex
                    + app.tables.allElementsBoundByIndex).map(\.frame),
                screenshot: ScreenshotSampler(screenshot.image))
            var findings: [AccessibilityAuditPolicy.Finding] = []
            let parts: [XCUIAccessibilityAuditType] = [
                .contrast, [.elementDetection, .hitRegion, .sufficientElementDescription, .trait], [.dynamicType, .textClipped],
            ]
            for part in parts {
                try app.performAccessibilityAudit(for: part) { issue in
                    findings.append(AccessibilityAuditPolicy.Finding(issue))
                    return true
                }
            }
            var report: [String] = []
            for finding in findings {
                let reason = AccessibilityAuditPolicy.accepts(finding, screen: screen, bars: bars)
                report.append((reason.map { "accepted (\($0))" } ?? "FAIL") + " — " + finding.summary)
                if reason == nil { XCTFail("\(screen): \(finding.summary)") }
            }
            if let shotsDirectory {
                let text = report.isEmpty ? "no findings\n" : report.joined(separator: "\n") + "\n"
                try? Data(text.utf8).write(to: shotsDirectory.appending(path: "\(prefix)freeup-\(screen)-audit.txt"))
            }
        }

        /// The system's question before photos are deleted (PhotoKit), answered with Delete.
        private func confirmSystemDeletion() -> Bool {
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            for _ in 0..<30 {
                for owner in [springboard, app!] {
                    let delete = owner.alerts.buttons["Delete"].firstMatch
                    if delete.exists {
                        shot("6-system-confirmation")
                        delete.tap()
                        return true
                    }
                }
                pause(1)
            }
            return false
        }

        func testFreeUpAfterBackup() throws {
            app.launch()
            XCTAssertTrue(app.buttons["account-menu"].firstMatch.waitForExistence(timeout: 60), "No account button")
            allowPhotoAccess()

            // 1. The backup uploads the tour's six photos; the account menu then offers to free up space.
            guard let offer = summary(containing: "Free up", timeout: 600) else {
                shot("0-no-offer")
                XCTFail("The account menu never offered to free up space; it said “\(lastSummary)”")
                return
            }
            XCTAssertTrue(offer.label.hasPrefix("All backed up · Free up"), "Summary says “\(offer.label)”")
            shot("1-account-menu")
            offer.tap()

            // 2. The menu opens free up: four old photos can go, the two recent ones stay.
            let headline = app.descendants(matching: .any)["freeUp.headline"].firstMatch
            XCTAssertTrue(headline.waitForExistence(timeout: 120), "Free up did not open from the account menu")
            // Four photos of the tour, plus any an earlier run kept (the simulator keeps them).
            let offered = headline.label.firstMatch(of: /(\d+) photos and videos/).flatMap { Int($0.1) } ?? 0
            XCTAssertGreaterThanOrEqual(offered, 4, "Headline says “\(headline.label)”")
            pause(1)
            shot("2-free-up")
            try audit("free-up")
            app.swipeUp()
            pause(1)
            let recent = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Recent'")).firstMatch
            XCTAssertTrue(recent.exists, "The recent photos are not listed as staying")
            shot("3-options-and-kept")
            app.swipeDown()

            // 3. The review: one photo is kept by the user.
            app.buttons["freeUp.review"].firstMatch.tap()
            let tiles = app.buttons.matching(NSPredicate(format: "value == 'Will be removed'"))
            XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 10), "No photos in the review")
            XCTAssertEqual(tiles.count, offered)
            tiles.element(boundBy: 0).tap()
            pause(1)
            shot("4-review")
            try audit("free-up-review")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(headline.waitForExistence(timeout: 10))
            XCTAssertTrue(headline.label.contains("\(offered - 1) photos and videos"), "Headline says “\(headline.label)”")

            // 4. Remove: the app asks, the server is checked once more (with checksums), the system asks.
            app.buttons["freeUp.remove"].firstMatch.tap()
            let confirm = app.buttons["Remove from this iPhone"].firstMatch
            let confirmPad = app.buttons["Remove from this iPad"].firstMatch
            XCTAssertTrue(confirm.waitForExistence(timeout: 10) || confirmPad.exists, "No confirmation")
            shot("5-confirmation")
            (confirm.exists ? confirm : confirmPad).tap()
            XCTAssertTrue(confirmSystemDeletion(), "The system did not ask before deleting")

            // 5. Moved to Recently Deleted; the kept one is offered again.
            let result = app.descendants(matching: .any)["freeUp.result"].firstMatch
            XCTAssertTrue(result.waitForExistence(timeout: 60), "No result after removing")
            XCTAssertTrue(result.label.contains("\(offered - 1) photos and videos"), "Result says “\(result.label)”")
            XCTAssertTrue(headline.waitForExistence(timeout: 60))
            XCTAssertTrue(headline.label.contains("1 photos and videos"), "Headline says “\(headline.label)”")
            shot("7-result")
        }
    }
#endif
