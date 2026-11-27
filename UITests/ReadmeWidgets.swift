// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import XCTest

#if os(iOS)
    /// The README's widget screenshots: the app's widgets added to the simulator's Home Screen through the system's own
    /// widget gallery, with the photos of the test server. Needs `PHOTOS_UITEST_LOGIN`; writes PNGs to
    /// `PHOTOS_UITEST_SHOTS`.
    @MainActor
    final class ReadmeWidgets: XCTestCase {
        var app: XCUIApplication!
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

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
        }

        func environment(_ name: String) -> String? {
            ProcessInfo.processInfo.environment[name].flatMap { $0.isEmpty ? nil : $0 }
        }

        func pause(_ seconds: TimeInterval) {
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        }

        func shot(_ name: String) {
            let screenshot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            guard let folder = environment("PHOTOS_UITEST_SHOTS") else { return }
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appending(path: "\(name).png"))
        }

        /// The springboard's tree next to a screenshot, for when the system's screens change.
        func dump(_ name: String) {
            shot(name)
            guard let folder = environment("PHOTOS_UITEST_SHOTS") else { return }
            try? springboard.debugDescription.write(
                to: URL(fileURLWithPath: folder).appending(path: "\(name).txt"), atomically: true, encoding: .utf8)
        }

        /// Adds one of the app's widgets through the Home Screen's widget gallery: the gallery shows the app's widgets one
        /// size after another ("Nextcloud Photos, On this day" / "Widget, Small").
        @discardableResult
        func addWidget(_ name: String, size: String) -> Bool {
            if springboard.buttons["Continue"].firstMatch.exists { springboard.buttons["Continue"].firstMatch.tap() }
            let edit = springboard.buttons["Edit"].firstMatch
            if !edit.exists {
                springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).press(forDuration: 2)
                pause(1.5)
            }
            guard edit.waitForExistence(timeout: 5) else {
                dump("widget-no-edit")
                return false
            }
            edit.tap()
            let add = springboard.buttons["Add Widget"].firstMatch
            guard add.waitForExistence(timeout: 5) else { return false }
            add.tap()
            let search = springboard.searchFields.firstMatch
            guard search.waitForExistence(timeout: 10) else { return false }
            search.tap()
            search.typeText("Nextcloud")
            let entry = springboard.cells.matching(NSPredicate(format: "label == 'Nextcloud Photos'")).firstMatch
            guard entry.waitForExistence(timeout: 10) else {
                dump("widget-no-app")
                return false
            }
            entry.tap()
            pause(2)
            let wanted = springboard.buttons.matching(
                NSPredicate(format: "label == %@ AND value CONTAINS[c] %@", "Nextcloud Photos, \(name)", size)
            ).firstMatch
            for _ in 0..<12 where !(wanted.exists && wanted.isHittable) {
                springboard.swipeLeft()
                pause(1)
            }
            guard wanted.exists else {
                dump("widget-not-found-\(name)-\(size)")
                springboard.buttons["close"].firstMatch.tap()
                return false
            }
            pause(2)
            springboard.buttons[" Add Widget"].firstMatch.tap()
            pause(2)
            return true
        }

        /// The Home Screen with the app's widgets (each with the test server's photos). The widgets are added on top of the
        /// first page, the last one first (each new one goes to the top): use a simulator whose Home Screen has none yet.
        func testHomeScreen() {
            // With a backup folder the backup runs first, so that the backup widget has something to say (the folder is
            // the test's own; grant photo access beforehand with `xcrun simctl privacy … grant photos`).
            if let folder = environment("PHOTOS_UITEST_BACKUP_FOLDER") {
                app.launchEnvironment["PHOTOS_DEBUG_BACKUP"] = folder
                app.launchEnvironment["PHOTOS_DEBUG_BACKUP_RESET"] = "1"
            }
            app.launch()
            XCTAssertTrue(app.collectionViews.cells.firstMatch.waitForExistence(timeout: 240), "No photos")
            // The first sync and the previews the widgets read from the App Group.
            pause(Double(environment("PHOTOS_UITEST_WIDGET_WAIT") ?? "") ?? 40)
            XCUIDevice.shared.press(.home)
            pause(2)
            let plan = (environment("PHOTOS_UITEST_WIDGETS") ?? "Favorites:Medium,Backup:Small,On this day:Small,Photo Frame:Medium")
                .split(separator: ",").map { $0.split(separator: ":").map(String.init) }
            for widget in plan where widget.count == 2 {
                XCTAssertTrue(addWidget(widget[0], size: widget[1]), "Could not add \(widget[0]) \(widget[1])")
            }
            let done = springboard.buttons["Done"].firstMatch
            if done.exists { done.tap() }
            pause(15)
            shot("widgets-home")
            dump("widgets-home-tree")
        }
    }
#endif
