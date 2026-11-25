// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import XCTest

/// Album cards, hero headers and the zoom transitions into albums, memories and places on iPhone and iPad (SPEC §17.4).
/// Needs `PHOTOS_UITEST_LOGIN` and an own album named `PHOTOS_UITEST_ALBUM` (default "Lisbon 2025"); nothing is changed
/// on the server (a long album `PHOTOS_UITEST_LONG_ALBUM`, default "r7-albums-long", is used if it exists). With `PHOTOS_UITEST_SHOTS` the screenshots are written there too (prefix `PHOTOS_UITEST_SHOT_PREFIX`).
/// `PHOTOS_UITEST_REDUCE_MOTION=1` and `PHOTOS_UITEST_REDUCE_TRANSPARENCY=1` switch those settings on for the app.
@MainActor
final class AlbumsMotionTourTests: XCTestCase {
    var app: XCUIApplication!
    var environment: [String: String] { ProcessInfo.processInfo.environment }
    var album: String { environment["PHOTOS_UITEST_ALBUM"] ?? "Lisbon 2025" }
    /// An own album with a few screens of photos (optional), for the hero header's scrolling.
    var longAlbum: String { environment["PHOTOS_UITEST_LONG_ALBUM"] ?? "r7-albums-long" }

    override func setUp() async throws {
        continueAfterFailure = true
        #if !os(iOS)
            throw XCTSkip("iPhone and iPad tour.")
        #else
            guard let login = environment["PHOTOS_UITEST_LOGIN"], !login.isEmpty else {
                throw XCTSkip("Set PHOTOS_UITEST_LOGIN to a login link of a test server to run the UI tests.")
            }
            app = XCUIApplication()
            app.launchEnvironment["PHOTOS_DEBUG_LOGIN"] = login
            app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            if environment["PHOTOS_UITEST_REDUCE_MOTION"] == "1" {
                app.launchArguments += ["-UIAccessibilityReduceMotionEnabled", "YES"]
            }
            if environment["PHOTOS_UITEST_REDUCE_TRANSPARENCY"] == "1" {
                app.launchArguments += ["-UIAccessibilityReduceTransparencyEnabled", "YES"]
            }
            app.launch()
        #endif
    }

    func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let prefix = environment["PHOTOS_UITEST_SHOT_PREFIX"] ?? ""
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = prefix + name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = environment["PHOTOS_UITEST_SHOTS"], !folder.isEmpty {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appending(path: "\(prefix)\(name).png"))
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

    func button(startingWith prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    func back() {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.waitForExistence(timeout: 3) { back.tap() }
        pause(2)
    }

    /// The album cards, an album's hero header (top, scrolled, pulled down) and back.
    func testAlbums() throws {
        pause(8)
        openLink("albums")
        let card = button(startingWith: album)
        XCTAssertTrue(card.waitForExistence(timeout: 30), "No album \(album)")
        pause(4)
        shot("albums-10-cards")
        app.swipeUp(velocity: .slow)
        pause(1.5)
        shot("albums-11-cards-scrolled")
        app.swipeDown(velocity: .slow)
        pause(1.5)
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        pause(0.2)
        shot("albums-20-zoom-in-progress")
        pause(3.5)
        shot("albums-21-album-hero")
        back()
        shot("albums-24-back-to-cards")
        // A long album: scrolled, the title goes into the bar; pulled down, the cover stretches.
        let long = button(startingWith: longAlbum)
        for _ in 0..<6 where !long.isHittable {
            app.swipeUp(velocity: .slow)
            pause(0.5)
        }
        guard long.exists else { return }
        long.tap()
        // Its photos come from the server the first time; Select is enabled once there are photos.
        let select = app.buttons["Select"].firstMatch
        let loaded = expectation(for: NSPredicate(format: "exists == true AND enabled == true"), evaluatedWith: select)
        wait(for: [loaded], timeout: 90)
        pause(4)
        shot("albums-25-long-album-hero")
        app.swipeUp(velocity: .slow)
        pause(1.5)
        shot("albums-26-long-album-collapsed")
        app.swipeDown(velocity: .fast)
        app.swipeDown(velocity: .fast)
        pause(1.5)
        shot("albums-27-long-album-top-again")

    }

    /// Memories: the cards, one memory's hero header, back.
    func testMemories() throws {
        pause(8)
        openLink("memories")
        pause(3)
        shot("albums-30-memories")
        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS ', memory'")).firstMatch
        guard card.waitForExistence(timeout: 15) else { throw XCTSkip("No memories on this server.") }
        card.tap()
        pause(0.2)
        shot("albums-31-memory-zoom-in-progress")
        pause(3.5)
        shot("albums-32-memory-hero")
        back()
        shot("albums-33-back-to-memories")
    }

    /// Places: a place's grid, and the map from the toolbar.
    func testPlaces() throws {
        pause(8)
        openLink("places")
        pause(3)
        shot("albums-40-places")
        let tile = app.scrollViews.buttons.matching(NSPredicate(format: "label CONTAINS 'place'")).firstMatch
        guard tile.waitForExistence(timeout: 15) else { throw XCTSkip("No places on this server.") }
        tile.tap()
        pause(0.2)
        shot("albums-41-place-zoom-in-progress")
        pause(3)
        shot("albums-42-place")
        back()
        let map = app.navigationBars.buttons["Map"].firstMatch
        if map.waitForExistence(timeout: 5) {
            map.tap()
            pause(0.2)
            shot("albums-43-map-zoom-in-progress")
            pause(3)
            shot("albums-44-map")
        }
    }
}
