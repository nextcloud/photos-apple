// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import XCTest

/// Colour from the photo, album covers and Guest Mode on iPhone and iPad (SPEC §16.8). Needs `PHOTOS_UITEST_LOGIN` and
/// an own album named `PHOTOS_UITEST_ALBUM` (default "Lisbon 2025"); nothing is changed on the server (the cover sheet is
/// cancelled). With `PHOTOS_UITEST_SHOTS` the screenshots are written there too.
@MainActor
final class LookTourTests: XCTestCase {
    var app: XCUIApplication!
    var album: String { ProcessInfo.processInfo.environment["PHOTOS_UITEST_ALBUM"] ?? "Lisbon 2025" }

    override func setUp() async throws {
        continueAfterFailure = true
        #if !os(iOS)
            throw XCTSkip("iPhone and iPad tour.")
        #else
            let environment = ProcessInfo.processInfo.environment
            guard let login = environment["PHOTOS_UITEST_LOGIN"], !login.isEmpty else {
                throw XCTSkip("Set PHOTOS_UITEST_LOGIN to a login link of a test server to run the UI tests.")
            }
            app = XCUIApplication()
            app.launchEnvironment["PHOTOS_DEBUG_LOGIN"] = login
            app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            app.launch()
        #endif
    }

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

    func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    func openLink(_ route: String) {
        app.open(URL(string: "nextcloudphotos://\(route)")!)
        let open = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"].firstMatch
        if open.waitForExistence(timeout: 5) { open.tap() }
        pause(3)
    }

    var albumCard: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", album)).firstMatch
    }

    /// The albums with their covers, the card's menu and the Customize Cover sheet (cancelled).
    func testCovers() throws {
        pause(8)
        endGuestModeIfOn()
        openLink("albums")
        XCTAssertTrue(albumCard.waitForExistence(timeout: 30), "No album \(album)")
        pause(3)
        shot("look-10-albums")
        albumCard.press(forDuration: 1.2)
        let customize = app.buttons["Customize cover…"].firstMatch
        XCTAssertTrue(customize.waitForExistence(timeout: 5), "No Customize cover… in the card's menu")
        shot("look-11-album-card-menu")
        customize.tap()
        pause(3)
        shot("look-12-customize-cover")
        let depth = app.buttons["Depth"].firstMatch
        if depth.waitForExistence(timeout: 5) {
            depth.tap()
            pause(4)
            shot("look-13-customize-cover-depth")
        }
        app.buttons["Cancel"].firstMatch.tap()
        pause(1)
        albumCard.tap()
        pause(4)
        shot("look-14-album-header-tint")
    }

    /// Guest Mode from an album: the sheet, the guest's grid and viewer, and ending it (the simulator has no passcode, so
    /// it ends at once).
    func testGuestMode() throws {
        pause(8)
        endGuestModeIfOn()
        openLink("albums")
        XCTAssertTrue(albumCard.waitForExistence(timeout: 30), "No album \(album)")
        albumCard.press(forDuration: 1.2)
        let guest = app.buttons["Show to a guest…"].firstMatch
        XCTAssertTrue(guest.waitForExistence(timeout: 5), "No Show to a guest… in the card's menu")
        guest.tap()
        let start = app.buttons["Start Guest Mode"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 10), "No start sheet")
        pause(1)
        shot("look-20-guest-start-sheet")
        start.tap()
        pause(4)
        shot("look-21-guest-grid")
        XCTAssertFalse(app.tabBars.firstMatch.exists, "The app's tabs are reachable in Guest Mode")
        // Links lead nowhere while a guest looks.
        app.open(URL(string: "nextcloudphotos://settings")!)
        let open = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"].firstMatch
        if open.waitForExistence(timeout: 5) { open.tap() }
        pause(3)
        XCTAssertTrue(app.buttons["End Guest Mode"].firstMatch.waitForExistence(timeout: 5), "A link left Guest Mode")
        let tile = app.scrollViews.buttons.firstMatch
        if tile.waitForExistence(timeout: 5) {
            tile.tap()
            pause(4)
            shot("look-22-guest-viewer")
            XCTAssertFalse(app.buttons["Delete"].exists, "Delete in the guest's viewer")
            XCTAssertFalse(app.buttons["Info"].exists, "Info in the guest's viewer")
            app.buttons["Close"].firstMatch.tap()
            pause(2)
        }
        // The system asks for Face ID or the passcode (in the simulator: Features › Face ID › Matching Face, or
        // `notifyutil -p com.apple.BiometricKit_Sim.pearl.match` with Face ID enrolled).
        app.buttons["End Guest Mode"].firstMatch.tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30), "Guest Mode did not end")
        pause(2)
        shot("look-23-after-guest-mode")
    }

    /// A run that stopped in Guest Mode comes back in it (it survives a relaunch): end it first.
    func endGuestModeIfOn() {
        let end = app.buttons["End Guest Mode"].firstMatch
        guard end.waitForExistence(timeout: 3) else { return }
        end.tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30), "Guest Mode did not end")
    }

    func testSettings() throws {
        pause(5)
        endGuestModeIfOn()
        let settings = app.tabBars.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        settings.tap()
        let backdrop = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Viewer Background'")).firstMatch
        for _ in 0..<12 where !(backdrop.exists && backdrop.isHittable) {
            app.swipeUp(velocity: .slow)
            pause(0.5)
        }
        XCTAssertTrue(backdrop.exists, "No Appearance settings")
        pause(1)
        shot("look-30-settings-appearance")
    }
}
