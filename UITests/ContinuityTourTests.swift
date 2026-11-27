// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import XCTest

/// The first run in three steps, the tips that replace its other questions, and the phone's side of setting up Apple TV
/// (SPEC §22.2), on iPhone and iPad. Needs `PHOTOS_UITEST_LOGIN`; nothing is changed on the server except that the first
/// run test turns backup on into a folder of its own (`PHOTOS_UITEST_BACKUP_FOLDER`, default `/r12-continuity-backup`;
/// the simulator's photo library is empty unless media were added). With `PHOTOS_UITEST_SHOTS` the screenshots are
/// written there too.
@MainActor
final class ContinuityTourTests: XCTestCase {
    static let officialBundleId = "com.nextcloud.photos"
    var app: XCUIApplication!
    var login = ""

    override func setUp() async throws {
        continueAfterFailure = true
        #if !os(iOS)
            throw XCTSkip("iPhone and iPad tour.")
        #else
            guard let login = ProcessInfo.processInfo.environment["PHOTOS_UITEST_LOGIN"], !login.isEmpty else {
                throw XCTSkip("Set PHOTOS_UITEST_LOGIN to a login link of a test server to run the UI tests.")
            }
            let runner = Bundle.main.bundleIdentifier ?? ""
            try XCTSkipIf(
                runner.hasPrefix(Self.officialBundleId + ".uitests"),
                "Build the UI tests with a bundle id of your own (PHOTOS_BUNDLE_ID), not \(Self.officialBundleId).")
            self.login = login
            XCUIDevice.shared.orientation = .portrait
            app = XCUIApplication()
            app.launchEnvironment["PHOTOS_DEBUG_LOGIN"] = login
            app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        #endif
    }

    override func tearDown() async throws {
        app?.terminate()
        app = nil
    }

    func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["PHOTOS_UITEST_SHOTS"], !folder.isEmpty {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appending(path: "continuity-\(name).png"))
        }
    }

    func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Steps 2 and 3 of the first run on a new install (step 1, the login, is the debug login here): the backup step,
    /// one tap and the system's photo question, then the welcome with "Backup is on" into the Library. Counts the taps.
    /// Needs a fresh install of the app (`xcrun simctl uninstall` before the run): the debug login only logs in an app
    /// without an account.
    func testFirstRunInThreeSteps() throws {
        app.launchEnvironment["PHOTOS_DEBUG_OFFER_BACKUP"] = "1"
        app.launchEnvironment["PHOTOS_DEBUG_WELCOME"] = "transition"
        app.launchEnvironment["PHOTOS_DEBUG_WELCOME_HOLD"] = "3"
        app.launchEnvironment["PHOTOS_DEBUG_FIRST_RUN_BACKUP_FOLDER"] =
            ProcessInfo.processInfo.environment["PHOTOS_UITEST_BACKUP_FOLDER"] ?? "/r12-continuity-backup"
        app.launch()
        var taps = 0
        let turnOn = app.buttons["first-run-backup"]
        guard turnOn.waitForExistence(timeout: 60) else {
            throw XCTSkip("No backup step: the app already had an account (uninstall it first) or backup is set up.")
        }
        XCTAssertTrue(app.buttons["first-run-not-now"].exists, "No Not now")
        let title =
            app.staticTexts["Back up the photos of this iPhone?"].exists || app.staticTexts["Back up the photos of this iPad?"].exists
        XCTAssertTrue(title, "No backup question")
        shot("first-run-02-backup")
        turnOn.tap()
        taps += 1
        // The system's photo access question (unless the simulator answered it already).
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow Full Access", "Allow Access to All Photos", "Allow"] {
            let button = springboard.buttons[label].firstMatch
            if button.waitForExistence(timeout: 5) {
                shot("first-run-02b-photo-question")
                button.tap()
                taps += 1
                break
            }
        }
        // Step 3: the welcome says backup is on (hidden from VoiceOver, so only the screenshot shows it), then the Library.
        pause(1.2)
        shot("first-run-03-done")
        let library = app.tabBars.buttons["Library"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 30), "No Library after the first run")
        pause(2)
        shot("first-run-04-library")
        print("FIRST-RUN taps after the login: \(taps)")
        XCTAssertLessThanOrEqual(taps, 2, "More than two taps from the backup step to the Library")
    }

    /// The tips at the top of the Library (`PHOTOS_DEBUG_TIPS=show` shows all of them at once): one at a time, closing it
    /// shows the next.
    func testTipsInTheLibrary() {
        app.launchEnvironment["PHOTOS_DEBUG_TIPS"] = "show"
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Library"].firstMatch.waitForExistence(timeout: 60), "No Library")
        pause(4)
        shot("tips-01-first")
        let close = app.buttons["Close"].firstMatch
        if close.waitForExistence(timeout: 5) {
            close.tap()
            pause(2)
            shot("tips-02-next")
        } else {
            XCTFail("No tip with a close button in the Library")
        }
    }

    /// The phone's sheet when an Apple TV asks to be set up (`PHOTOS_DEBUG_TV_SETUP_SHEET`: no TV needed).
    func testTVSetupSheet() {
        app.launchEnvironment["PHOTOS_DEBUG_TV_SETUP_SHEET"] = "Living Room"
        app.launch()
        let title = app.staticTexts["Set Up Apple TV"]
        XCTAssertTrue(title.waitForExistence(timeout: 60), "No TV set-up sheet")
        XCTAssertTrue(app.buttons["tv-setup-continue"].exists, "No Continue")
        pause(1)
        shot("tv-setup-01-phone-sheet")
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 5), "Cancel did not close the sheet")
    }
}
