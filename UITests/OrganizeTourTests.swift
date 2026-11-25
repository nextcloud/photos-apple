// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import XCTest

/// A tour of the round-6 organising features on iPhone (SPEC §16.4): the smart album builder, the batch fixes of a
/// selection, folder rules and the Shortcuts-facing pieces that show in the app. Same requirements as `SmokeTests`
/// (`PHOTOS_UITEST_LOGIN`); screenshots are attached and, with `PHOTOS_UITEST_SHOTS=<folder>`, also written there.
/// What it saves (a smart album named "UI test smart album") it deletes again; it applies no batch fix.
@MainActor
final class OrganizeTourTests: XCTestCase {
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

    var tiles: XCUIElementQuery { app.collectionViews.cells }

    func waitForTimeline() {
        let library = app.tabBars.buttons["Library"].firstMatch
        _ = library.waitForExistence(timeout: 20)
        pause(2)
        if let link = URL(string: "nextcloudphotos://library") { app.open(link) }
        pause(1)
        if library.exists { library.tap() }
        XCTAssertTrue(app.buttons["Select"].firstMatch.waitForExistence(timeout: Self.wait), "The Library did not show")
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: Self.wait), "No photo appeared in the timeline")
        pause(3)
    }

    func scroll(to element: XCUIElement, maxSwipes: Int = 12) {
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

        /// Adds a condition of a kind through "Add Condition".
        func addCondition(_ kind: String) {
            let add = app.buttons["Add Condition"].firstMatch
            scroll(to: add)
            // After the live count has settled (it redraws the form).
            pause(4)
            add.tap()
            let option = app.buttons[kind].firstMatch
            // The menu can be slow to open in a busy simulator: once more if it did not.
            if !option.waitForExistence(timeout: 10) {
                shot("debug-add-condition-\(kind)")
                // The menu is long: its lower part may need scrolling.
                app.swipeUp(velocity: .slow)
                _ = option.waitForExistence(timeout: 5)
            }
            XCTAssertTrue(option.exists, "No \(kind) in Add Condition")
            option.tap()
            pause(1)
        }

        func testSmartAlbumBuilder() throws {
            app.launch()
            waitForTimeline()
            app.open(try XCTUnwrap(URL(string: "nextcloudphotos://smartAlbums")))
            pause(3)
            shot("01-smart-albums")
            let new = app.buttons["New Smart Album"].firstMatch
            XCTAssertTrue(new.waitForExistence(timeout: 10), "No New Smart Album")
            new.tap()
            let name = app.textFields["Name"].firstMatch
            XCTAssertTrue(name.waitForExistence(timeout: 10), "The builder did not open")
            name.tap()
            name.typeText("UI test smart album\n")
            addCondition("Rating")
            addCondition("Media type")
            pause(3)
            app.swipeDown(velocity: .slow)
            pause(1)
            shot("02-builder-rating-photo")
            addCondition("Camera")
            pause(4)
            shot("03-builder-camera")
            // Nested: a group "any of".
            let group = app.buttons["Add Group"].firstMatch
            scroll(to: group)
            group.tap()
            pause(1)
            shot("04-builder-group")
            app.swipeDown(velocity: .fast)
            app.swipeDown(velocity: .fast)
            pause(1)
            // Saved without the camera condition: remove it again (the album should show photos).
            let remove = app.buttons.matching(identifier: "Remove Condition")
            if remove.count >= 3 { remove.element(boundBy: 2).tap() }
            pause(3)
            shot("05-builder-before-save")
            app.buttons["Save"].firstMatch.tap()
            pause(4)
            shot("06-smart-albums-with-album")
            let card = element("UI test smart album")
            XCTAssertTrue(card.waitForExistence(timeout: 10), "The saved smart album is not listed")
            card.tap()
            pause(5)
            shot("07-smart-album-content")
            app.navigationBars.buttons.firstMatch.tap()
            pause(2)
            // Delete it again.
            card.press(forDuration: 1.2)
            let delete = app.buttons["Delete…"].firstMatch
            if delete.waitForExistence(timeout: 5) {
                delete.tap()
                let confirm = app.buttons["Delete smart album"].firstMatch
                if confirm.waitForExistence(timeout: 5) { confirm.tap() }
            }
            pause(2)
        }

        func testAlbumsShowSmartAlbums() throws {
            app.launch()
            waitForTimeline()
            app.open(try XCTUnwrap(URL(string: "nextcloudphotos://albums")))
            pause(4)
            shot("08-albums-with-smart-strip")
        }

        func testBatchFixSheet() {
            app.launch()
            waitForTimeline()
            app.buttons["Select"].firstMatch.tap()
            pause(1)
            for index in [0, 1, 2] where index < tiles.count { tiles.element(boundBy: index).tap() }
            pause(1)
            tiles.element(boundBy: 0).press(forDuration: 1.2)
            pause(1)
            let adjust = app.buttons["Adjust"].firstMatch
            XCTAssertTrue(adjust.waitForExistence(timeout: 10), "No Adjust in the selection's menu")
            adjust.tap()
            pause(1)
            shot("09-adjust-submenu")
            let date = app.buttons["Adjust date and time…"].firstMatch
            XCTAssertTrue(date.waitForExistence(timeout: 5))
            date.tap()
            pause(2)
            let hours = app.steppers.element(boundBy: 1)
            if hours.waitForExistence(timeout: 5) { hours.buttons["Increment"].tap() }
            pause(1)
            shot("10-fix-date-shift")
            let zone = app.switches["Taken in another time zone"].firstMatch
            if zone.exists {
                zone.switches.firstMatch.tap()
                pause(1)
            }
            app.swipeUp(velocity: .slow)
            pause(1)
            shot("11-fix-date-zone-preview")
            app.buttons["Name"].firstMatch.tap()
            pause(2)
            shot("12-fix-rename")
            app.buttons["Place"].firstMatch.tap()
            pause(3)
            shot("13-fix-place")
            app.buttons["GPS Track"].firstMatch.tap()
            pause(2)
            shot("14-fix-track")
            app.buttons["Cancel"].firstMatch.tap()
        }

        func testFolderRules() {
            app.launch()
            waitForTimeline()
            app.tabBars.buttons["Settings"].tap()
            let rules = element("Folder Rules")
            scroll(to: rules)
            pause(1)
            shot("15-settings-organize")
            rules.tap()
            pause(2)
            shot("16-folder-rules")
            let examples = app.buttons["Start from an Example"].firstMatch
            examples.tap()
            let example = app.buttons["Screenshots older than 30 days → archive"].firstMatch
            if !example.waitForExistence(timeout: 10) {
                examples.tap()
                _ = example.waitForExistence(timeout: 10)
            }
            XCTAssertTrue(example.exists, "No examples menu")
            example.tap()
            pause(4)
            shot("17-folder-rule-editor")
            app.swipeUp(velocity: .slow)
            app.swipeUp(velocity: .slow)
            pause(2)
            shot("18-folder-rule-editor-action")
            app.buttons["Cancel"].firstMatch.tap()
        }

        /// Applies a date shift and a rename to the three photos of `PHOTOS_UITEST_ORGANIZE_FOLDER` (a folder the tester
        /// made for it, never the shared test library), undoes both, and runs the folder rules. Opt-in: it changes files.
        func testApplyAndUndoInOwnFolder() throws {
            guard let folder = ProcessInfo.processInfo.environment["PHOTOS_UITEST_ORGANIZE_FOLDER"], !folder.isEmpty else {
                throw XCTSkip("Set PHOTOS_UITEST_ORGANIZE_FOLDER to a folder of your own test photos.")
            }
            app.launch()
            waitForTimeline()
            app.open(try XCTUnwrap(URL(string: "nextcloudphotos://folders/\(folder)")))
            pause(4)
            func selectAll() {
                let select = app.buttons["Select"].firstMatch
                XCTAssertTrue(select.waitForExistence(timeout: 20), "The folder did not open")
                select.tap()
                pause(1)
                for index in 0..<min(3, tiles.count) { tiles.element(boundBy: index).tap() }
                pause(1)
                tiles.element(boundBy: 0).press(forDuration: 1.2)
                let adjust = app.buttons["Adjust"].firstMatch
                XCTAssertTrue(adjust.waitForExistence(timeout: 10))
                adjust.tap()
                pause(1)
            }
            selectAll()
            app.buttons["Adjust date and time…"].firstMatch.tap()
            pause(2)
            let hours = app.steppers.element(boundBy: 1)
            if hours.waitForExistence(timeout: 5) { hours.buttons["Increment"].tap() }
            pause(1)
            app.buttons["Apply"].firstMatch.tap()
            let undo = app.buttons["Undo"].firstMatch
            XCTAssertTrue(undo.waitForExistence(timeout: 60), "No result")
            pause(1)
            shot("19-fix-date-applied")
            // Checked on the server by the tester's script while this waits.
            pause(20)
            undo.tap()
            pause(15)
            app.open(try XCTUnwrap(URL(string: "nextcloudphotos://folders/\(folder)")))
            pause(4)
            if app.buttons["Done"].firstMatch.exists { app.buttons["Done"].firstMatch.tap() }
            selectAll()
            app.buttons["Rename…"].firstMatch.tap()
            pause(3)
            app.buttons["Apply"].firstMatch.tap()
            XCTAssertTrue(undo.waitForExistence(timeout: 60), "No rename result")
            shot("20-fix-rename-applied")
            pause(20)
            undo.tap()
            pause(15)
            // Folder rules: a rule written into the server's file by the tester's script.
            for _ in 0..<4 where !app.tabBars.buttons["Settings"].exists {
                app.navigationBars.buttons.firstMatch.tap()
                pause(1)
            }
            app.tabBars.buttons["Settings"].tap()
            let rules = element("Folder Rules")
            scroll(to: rules)
            rules.tap()
            pause(4)
            let run = app.buttons["Run Rules Now"].firstMatch
            if run.waitForExistence(timeout: 20) {
                run.tap()
                pause(10)
            }
            shot("21-folder-rules-ran")
        }
    #endif
}
