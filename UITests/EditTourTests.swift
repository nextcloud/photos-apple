// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import XCTest

/// A tour of non-destructive editing on iPhone (SPEC §16.3): open a photo, edit it (turn), Done, the viewer shows the
/// edit, the More menu, the undo history and undoing the edit from it. Same requirements as `SmokeTests`
/// (`PHOTOS_UITEST_LOGIN`); screenshots are attached and, with `PHOTOS_UITEST_SHOTS=<folder>`, also written there. The
/// photo itself is never changed: the edit is a recipe in `.nextcloud-photos/edits/`, removed again by the undo.
@MainActor
final class EditTourTests: XCTestCase {
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

    #if os(iOS)
        func testEditUndoHistoryTour() {
            app.launch()
            let library = app.tabBars.buttons["Library"].firstMatch
            _ = library.waitForExistence(timeout: 20)
            pause(2)
            if library.exists { library.tap() }
            let tiles = app.collectionViews.cells
            XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: Self.wait), "No photo appeared in the timeline")
            pause(3)
            // A photo, not a video (the first tiles of the test library are photos).
            tiles.element(boundBy: 0).tap()
            let edit = app.buttons["Edit"].firstMatch
            XCTAssertTrue(edit.waitForExistence(timeout: Self.wait), "The viewer has no Edit button")
            pause(2)
            edit.tap()
            let done = app.buttons["Done"].firstMatch
            XCTAssertTrue(done.waitForExistence(timeout: Self.wait), "The editor did not open")
            pause(4)
            shot("r6-edit-01-editor-adjust")
            app.buttons["Crop"].firstMatch.tap()
            pause(1)
            app.buttons["Rotate Right"].firstMatch.tap()
            pause(2)
            shot("r6-edit-02-editor-crop-rotated")
            app.buttons["More"].firstMatch.tap()
            pause(1)
            shot("r6-edit-03-editor-more-menu")
            // Close the menu again (a tap outside it).
            if app.buttons["Save as Copy"].firstMatch.exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap() }
            pause(1)
            done.tap()
            pause(4)
            shot("r6-edit-04-viewer-edited")
            // The confirmation banner: "Edited IMG_… · Undo".
            XCTAssertTrue(
                app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Edited'")).firstMatch.waitForExistence(timeout: 10),
                "No confirmation after Done")
            app.buttons["More"].firstMatch.tap()
            pause(1)
            shot("r6-edit-05-viewer-more-menu")
            // The menu opens from the bottom bar: its last items are at the top, scrolled out of sight.
            let history = app.buttons["Undo history"].firstMatch
            for _ in 0..<4 where !(history.exists && history.isHittable) {
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.25))
                start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6)))
                pause(1)
            }
            shot("r6-edit-05b-viewer-more-menu-top")
            XCTAssertTrue(history.waitForExistence(timeout: 5), "No Undo history in the More menu")
            history.tap()
            pause(2)
            shot("r6-edit-06-undo-history")
            let undo = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Undo:'")).firstMatch
            XCTAssertTrue(undo.waitForExistence(timeout: 5), "The edit has no Undo in the history")
            undo.tap()
            pause(3)
            shot("r6-edit-07-undo-history-undone")
            XCTAssertTrue(app.staticTexts["Undone"].firstMatch.waitForExistence(timeout: 10), "The edit was not undone")
            app.buttons["Done"].firstMatch.tap()
            pause(3)
            shot("r6-edit-08-viewer-original-again")
        }
    #endif
}
