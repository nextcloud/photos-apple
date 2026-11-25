// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import XCTest

/// The app outside its window (SPEC §15.4): the backup's Live Activity on iPhone, the memory room on Vision Pro.
///
/// Like `SmokeTests` they need `PHOTOS_UITEST_LOGIN`. The Live Activity tour also needs backup set up for that account and
/// new photos in the simulator's library (docs/TESTING.md); with `PHOTOS_UITEST_SHOTS` the screenshots are written there too.
@MainActor
final class AmbientUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = true
        let environment = ProcessInfo.processInfo.environment
        guard let login = environment["PHOTOS_UITEST_LOGIN"], !login.isEmpty else {
            throw XCTSkip("Set PHOTOS_UITEST_LOGIN to a login link of a test server to run the UI tests.")
        }
        app = XCUIApplication()
        app.launchEnvironment["PHOTOS_DEBUG_LOGIN"] = login
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
    }

    /// Keeps a screenshot with the test result, and in `PHOTOS_UITEST_SHOTS` when set.
    func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["PHOTOS_UITEST_SHOTS"], !folder.isEmpty {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appending(path: "\(name).png"))
        }
    }

    #if os(iOS)
        /// "Back up now", then the app goes to the background: the Live Activity shows in the Dynamic Island and, with
        /// Notification Center pulled down, as on the Lock Screen.
        func testBackupLiveActivity() throws {
            app.open(URL(string: "nextcloudphotos://backup")!)
            let backUp = app.buttons["Back up now"].firstMatch
            XCTAssertTrue(backUp.waitForExistence(timeout: 60), "No \"Back up now\" (is backup set up?)")
            shot("10-backup-screen")
            backUp.tap()
            // The Live Activity starts while the app is in front (the system allows it only then).
            sleep(5)
            shot("10b-backup-running")
            XCUIDevice.shared.press(.home)
            sleep(2)
            shot("11-dynamic-island")
            // Notification Center shows Live Activities as the Lock Screen does.
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.005))
            top.press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.7)))
            sleep(2)
            shot("12-lock-screen-activity")
            // Done: the activity says so and stays a while.
            sleep(40)
            shot("13-lock-screen-done")
        }

        /// Adds the Photo Frame and Backup widgets to the Home Screen through the widget gallery, as a user would.
        func testPhotoFrameWidget() throws {
            // Let the app load the library and its previews first.
            sleep(20)
            XCUIDevice.shared.press(.home)
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            addWidget(springboard, name: "Photo Frame", size: "Medium")
            addWidget(springboard, name: "Backup", size: "Small")
            springboard.buttons["Done"].firstMatch.tap()
            sleep(8)
            shot("21-home-screen-widgets")
        }

        /// Control Center ▸ + ▸ Add a Control ▸ Nextcloud Photos: the backup controls.
        func testControls() throws {
            sleep(5)
            XCUIDevice.shared.press(.home)
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.005))
                .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.6)))
            sleep(2)
            let addControls = springboard.buttons["Add Controls"].firstMatch
            XCTAssertTrue(addControls.waitForExistence(timeout: 5))
            addControls.tap()
            sleep(2)
            for identifier in ["backupToggle", "backUpNow"] {
                let addControl = springboard.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Add a Control'")).firstMatch
                XCTAssertTrue(addControl.waitForExistence(timeout: 5))
                addControl.tap()
                sleep(2)
                let control = springboard.buttons[identifier].firstMatch
                XCTAssertTrue(control.waitForExistence(timeout: 5), "No \(identifier) in the gallery")
                if identifier == "backupToggle" { shot("40-control-gallery") }
                control.tap()
                sleep(2)
            }
            shot("41-control-center-editing")
            // Leave editing: a tap on an empty spot.
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap()
            sleep(2)
            print("CC-4", springboard.debugDescription)
            shot("42-control-center")
        }

        /// The controls placed by `testControls` at work: the switch turns backup off and on in the app, "Back Up Now" runs
        /// a backup with its Live Activity (new photos in the library needed), all with the app in the background.
        func testControlActions() throws {
            sleep(5)
            XCUIDevice.shared.press(.home)
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            func openControlCenter() {
                springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.005))
                    .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.6)))
                sleep(2)
            }
            openControlCenter()
            let toggle = springboard.buttons["backupToggle"].firstMatch
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            XCTAssertEqual(toggle.value as? String, "On")
            toggle.tap()
            sleep(4)
            XCTAssertEqual(toggle.value as? String, "Off")
            shot("43-control-backup-off")
            toggle.tap()
            sleep(4)
            XCTAssertEqual(toggle.value as? String, "On")
            springboard.buttons["backUpNow"].firstMatch.tap()
            sleep(6)
            XCUIDevice.shared.press(.home)
            sleep(2)
            shot("44-control-back-up-now-island")
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.005))
                .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.7)))
            sleep(2)
            shot("45-control-back-up-now-lock-screen")
        }

        /// Home Screen ▸ Edit ▸ Add Widget ▸ Nextcloud Photos ▸ the widget's page ▸ Add Widget.
        func addWidget(_ springboard: XCUIApplication, name: String, size: String) {
            if !springboard.buttons["Done"].firstMatch.exists {
                springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).press(forDuration: 1.5)
            }
            let edit = springboard.buttons["Edit"].firstMatch
            XCTAssertTrue(edit.waitForExistence(timeout: 5))
            edit.tap()
            let add = springboard.buttons["Add Widget"].firstMatch
            XCTAssertTrue(add.waitForExistence(timeout: 5))
            add.tap()
            let ours = springboard.cells["Nextcloud Photos"].firstMatch
            XCTAssertTrue(ours.waitForExistence(timeout: 10))
            ours.tap()
            let wanted = springboard.buttons.matching(
                NSPredicate(format: "label == %@ AND value CONTAINS %@", "Nextcloud Photos, \(name)", size)
            ).firstMatch
            for _ in 0..<12 where !(wanted.exists && wanted.isHittable) {
                springboard.buttons.matching(NSPredicate(format: "value BEGINSWITH 'Widget'")).firstMatch.swipeLeft()
                sleep(1)
            }
            XCTAssertTrue(wanted.exists, "No \(name) widget")
            shot("20-gallery-\(name.lowercased().replacingOccurrences(of: " ", with: "-"))")
            springboard.buttons.matching(NSPredicate(format: "label ENDSWITH 'Add Widget'")).firstMatch.tap()
            sleep(3)
        }
    #endif

    #if os(visionOS)
        /// A memory, its "Memory Room" button, and the room around the viewer.
        func testMemoryRoom() throws {
            app.terminate()
            app.launchEnvironment["PHOTOS_DEBUG_MEMORY_ROOM_FOCUS"] = "1"
            app.launch()
            // The memories strip at the top of the library.
            let memory = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'memory'")).firstMatch
            if !memory.waitForExistence(timeout: 90) { print("VISION-1", app.debugDescription) }
            sleep(10)
            XCTAssertTrue(memory.exists, "No memory")
            shot("30-memories")
            memory.tap()
            let room = app.buttons["Memory Room"].firstMatch
            XCTAssertTrue(room.waitForExistence(timeout: 30))
            shot("31-memory")
            room.tap()
            // visionOS: XCUIScreen does not capture the room; the shots are taken with `simctl io screenshot` meanwhile.
            sleep(45)
            shot("32-memory-room")
            let leave = app.buttons["Leave Memory Room"].firstMatch
            XCTAssertTrue(leave.waitForExistence(timeout: 10))
        }
    #endif
}
