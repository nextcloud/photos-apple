// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import XCTest

/// A tour of sharing and family on iPhone (SPEC §16.7): a postcard, the weekly photo prompt, the family library and the
/// Lock Screen album. Same requirements as `SmokeTests` (`PHOTOS_UITEST_LOGIN`); screenshots are attached and, with
/// `PHOTOS_UITEST_SHOTS=<folder>`, also written there. The postcard and prompt tests change the server (a folder in
/// `/Postcards` with a public link, a "Prompt: …" album): run them against a test server and remove those afterwards.
/// The others need test data named in each test.
@MainActor
final class FamilyTourTests: XCTestCase {
    static let wait: TimeInterval = 60
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = true
        let environment = ProcessInfo.processInfo.environment
        guard let login = environment["PHOTOS_UITEST_LOGIN"], !login.isEmpty else {
            throw XCTSkip("Set PHOTOS_UITEST_LOGIN to a login link of a test server to run the UI tests.")
        }
        #if !os(iOS)
            throw XCTSkip("The tour is written for iPhone.")
        #endif
        app = XCUIApplication()
        app.launchEnvironment["PHOTOS_DEBUG_LOGIN"] = login
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        // Stickers, Insights, collages, postcards and culling are behind Advanced features (SPEC §20.4).
        app.launchArguments += ["-advancedFeatures", "YES"]
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

    func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    func waitForTimeline() {
        let library = app.tabBars.buttons["Library"].firstMatch
        _ = library.waitForExistence(timeout: 20)
        pause(2)
        if let link = URL(string: "nextcloudphotos://library") { app.open(link) }
        pause(1)
        if library.exists { library.tap() }
        XCTAssertTrue(app.collectionViews.cells.firstMatch.waitForExistence(timeout: Self.wait), "No photo appeared in the timeline")
        pause(3)
    }

    func scroll(to element: XCUIElement, maxSwipes: Int = 14) {
        var swipes = 0
        while !(element.exists && element.isHittable) && swipes < maxSwipes {
            app.swipeUp(velocity: .slow)
            swipes += 1
        }
    }

    #if os(iOS)
        func element(_ text: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        }

