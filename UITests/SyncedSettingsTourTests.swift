// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import XCTest

/// Settings that follow the user (SPEC §22.5.2), end to end against the test server of `PHOTOS_UITEST_LOGIN`: a setting
/// changed on "another device" (written into `/.nextcloud-photos/settings.json` by the test) shows up in the app, and a
/// setting changed in the app reaches the file. Puts both back at the end (the file stays, with the default values).
@MainActor
final class SyncedSettingsTourTests: XCTestCase {
    var app: XCUIApplication!
    var server: (url: URL, user: String, password: String)?

    override func setUp() async throws {
        continueAfterFailure = true
        let environment = ProcessInfo.processInfo.environment
        guard let login = environment["PHOTOS_UITEST_LOGIN"], !login.isEmpty else {
            throw XCTSkip("Set PHOTOS_UITEST_LOGIN to a login link of a test server to run the UI tests.")
        }
        #if !os(iOS)
            throw XCTSkip("The tour is written for iPhone.")
        #endif
        server = Self.server(login)
        app = XCUIApplication()
        app.launchEnvironment["PHOTOS_DEBUG_LOGIN"] = login
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    }

    override func tearDown() async throws {
        app?.terminate()
        app = nil
    }

    static func server(_ login: String) -> (URL, String, String)? {
        guard let range = login.range(of: "server:") else { return nil }
        var values: [String: String] = [:]
        for part in login[range.lowerBound...].split(separator: "&") {
            guard let colon = part.firstIndex(of: ":") else { continue }
            values[String(part[..<colon])] = String(part[part.index(after: colon)...])
        }
        guard let address = values["server"], let url = URL(string: address), let user = values["user"], let password = values["password"]
        else { return nil }
        return (url, user, password)
    }

    var settingsFile: URL? {
        guard let server else { return nil }
        return server.url.appending(path: "remote.php/dav/files").appending(path: server.user).appending(path: ".nextcloud-photos")
            .appending(path: "settings.json")
    }

    /// A request to the test server, waited for on the run loop (the test itself stays synchronous, as the other tours).
    func send(_ method: String, _ url: URL, body: Data? = nil) -> (data: Data, status: Int)? {
        guard let server else { return nil }
        let box = ResultBox()
        Task.detached { box.value = try? await Self.request(method, url, body: body, server: server) }
        let deadline = Date().addingTimeInterval(30)
        while box.value == nil && Date() < deadline { pause(0.1) }
        return box.value
    }

    final class ResultBox: @unchecked Sendable {
        // Unchecked: the stored answer is only touched under the lock.
        private let lock = NSLock()
        private var stored: (data: Data, status: Int)?
        var value: (data: Data, status: Int)? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    nonisolated static func request(
        _ method: String, _ url: URL, body: Data?, server: (url: URL, user: String, password: String)
    ) async throws -> (data: Data, status: Int) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(
            "Basic \(Data("\(server.user):\(server.password)".utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
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

    func element(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    func testSettingsFollowTheUser() throws {
        guard let settingsFile else { throw XCTSkip("No test server") }
        // "Another device" chose memories as a strip, a moment ago.
        let stamp = Date().addingTimeInterval(-5).formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        let document = """
            {"format": "nextcloud-photos-settings", "version": 1, "kind": "settings",
             "entries": {"memoriesStyle": {"value": "strip", "modifiedAt": "\(stamp)"}}}
            """
        _ = send("MKCOL", settingsFile.deletingLastPathComponent())
        let put = send("PUT", settingsFile, body: Data(document.utf8))?.status ?? 0
        XCTAssertTrue((200..<300).contains(put), "settings.json not written (\(put))")

        app.launch()
        let library = app.tabBars.buttons["Library"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 30))
        XCTAssertTrue(app.collectionViews.cells.firstMatch.waitForExistence(timeout: 60), "No photo appeared in the timeline")
        // The settings sync after the library's sync.
        pause(8)
        app.openSettings(page: "library")
        let memories = element("Strip")
        for _ in 0..<6 where !(memories.exists && memories.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(memories.waitForExistence(timeout: 10), "The memories style of the other device was not taken over")
        shot("01-library-display-taken-over")

        // Changed here: Square tiles off reaches the file.
        let square = app.switches["Square tiles"].firstMatch
        for _ in 0..<4 where !(square.exists && square.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(square.waitForExistence(timeout: 5))
        let wasOn = (square.value as? String) == "1"
        if wasOn { square.switches.firstMatch.tap() }
        shot("02-square-tiles-off")
        let sent = fileSays { $0.contains("\"squareTiles\"") && $0.contains("\"value\" : false") }
        XCTAssertTrue(sent, "Square tiles off did not reach settings.json")

        // Back as they were (the tours after this one expect square tiles and story cards): changed here, sent.
        if wasOn, (square.value as? String) == "0" { square.switches.firstMatch.tap() }
        let picker = element("Strip")
        if picker.exists && picker.isHittable {
            picker.tap()
            let stories = app.buttons["Stories"].firstMatch
            if stories.waitForExistence(timeout: 5) { stories.tap() }
        }
        let restored = fileSays { !$0.contains("\"value\" : false") && $0.contains("\"stories\"") }
        XCTAssertTrue(restored, "The settings were not put back")

        // The switch of this device, in Settings › Advanced.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        pause(1)
        let advanced = app.buttons["settings-page-advanced"].firstMatch
        for _ in 0..<4 where !(advanced.exists && advanced.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(advanced.waitForExistence(timeout: 5), "No Advanced page")
        advanced.tap()
        pause(1)
        let sync = app.switches["Sync settings through Nextcloud"].firstMatch
        for _ in 0..<6 where !(sync.exists && sync.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(sync.waitForExistence(timeout: 5), "No Sync settings switch")
        XCTAssertEqual(sync.value as? String, "1")
        shot("03-sync-settings-switch")
    }

    /// Waits (up to 20 s) until the server's settings.json satisfies `condition`.
    func fileSays(_ condition: (String) -> Bool) -> Bool {
        guard let settingsFile else { return false }
        for _ in 0..<20 {
            pause(1)
            if let answer = send("GET", settingsFile), answer.status == 200, condition(String(decoding: answer.data, as: UTF8.self)) {
                return true
            }
        }
        return false
    }
}
