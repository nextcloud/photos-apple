// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import XCTest

/// The editor's Erase tool on iPhone (SPEC §21.5): brush over the photo, the stroke is filled in (Restore All appears),
/// Undo takes it back, Cancel leaves the photo as it was. Same requirements as `SmokeTests` (`PHOTOS_UITEST_LOGIN`);
/// screenshots are attached and, with `PHOTOS_UITEST_SHOTS=<folder>`, also written there. Nothing is saved.
@MainActor
final class EraseTourTests: XCTestCase {
    /// Generous: the simulator's first launch and the editor's first picture can be slow.
    static let wait: TimeInterval = 90
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
        func testBrushEraseUndo() {
            app.launch()
            let library = app.tabBars.buttons["Library"].firstMatch
            _ = library.waitForExistence(timeout: 20)
            pause(2)
            if library.exists { library.tap() }
            let tiles = app.collectionViews.cells
            XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: Self.wait), "No photo appeared in the timeline")
            pause(3)
            // The first photo the viewer can edit (another test's video or a read-only share may come first).
            let edit = app.buttons["Edit"].firstMatch
            var found = false
            for index in 0..<4 where !found {
                tiles.element(boundBy: index).tap()
                found = edit.waitForExistence(timeout: 15)
                if !found, app.buttons["Close"].firstMatch.exists {
                    app.buttons["Close"].firstMatch.tap()
                    pause(2)
                }
            }
            XCTAssertTrue(found, "None of the first photos has an Edit button")
            shot("r11-erase-00-viewer")
            pause(2)
            edit.tap()
            let cancel = app.buttons["Cancel"].firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: Self.wait), "The editor did not open")
            pause(4)
            app.buttons["Erase"].firstMatch.tap()
            let picture = app.images["Edited photo"].firstMatch
            XCTAssertTrue(picture.waitForExistence(timeout: Self.wait), "The Erase tool shows no picture to brush on")
            XCTAssertTrue(app.staticTexts["Tap an object to erase it, or brush over it."].firstMatch.exists)
            // The basic fill is how Erase works: nothing about installing or downloading a model.
            XCTAssertTrue(app.staticTexts["Works best on spots and small things."].firstMatch.exists)
            XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'model'")).firstMatch.exists)
            pause(2)
            shot("r11-erase-01-tool")
            let start = picture.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
            let end = picture.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.55))
            start.press(forDuration: 0.2, thenDragTo: end)
            let restore = app.buttons["Restore All"].firstMatch
            XCTAssertTrue(restore.waitForExistence(timeout: Self.wait), "The brushed stroke was not erased")
            pause(1)
            shot("r11-erase-02-brushed")
            app.buttons["Undo"].firstMatch.tap()
            pause(2)
            XCTAssertFalse(restore.exists, "Undo did not take the stroke back")
            shot("r11-erase-03-undone")
            cancel.tap()
        }
    #endif
}