        /// Accepts a system alert (Photos access, deleting copies) with the button of that title.
        func acceptAlert(_ titles: [String], timeout: TimeInterval = 10) -> Bool {
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                for title in titles {
                    for button in [
                        springboard.alerts.buttons[title].firstMatch, app.alerts.buttons[title].firstMatch,
                        springboard.buttons[title].firstMatch,
                    ]
                    where button.exists && button.isHittable {
                        button.tap()
                        return true
                    }
                }
                pause(0.5)
            }
            return false
        }

        /// The postcard of photo `PHOTOS_UITEST_POSTCARD_PHOTO` (a file id; default 2874, a Barcelona photo of the test
        /// library): styles, the back with a message, sending, the sent state.
        func testPostcard() throws {
            app.launch()
            waitForTimeline()
            let fileId = ProcessInfo.processInfo.environment["PHOTOS_UITEST_POSTCARD_PHOTO"] ?? "2874"
            app.open(try XCTUnwrap(URL(string: "nextcloudphotos://photo/\(fileId)")))
            let more = app.buttons["More"].firstMatch
            XCTAssertTrue(more.waitForExistence(timeout: Self.wait), "The viewer did not open")
            pause(2)
            more.tap()
            let send = app.buttons["Send as postcard…"].firstMatch
            XCTAssertTrue(send.waitForExistence(timeout: 10), "No Send as postcard in the More menu")
            shot("01-postcard-menu")
            send.tap()
            XCTAssertTrue(element("Front of the postcard").waitForExistence(timeout: 30))
            pause(4)
            shot("02-postcard-front-classic")
            for (style, name) in [("Airmail", "03-postcard-front-airmail"), ("Vintage", "04-postcard-front-vintage")] {
                app.buttons[style].firstMatch.tap()
                pause(2)
                shot(name)
            }
            app.buttons["Back"].firstMatch.tap()
            pause(1)
            let to = app.textFields["To"].firstMatch
            XCTAssertTrue(to.waitForExistence(timeout: 5))
            to.tap()
            to.typeText("Grandma")
            let message = app.textViews.firstMatch
            message.tap()
            message.typeText("Hello from Barcelona! The square was full of music until late. Wish you were here.")
            pause(2)
            shot("05-postcard-back")
            app.buttons["Send"].firstMatch.tap()
            XCTAssertTrue(app.buttons["Share Postcard"].firstMatch.waitForExistence(timeout: 180), "The postcard was not sent")
            pause(3)
            shot("06-postcard-sent")
            element("Back of the postcard").tap()
            pause(1.5)
            shot("07-postcard-sent-front")
        }

        /// Weekly prompt: the invitation, turning it on, adding this week's photos, the card afterwards and the history.
        func testWeeklyPrompt() throws {
            app.launch()
            waitForTimeline()
            app.open(try XCTUnwrap(URL(string: "nextcloudphotos://memories")))
            pause(3)
            let turnOn = app.buttons["Turn On"].firstMatch
            if turnOn.waitForExistence(timeout: 10) {
                shot("10-prompt-invitation")
                turnOn.tap()
                pause(2)
            }
            let add = app.buttons["Add Photos"].firstMatch
            XCTAssertTrue(add.waitForExistence(timeout: 10), "No prompt card")
            shot("11-prompt-card")
            add.tap()
            pause(4)
            let tiles = app.scrollViews.buttons
            if tiles.count >= 2 {
                tiles.element(boundBy: 0).tap()
                tiles.element(boundBy: 1).tap()
            }
            pause(1)
            shot("12-prompt-picker")
            app.buttons["Add"].firstMatch.tap()
            pause(8)
            shot("13-prompt-card-with-photos")
            let past = app.buttons["Past Prompts"].firstMatch
            if past.exists {
                past.tap()
                pause(2)
                shot("14-prompt-history")
            }
        }

        /// Family library: picks the shared folder `r6-family-Family` in Settings and shows the suggestion in Memories.
        /// Nothing is moved.
        func testFamilyLibrary() throws {
            app.launch()
            waitForTimeline()
            app.openSettings(page: "library")
            let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Family Library")).firstMatch
            scroll(to: row)
            shot("20-settings-family-rows")
            row.tap()
            let folder = element("r6-family-Family")
            XCTAssertTrue(folder.waitForExistence(timeout: 30), "The shared folder was not found")
            pause(1)
            shot("21-family-setup")
            folder.tap()
            pause(2)
            shot("22-family-setup-chosen")
            app.open(try XCTUnwrap(URL(string: "nextcloudphotos://memories")))
            let review = app.buttons["Review"].firstMatch
            XCTAssertTrue(review.waitForExistence(timeout: 240), "No family suggestion in Memories")
            pause(10)
            shot("23-family-card")
            // The card moves while the cards above it load their photos: tap again when the first tap missed.
            review.tap()
            if !app.buttons["Not These"].firstMatch.waitForExistence(timeout: 8) { review.tap() }
            let opened = app.buttons["Not These"].firstMatch.waitForExistence(timeout: 30)
            if !opened, let folder = ProcessInfo.processInfo.environment["PHOTOS_UITEST_SHOTS"] {
                try? "hittable: \(review.isHittable) frame: \(review.frame)\n\(app.debugDescription)".write(
                    toFile: folder + "/24-family-review-tree.txt", atomically: true, encoding: .utf8)
            }
            XCTAssertTrue(opened, "Review did not open")
            pause(3)
            shot("24-family-review")
        }

        /// Lock Screen album: mirrors the album `r6-family-lockscreen` into the simulator's Photos library, then turns it
        /// off again (the system asks before the copies are deleted).
        func testLockScreenAlbum() throws {
            app.launch()
            waitForTimeline()
            app.openSettings(page: "library")
            let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Lock Screen Album")).firstMatch
            scroll(to: row)
            pause(1)
            shot("30-settings-lock-screen")
            row.tap()
            let album = element("r6-family-lockscreen")
            XCTAssertTrue(album.waitForExistence(timeout: 30))
            shot("31-lock-screen-picker")
            album.tap()
            _ = acceptAlert(["Allow Full Access", "Allow Access to All Photos", "Allow"], timeout: 5)
            XCTAssertTrue(element("photos on this device").waitForExistence(timeout: 60))
            pause(8)
            shot("32-lock-screen-on")
            // The copies in the device's Photos app.
            let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
            photos.activate()
            pause(4)
            let collections = photos.buttons["Collections"].firstMatch
            if collections.exists { collections.tap() }
            pause(2)
            let mirrored = photos.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Nextcloud:")).firstMatch
            for _ in 0..<6 where !mirrored.exists { photos.swipeUp(velocity: .slow) }
            shot("32b-device-photos-albums")
            if mirrored.exists {
                mirrored.tap()
                pause(3)
                shot("32c-device-photos-mirrored-album")
            }
            app.activate()
            pause(2)
            let off = app.buttons["Turn Off and Remove Copies"].firstMatch
            scroll(to: off, maxSwipes: 3)
            off.tap()
            app.buttons["Turn Off"].firstMatch.tap()
            // The system asks before the copies and the album are deleted ("Allow … to delete N photos?"). In the iOS 27.2
            // simulator XCUITest cannot press that alert's buttons; when it stays, the shot shows it and the copies wait.
            if acceptAlert(["Delete"], timeout: 20) {
                pause(3)
                XCTAssertFalse(element("still on this device").exists, "Copies are left on the device")
            }
            shot("33-lock-screen-off")
        }
    #endif
}
