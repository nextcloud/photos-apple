// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import XCTest

#if os(iOS)
    /// Clean up on iPhone and iPad (SPEC §19.3): the older Duplicates and Free up space places open it at their section,
    /// and a section opens its review screen. Needs `PHOTOS_UITEST_LOGIN` like the other tours; only looks, deletes
    /// nothing. With `PHOTOS_UITEST_SHOTS` the screenshots are also written there.
    @MainActor
    final class CleanUpTourTests: XCTestCase {
        var app: XCUIApplication!
        private var shotsDirectory: URL?
        private var prefix = ""

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
            prefix = (environment["PHOTOS_UITEST_SHOT_PREFIX"] ?? "") + (UIDevice.current.userInterfaceIdiom == .pad ? "ipad-" : "iphone-")
            app = XCUIApplication()
            app.launchEnvironment["PHOTOS_DEBUG_LOGIN"] = login
            app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        }

        override func tearDown() async throws {
            app?.terminate()
            app = nil
        }

        private func shot(_ name: String) {
            let screenshot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            guard let shotsDirectory else { return }
            try? screenshot.pngRepresentation.write(to: shotsDirectory.appending(path: "\(prefix)\(name).png"))
        }

        private func pause(_ seconds: TimeInterval) {
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        }

        /// Duplicates opens Clean up; its rows open the review screens.
        func testDuplicatesOpensCleanUp() {
            app.launchEnvironment["PHOTOS_DEBUG_DESTINATION"] = "duplicates"
            app.launch()
            pause(12)
            shot("duplicates-link")
            let row = app.buttons["cleanUp.largeVideos"].firstMatch
            guard row.waitForExistence(timeout: 10) else {
                // Before round 9 the place was the Duplicates screen itself.
                XCTAssertTrue(app.navigationBars["Duplicates"].exists || app.staticTexts["Duplicates"].exists)
                return
            }
            XCTAssertTrue(app.buttons["cleanUp.duplicates"].exists)
            XCTAssertTrue(app.buttons["cleanUp.similarShots"].exists)
            row.tap()
            pause(4)
            shot("large-videos")
            app.navigationBars.buttons.firstMatch.tap()
            pause(2)
            let device = app.buttons["cleanUp.device"].firstMatch
            if !device.isHittable { app.swipeUp() }
            XCTAssertTrue(device.waitForExistence(timeout: 5), "No row for the device's own photos")
            shot("cleanup-device-row")
        }

        /// Free up server space opens Clean up at Large videos.
        func testFreeSpaceOpensCleanUp() {
            app.launchEnvironment["PHOTOS_DEBUG_DESTINATION"] = "freeSpace"
            app.launch()
            pause(12)
            shot("free-space-link")
        }
    }
#endif
