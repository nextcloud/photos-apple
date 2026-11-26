// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import XCTest

/// Delete two photos in the selection bar, then Undo: both must be back in their folder on the server (SPEC §20.1). Brings
/// its own photos (`TestServer`), so it runs on any server and any day; `PHOTOS_UITEST_LOGIN` as for `SmokeTests`.
/// Two timings: Undo at once (the delete may still be on its way) and Undo after the server has the photos in its trash.
@MainActor
final class UndoDeleteTourTests: XCTestCase {
    static let wait: TimeInterval = 60
    var app: XCUIApplication!

    var prefix: String { ProcessInfo.processInfo.environment["PHOTOS_UITEST_SHOT_PREFIX"] ?? "undo" }
    var login: String { ProcessInfo.processInfo.environment["PHOTOS_UITEST_LOGIN"] ?? "" }

    override func setUp() async throws {
        continueAfterFailure = false
        guard !login.isEmpty else {
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
        attachment.name = "\(prefix)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["PHOTOS_UITEST_SHOTS"], !folder.isEmpty {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(prefix)-\(name).png"))
        }
    }

    func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    var tiles: XCUIElementQuery { app.collectionViews.cells }

    func waitForToday() {
        let library = app.tabBars.buttons["Library"].firstMatch
        _ = library.waitForExistence(timeout: 20)
        pause(2)
        if let link = URL(string: "nextcloudphotos://library") { app.open(link) }
        pause(1)
        if library.exists { library.tap() }
        XCTAssertTrue(app.buttons["Select"].firstMatch.waitForExistence(timeout: Self.wait), "The Library did not show")
        XCTAssertTrue(app.staticTexts["Today"].firstMatch.waitForExistence(timeout: Self.wait), "The uploaded photos did not arrive")
        pause(2)
    }

    /// Selects the two newest photos (the test's own, under "Today"), deletes them and confirms.
    func deleteTheTwoNewest() {
        app.buttons["Select"].firstMatch.tap()
        pause(1)
        tiles.element(boundBy: 0).tap()
        tiles.element(boundBy: 1).tap()
        pause(1)
        app.buttons["Delete"].firstMatch.tap()
        pause(1.5)
        let barTop = app.frame.height * 0.8
        let confirm = app.buttons.matching(identifier: "Delete").allElementsBoundByIndex.filter { $0.frame.maxY < barTop }
        XCTAssertFalse(confirm.isEmpty, "No confirmation")
        confirm.min { $0.frame.minY < $1.frame.minY }?.tap()
    }

    /// Polls the server until `condition` holds for every photo, at most `timeout` seconds.
    func waitOnServer(
        _ what: String, names: [String], probe: UndoProbe, timeout: TimeInterval, _ condition: @escaping (Bool) -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var all = true
            for name in names where !condition(await probe.exists(name)) { all = false }
            if all { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    /// As `GridMotionTourTests.testActionFeedback` does it: the first photo made a favourite and back, then both deleted.
    func favoriteAndBack() {
        app.buttons["Select"].firstMatch.tap()
        pause(1)
        tiles.element(boundBy: 0).tap()
        pause(1)
        let favorite = app.buttons["Add to favorites"].firstMatch
        XCTAssertTrue(favorite.waitForExistence(timeout: 5), "No Add to favorites in the selection bar")
        favorite.tap()
        pause(2)
        let unfavorite = app.buttons["Remove from favorites"].firstMatch
        if unfavorite.waitForExistence(timeout: 5) { unfavorite.tap() }
        pause(2)
        tiles.element(boundBy: 1).tap()
        pause(1)
        app.buttons["Delete"].firstMatch.tap()
        pause(1.5)
        let barTop = app.frame.height * 0.8
        let confirm = app.buttons.matching(identifier: "Delete").allElementsBoundByIndex.filter { $0.frame.maxY < barTop }
        XCTAssertFalse(confirm.isEmpty, "No confirmation")
        confirm.min { $0.frame.minY < $1.frame.minY }?.tap()
    }

    func run(undoAfterServerDeleted: Bool, favoriteFirst: Bool = false) async throws {
        let folder = "Photos/UI test undo \(UUID().uuidString.prefix(8))"
        let server = try XCTUnwrap(TestServer(login: login, folder: folder), "PHOTOS_UITEST_LOGIN is not a login link")
        let probe = try XCTUnwrap(UndoProbe(login: login, folder: folder))
        addTeardownBlock { try? await server.removeFolder() }
        let names = try await server.uploadPhotos(2, prefix: "undo-check")
        app.launch()
        waitForToday()
        if favoriteFirst {
            favoriteAndBack()
        } else {
            deleteTheTwoNewest()
        }
        if undoAfterServerDeleted {
            let gone = await waitOnServer("deleted", names: names, probe: probe, timeout: 20) { !$0 }
            XCTAssertTrue(gone, "The photos were not deleted on the server")
        } else {
            pause(2)
        }
        shot(undoAfterServerDeleted ? "41-deleted-on-server" : favoriteFirst ? "44-favorite-deleted" : "40-deleted")
        // Which Undo buttons there are, and what the notices say (a failure shows whose Undo was tapped).
        let undos = app.buttons.matching(identifier: "Undo").allElementsBoundByIndex
        print("UNDO-BUTTONS \(undos.count): \(undos.map { "\($0.label) @\($0.frame)" })")
        let undo = app.buttons["Undo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 8), "No Undo after the delete")
        undo.tap()
        let back = await waitOnServer("restored", names: names, probe: probe, timeout: 20) { $0 }
        shot(undoAfterServerDeleted ? "43-undone-later" : favoriteFirst ? "45-favorite-undone" : "42-undone")
        XCTAssertTrue(back, "Undo did not bring the photos back on the server")
        XCTAssertTrue(app.staticTexts["Today"].firstMatch.waitForExistence(timeout: 10), "The photos did not come back in the app")
    }

    func testUndoRightAfterDelete() async throws {
        try await run(undoAfterServerDeleted: false)
    }

    func testUndoAfterFavoriteAndDelete() async throws {
        try await run(undoAfterServerDeleted: false, favoriteFirst: true)
    }

    func testUndoAfterTheServerDeleted() async throws {
        try await run(undoAfterServerDeleted: true)
    }
}

/// Whether a photo of the test's folder is there on the server.
struct UndoProbe {
    let files: URL
    let credentials: String

    init?(login: String, folder: String) {
        guard let range = login.range(of: "server:") else { return nil }
        var values: [String: String] = [:]
        for part in login[range.lowerBound...].split(separator: "&") {
            guard let colon = part.firstIndex(of: ":") else { continue }
            values[String(part[..<colon])] = String(part[part.index(after: colon)...])
        }
        guard let address = values["server"], let server = URL(string: address), let user = values["user"],
            let password = values["password"]
        else { return nil }
        var url = server.appending(path: "remote.php/dav/files").appending(path: user)
        for part in folder.split(separator: "/") { url = url.appending(path: String(part)) }
        files = url
        credentials = Data("\(user):\(password)".utf8).base64EncodedString()
    }

    func exists(_ name: String) async -> Bool {
        var request = URLRequest(url: files.appending(path: name))
        request.httpMethod = "PROPFIND"
        request.setValue("0", forHTTPHeaderField: "Depth")
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 207
    }
}
