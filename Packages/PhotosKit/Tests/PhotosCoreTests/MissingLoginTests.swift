// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Security
import Testing

@testable import PhotosCore
@testable import PhotosModel
@testable import PhotosNetworking

/// A login whose app password the keychain cannot keep is reported as such, not as one the server revoked.
@MainActor
@Suite struct MissingLoginTests {
    /// An unsigned build has no keychain entitlement: the last keychain refusing too is an error, not a silent success.
    @Test func aKeychainWithoutEntitlementFailsTheWrite() throws {
        #expect(try Keychain.isStored(errSecSuccess, lastAttempt: false))
        #expect(try Keychain.isStored(errSecSuccess, lastAttempt: true))
        #expect(try !Keychain.isStored(errSecMissingEntitlement, lastAttempt: false))
        #expect(throws: Keychain.KeychainError.status(errSecMissingEntitlement)) {
            try Keychain.isStored(errSecMissingEntitlement, lastAttempt: true)
        }
        #expect(throws: Keychain.KeychainError.status(errSecDuplicateItem)) {
            try Keychain.isStored(errSecDuplicateItem, lastAttempt: false)
        }
        #expect(Keychain.KeychainError.status(errSecMissingEntitlement).localizedDescription.contains("keychain"))
    }

    /// A login whose app password cannot be stored fails with that reason; no account is added, and the app password the
    /// server granted is revoked again.
    @Test func aLoginThatCannotBeStoredFailsAndIsRevoked() async throws {
        let sandbox = Sandbox()
        let server = StubServer()
        defer { sandbox.remove() }
        // A file where the secret store's directory should be: nothing can be written.
        try sandbox.write(to: sandbox.secrets)
        let defaults = try #require(UserDefaults(suiteName: "photos-core-tests-\(UUID().uuidString)"))
        let app = AppModel(
            appVersion: "1.0", layout: sandbox.layout, keychain: sandbox.keychain, defaults: defaults,
            httpConfiguration: server.configuration)
        await #expect(throws: (any Error).self) {
            try await app.addAccount(
                LoginService.Credentials(serverURL: server.url, loginName: "alice", appPassword: "pw"), askForNotifications: false)
        }
        #expect(app.accounts.isEmpty)
        #expect(app.session == nil)
        #expect(server.lines(containing: "core/apppassword") == ["DELETE /ocs/v2.php/core/apppassword"])
    }

    /// The app as it starts with this account; requests go to a stub server.
    func app(with account: Account, sandbox: Sandbox, server: StubServer) throws -> AppModel {
        try AccountRegistry(accounts: [account], activeAccountID: account.id).save(to: sandbox.layout.accountsFile)
        let defaults = try #require(UserDefaults(suiteName: "photos-core-tests-\(UUID().uuidString)"))
        return AppModel(
            appVersion: "1.0", layout: sandbox.layout, keychain: sandbox.keychain, defaults: defaults,
            httpConfiguration: server.configuration)
    }

    @Test func anAccountWithoutPasswordIsMissingItsLogin() throws {
        let sandbox = Sandbox()
        let server = StubServer()
        defer { sandbox.remove() }
        let account = makeAccount("alice", server: server.url.absoluteString)
        let session = try #require(try app(with: account, sandbox: sandbox, server: server).session)
        #expect(session.isSignedOut)
        #expect(session.isLoginMissing)
    }

    @Test func aRevokedLoginIsNotAMissingOne() throws {
        let sandbox = Sandbox()
        let server = StubServer()
        defer { sandbox.remove() }
        var account = makeAccount("bob", server: server.url.absoluteString)
        account.isSignedOut = true
        try sandbox.keychain.set("password", for: Keychain.passwordKey(account.id.rawValue))
        let revoked = try #require(try app(with: account, sandbox: sandbox, server: server).session)
        #expect(revoked.isSignedOut)
        #expect(!revoked.isLoginMissing)
    }

    @Test func aStoredLoginIsNeither() throws {
        let sandbox = Sandbox()
        let server = StubServer()
        defer { sandbox.remove() }
        let account = makeAccount("carol", server: server.url.absoluteString)
        try sandbox.keychain.set("password", for: Keychain.passwordKey(account.id.rawValue))
        let session = try #require(try app(with: account, sandbox: sandbox, server: server).session)
        #expect(!session.isLoginMissing)
        session.stop()
    }
}
