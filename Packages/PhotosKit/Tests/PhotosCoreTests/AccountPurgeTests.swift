// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosBackup
@testable import PhotosCore
@testable import PhotosModel
@testable import PhotosNetworking

/// What is left on disk and in the secret store after an account is removed.
@Suite struct AccountPurgeTests {
    @Test func removesEverythingOfTheOnlyAccount() throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        let account = makeAccount("alice", server: "https://Cloud.Example.com")
        try sandbox.populate(account)
        var backup = BackupSettings()
        backup.isEnabled = true
        backup.accountId = account.id
        try backup.save(to: sandbox.layout.backupSettingsFile)
        #expect(sandbox.files().count == 7)
        #expect(sandbox.secretCount() == 5)

        AccountPurge(layout: sandbox.layout, keychain: sandbox.keychain, trustStore: nil).purge(account, remaining: [])

        #expect(sandbox.files() == [])
        #expect(sandbox.secretCount() == 0)
    }

    @Test func removesPushKeysAndPassword() throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        let account = makeAccount("alice", server: "https://cloud.example.com")
        try sandbox.populate(account)
        AccountPurge(layout: sandbox.layout, keychain: sandbox.keychain, trustStore: nil).purge(account, remaining: [account])
        let id = account.id.rawValue
        #expect(sandbox.keychain.data(for: Keychain.passwordKey(id)) == nil)
        #expect(sandbox.keychain.data(for: Keychain.pushPrivateKeyKey(id)) == nil)
        #expect(sandbox.keychain.data(for: Keychain.pushRegistrationKey(id)) == nil)
    }

    @Test func keepsWhatAnotherAccountOnTheSameHostNeeds() throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        let trustStore = TrustStore(directory: sandbox.layout.certificates)
        let alice = makeAccount("alice", server: "https://cloud.example.com")
        let bob = makeAccount("bob", server: "https://CLOUD.example.com/nextcloud")
        let carol = makeAccount("carol", server: "https://other.example.org")
        for account in [alice, bob, carol] { try sandbox.populate(account, trustStore: trustStore) }
        var backup = BackupSettings()
        backup.accountId = bob.id
        try backup.save(to: sandbox.layout.backupSettingsFile)
        let purge = AccountPurge(layout: sandbox.layout, keychain: sandbox.keychain, trustStore: trustStore)
        let host = "cloud.example.com"

        purge.purge(alice, remaining: [bob, carol])

        // Alice's own data is gone …
        #expect(!FileManager.default.fileExists(atPath: sandbox.layout.accountDirectory(alice.id).path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: sandbox.layout.previews(alice.id).path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: sandbox.layout.originals(alice.id).path(percentEncoded: false)))
        #expect(sandbox.keychain.data(for: Keychain.passwordKey(alice.id.rawValue)) == nil)
        // … Bob still reaches the same server with the same certificates, and keeps his data and his backup.
        #expect(sandbox.keychain.data(for: Keychain.clientCertificateKey(host)) != nil)
        #expect(sandbox.keychain.string(for: Keychain.clientCertificatePasswordKey(host)) == "p12-password")
        #expect(
            FileManager.default.fileExists(atPath: sandbox.layout.certificates.appending(path: "\(host).der").path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: sandbox.layout.database(bob.id).path(percentEncoded: false)))
        #expect(sandbox.keychain.string(for: Keychain.passwordKey(bob.id.rawValue)) == "secret")
        #expect(BackupSettings.load(from: sandbox.layout.backupSettingsFile).accountId == bob.id)

        purge.purge(bob, remaining: [carol])

        // The last account on the host takes the host's certificates and its backup options with it.
        #expect(sandbox.keychain.data(for: Keychain.clientCertificateKey(host)) == nil)
        #expect(sandbox.keychain.data(for: Keychain.clientCertificatePasswordKey(host)) == nil)
        #expect(
            !FileManager.default.fileExists(atPath: sandbox.layout.certificates.appending(path: "\(host).der").path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: sandbox.layout.backupSettingsFile.path(percentEncoded: false)))
        // A new trust store (next launch) no longer knows the certificate either.
        #expect(sandbox.files().filter { $0.hasSuffix(".der") } == ["Library/Application Support/Certificates/other.example.org.der"])
        // Carol is untouched.
        #expect(sandbox.keychain.data(for: Keychain.clientCertificateKey("other.example.org")) != nil)
        #expect(FileManager.default.fileExists(atPath: sandbox.layout.database(carol.id).path(percentEncoded: false)))
    }
}

