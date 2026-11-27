// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import XCTest

/// A tour of the camera in search and of People on a server without Recognize (SPEC §22.3), on iPhone and iPad.
///
/// Like `SmokeTests` it needs `PHOTOS_UITEST_LOGIN`. The camera chip needs photos taken with a Fujifilm X100V on the
/// server (`PHOTOS_UITEST_CAMERA`, default "x100v"; round 12 put three in `/Photos/r12-people-test` on 8089). Vision
/// does not run in the simulator: People shows what it shows before any face is found. With `PHOTOS_UITEST_SHOTS` set to
/// a folder, it saves a screenshot of every step there as well as attaching it to the test.
@MainActor
final class PeopleTourTests: XCTestCase {
    var app: XCUIApplication!

    func launch(destination: String? = nil) throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let login = environment["PHOTOS_UITEST_LOGIN"], !login.isEmpty else {
            throw XCTSkip("Set PHOTOS_UITEST_LOGIN to a login link of a test server to run the UI tests.")
        }
        try XCTSkipIf(
            (Bundle.main.bundleIdentifier ?? "").hasPrefix(SmokeTests.officialBundleId + ".uitests"),
            "Build the UI tests with a bundle id of your own (PHOTOS_BUNDLE_ID).")
        app = XCUIApplication()
        app.launchEnvironment["PHOTOS_DEBUG_LOGIN"] = login
        if let destination { app.launchEnvironment["PHOTOS_DEBUG_DESTINATION"] = destination }
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
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
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
        }
    }

    /// "x100v" in the search field is offered as a camera; picked, it is a chip with the photos taken with it.
    func testCameraChip() throws {
        try launch()
        XCTAssertTrue(app.collectionViews.cells.firstMatch.waitForExistence(timeout: 60), "No photos in the timeline")
        // The camera data is read after the first sync, 500 photos a request.
        sleep(20)
        let tab = app.tabBars.buttons["Search"].firstMatch
        if tab.exists { tab.tap() } else { app.buttons["Search"].firstMatch.tap() }
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(ProcessInfo.processInfo.environment["PHOTOS_UITEST_CAMERA"] ?? "x100v")
        let suggestion = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "X100V")).firstMatch
        XCTAssertTrue(suggestion.waitForExistence(timeout: 15), "No camera suggestion")
        XCTAssertTrue(app.staticTexts["Camera"].firstMatch.exists, "The suggestion does not say it is a camera")
        shot("p1-camera-suggestion")
        suggestion.tap()
        let chip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Camera")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "No camera chip")
        XCTAssertTrue(app.staticTexts["3 results"].firstMatch.waitForExistence(timeout: 15), "Not the three X100V photos")
        sleep(2)
        shot("p2-camera-chip-results")
    }

    /// People without Recognize: the screen is there, says the device looks for people itself, and how far it is.
    func testPeopleWithoutRecognize() throws {
        try launch(destination: "people")
        let note = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "found on this device")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 60), "People does not say it finds people on this device")
        sleep(3)
        shot("p3-people-on-device")
    }
}
