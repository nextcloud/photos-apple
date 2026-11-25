// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosNetworking
import Testing

@testable import PhotosCore

/// The welcome into the Library plays after the first login only (SPEC §17.6.3).
@MainActor
@Suite(.timeLimit(.minutes(1))) struct WelcomeFlagTests {
    @Test func onlyTheFirstAccountIsWelcomed() async throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        let server = StubServer()
        let defaults = try #require(UserDefaults(suiteName: "photos-core-tests-\(UUID().uuidString)"))
        let app = AppModel(
            appVersion: "1.0", layout: sandbox.layout, keychain: sandbox.keychain, defaults: defaults,
            httpConfiguration: server.configuration)
        let credentials = LoginService.Credentials(serverURL: server.url, loginName: "alice", appPassword: "pw")
        #expect(!app.welcomesFirstLogin)

        try await app.addAccount(credentials, askForNotifications: false, offerBackup: false)
        #expect(app.welcomesFirstLogin)
        app.finishWelcome()
        #expect(!app.welcomesFirstLogin)

        // Logging in again with an account already there: no welcome.
        try await app.addAccount(credentials, askForNotifications: false, offerBackup: false)
        #expect(!app.welcomesFirstLogin)
        await app.session?.shutdown(closeDatabase: true)
    }

    @Test func aLoginCanSkipTheWelcome() async throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        let server = StubServer()
        let defaults = try #require(UserDefaults(suiteName: "photos-core-tests-\(UUID().uuidString)"))
        let app = AppModel(
            appVersion: "1.0", layout: sandbox.layout, keychain: sandbox.keychain, defaults: defaults,
            httpConfiguration: server.configuration)
        try await app.addAccount(
            LoginService.Credentials(serverURL: server.url, loginName: "alice", appPassword: "pw"), askForNotifications: false,
            offerBackup: false, welcome: false)
        #expect(!app.welcomesFirstLogin)
        await app.session?.shutdown(closeDatabase: true)
    }
}