/// Logout, account switching and remote wipe on the app model, against a stubbed server in a temporary container.
@MainActor
@Suite struct AccountLifecycleTests {
    let sandbox = Sandbox()
    let server = StubServer()

    func makeApp() -> AppModel {
        let suite = "photos-core-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AppModel(
            appVersion: "1.0", layout: sandbox.layout, keychain: sandbox.keychain, defaults: defaults,
            httpConfiguration: server.configuration)
    }

    func login(_ app: AppModel, password: String = "app-password") async throws -> Account {
        try await app.addAccount(
            LoginService.Credentials(serverURL: server.url, loginName: "alice", appPassword: password), askForNotifications: false)
        return try #require(app.activeAccount)
    }

    @Test func logoutUnregistersPushBeforeRevokingThePassword() async throws {
        defer { sandbox.remove() }
        let app = makeApp()
        let account = try await login(app)
        try sandbox.seedPushRegistration(account, deviceIdentifier: server.host)
        try sandbox.keychain.set(Data([1]), for: Keychain.pushPrivateKeyKey(account.id.rawValue))

        await app.removeAccount(account.id)

        #expect(
            server.lines(containing: "notifications/api/v2/push", "/devices", "core/apppassword") == [
                "DELETE /ocs/v2.php/apps/notifications/api/v2/push", "DELETE /devices", "DELETE /ocs/v2.php/core/apppassword",
            ])
    }

    @Test func logoutLeavesNothingBehind() async throws {
        defer { sandbox.remove() }
        let app = makeApp()
        let account = try await login(app)
        // Everything an account accumulates while it is used.
        try sandbox.populate(account, trustStore: app.http.trustStore, liveDatabase: true)
        try sandbox.seedPushRegistration(account, deviceIdentifier: server.host)
        try sandbox.keychain.set("app-password", for: Keychain.passwordKey(account.id.rawValue))
        app.backup.update {
            $0.accountId = account.id
            $0.isEnabled = true
        }
        #expect(FileManager.default.fileExists(atPath: sandbox.layout.backupSettingsFile.path(percentEncoded: false)))
        let session = try #require(app.session)
        #expect(session.services != nil)

        await app.removeAccount(account.id)

        #expect(app.session == nil)
        #expect(app.accounts.isEmpty)
        #expect(app.backup.settings.isEnabled == false)
        #expect(app.backup.settings.accountId == nil)
        // Nothing may come back either: give stray tasks a moment, then look again.
        try await Task.sleep(for: .milliseconds(300))
        #expect(sandbox.files() == ["Library/Application Support/accounts.json"])
        #expect(sandbox.secretCount() == 0)
        #expect(AccountRegistry.load(from: sandbox.layout.accountsFile).accounts.isEmpty)
    }

    @Test func remoteWipeLeavesNothingBehind() async throws {
        defer { sandbox.remove() }
        let app = makeApp()
        let account = try await login(app)
        try sandbox.populate(account, trustStore: app.http.trustStore, liveDatabase: true)
        try sandbox.seedPushRegistration(account, deviceIdentifier: server.host)
        try sandbox.keychain.set("app-password", for: Keychain.passwordKey(account.id.rawValue))
        server.set {
            $0.unauthorized = true
            $0.wipeRequested = true
        }

        await app.handleUnauthorized(account.id)

        #expect(app.accounts.isEmpty)
        #expect(app.session == nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(sandbox.files() == ["Library/Application Support/accounts.json"])
        #expect(sandbox.secretCount() == 0)
        // The push proxy is told to forget the device, and the wipe is confirmed with the wiped token.
        let confirmations = server.requests.filter { $0.path == "/index.php/core/wipe/success" }
        #expect(confirmations.map(\.body) == ["token=app-password"])
        #expect(server.lines(containing: "/devices") == ["DELETE /devices"])
    }

    @Test func rejectedPasswordWithoutWipeKeepsTheData() async throws {
        defer { sandbox.remove() }
        let app = makeApp()
        let account = try await login(app)
        server.set { $0.unauthorized = true }

        await app.handleUnauthorized(account.id)

        #expect(app.accounts.first?.isSignedOut == true)
        #expect(app.session?.account.isSignedOut == true)
        #expect(FileManager.default.fileExists(atPath: sandbox.layout.database(account.id).path(percentEncoded: false)))
        await app.session?.shutdown(closeDatabase: true)
    }

    @Test func stillValidPasswordIsNotSignedOut() async throws {
        defer { sandbox.remove() }
        let app = makeApp()
        let account = try await login(app)
        await app.handleUnauthorized(account.id)
        #expect(app.accounts.first?.isSignedOut == false)
        await app.session?.shutdown(closeDatabase: true)
    }

    @Test func foregroundRefreshesDoNotPileUp() async throws {
        defer { sandbox.remove() }
        let app = makeApp()
        _ = try await login(app)
        let session = try #require(app.session)
        for _ in 0..<50 { session.didBecomeActive() }
        // The start-up task and at most one foreground refresh.
        #expect(session.runningTaskCount <= 2)
        #expect(await eventually { session.runningTaskCount == 0 })
        await session.shutdown(closeDatabase: true)
    }

    /// Writes accounts with passwords, as a previous launch would have left them.
    func seed(_ accounts: [Account], active: Account) throws {
        for account in accounts { try sandbox.keychain.set("password", for: Keychain.passwordKey(account.id.rawValue)) }
        try AccountRegistry(accounts: accounts, activeAccountID: active.id).save(to: sandbox.layout.accountsFile)
    }

    @Test func aReplacedSessionStopsAndIsReleased() async throws {
        defer { sandbox.remove() }
        let alice = makeAccount("alice", server: server.url.absoluteString)
        let bob = makeAccount("bob", server: server.url.absoluteString)
        try seed([alice, bob], active: alice)
        let app = makeApp()
        weak var oldSession = app.session
        weak var oldServices = app.session?.services
        weak var oldOffline = app.session?.offline
        #expect(oldSession?.account.id == alice.id)
        #expect(oldServices != nil)

        app.switchTo(bob.id)
        #expect(oldSession?.isStopped == true)
        await app.waitForRetiredSessions()

        #expect(app.activeAccount?.id == bob.id)
        // Nothing keeps the old session, its services (database connections) or its offline manager alive.
        #expect(await eventually { oldSession == nil })
        #expect(await eventually { oldOffline == nil })
        #expect(await eventually { oldServices == nil })
        await app.session?.shutdown(closeDatabase: true)
    }

    @Test func backupKeepsItsAccountWhenAnotherOneIsActive() async throws {
        defer { sandbox.remove() }
        let alice = makeAccount("alice", server: server.url.absoluteString)
        let bob = makeAccount("bob", server: server.url.absoluteString)
        try seed([alice, bob], active: bob)
        var settings = BackupSettings()
        settings.isEnabled = true
        settings.accountId = alice.id
        try settings.save(to: sandbox.layout.backupSettingsFile)

        let app = makeApp()
        #expect(app.activeAccount?.id == bob.id)
        #expect(app.backup.account?.id == alice.id)
        #expect(app.backup.isForOtherAccount)
        // The engine exists for Alice although Bob is on screen …
        #expect(app.backup.prepareEngine() != nil)
        // … and a pass really starts: it gets as far as the photo library (no access in tests) instead of being skipped.
        let outcome = await app.backup.runNow()
        if case .unavailable = outcome { Issue.record("backup did not run for its own account: \(outcome)") }

        // Removing the backup account stops its backup and forgets the options.
        await app.removeAccount(alice.id)
        #expect(app.backup.settings.isEnabled == false)
        #expect(app.backup.account?.id == bob.id)
        #expect(!FileManager.default.fileExists(atPath: sandbox.layout.accountDirectory(alice.id).path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: sandbox.layout.backupSettingsFile.path(percentEncoded: false)))
        #expect(app.activeAccount?.id == bob.id)
        await app.session?.shutdown(closeDatabase: true)
    }

    @Test func backupOfASignedOutAccountSaysSo() async throws {
        defer { sandbox.remove() }
        let app = makeApp()
        let account = try await login(app)
        app.backup.update {
            $0.accountId = account.id
            $0.isEnabled = true
        }
        app.markSignedOut(account.id)
        let outcome = await app.backup.runNow()
        guard case .unavailable(let reason) = outcome else {
            Issue.record("expected the backup to be unavailable, got \(outcome)")
            return
        }
        #expect(reason.contains("Alice"))
        #expect(app.backup.status.phase == .paused(reason))
        await app.session?.shutdown(closeDatabase: true)
    }

    @Test func optionsOfAnAccountThatNoLongerExistsAreDiscarded() throws {
        defer { sandbox.remove() }
        var settings = BackupSettings()
        settings.isEnabled = true
        settings.accountId = makeAccount("gone", server: "https://gone.example.com").id
        try settings.save(to: sandbox.layout.backupSettingsFile)
        let app = makeApp()
        #expect(app.backup.settings.isEnabled == false)
        #expect(!FileManager.default.fileExists(atPath: sandbox.layout.backupSettingsFile.path(percentEncoded: false)))
    }
}
