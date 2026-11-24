// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Security
import Testing

@testable import PhotosCore
@testable import PhotosModel
@testable import PhotosNetworking

/// When the app locks (SPEC §8).
@MainActor
@Suite struct AppLockTests {
    final class Setting {
        var enabled = true
        var timeout: TimeInterval = 60
    }

    func makeLock(_ setting: Setting) -> AppLock {
        AppLock(settings: { (setting.enabled, setting.timeout) })
    }

    @Test func startsLockedWhenOn() {
        let setting = Setting()
        #expect(makeLock(setting).requiresUnlock)
        setting.enabled = false
        let off = makeLock(setting)
        #expect(!off.requiresUnlock)
        off.didGoAway()
        off.didComeBack(now: Date().addingTimeInterval(3600))
        #expect(!off.requiresUnlock)
    }

    @Test func locksAfterBeingAwayForTheChosenTime() {
        let setting = Setting()
        let lock = makeLock(setting)
        lock.unlockForTesting()
        let start = Date()
        lock.didGoAway(now: start)
        lock.didComeBack(now: start.addingTimeInterval(30))
        #expect(!lock.requiresUnlock)
        lock.didGoAway(now: start.addingTimeInterval(100))
        // A second "away" (another window) doesn't restart the clock.
        lock.didGoAway(now: start.addingTimeInterval(150))
        lock.didComeBack(now: start.addingTimeInterval(160))
        #expect(lock.requiresUnlock)
    }

    @Test func immediatelyLocksAsSoonAsTheAppIsAway() {
        let setting = Setting()
        setting.timeout = 0
        let lock = makeLock(setting)
        lock.unlockForTesting()
        lock.didGoAway()
        // Locked already while away: the app switcher and a link that arrives before the window is active see the lock.
        #expect(lock.requiresUnlock)
    }

    /// A link that arrives before the window is active again finds the app locked.
    @Test func aLinkAfterTheTimeoutFindsTheAppLocked() {
        let setting = Setting()
        let lock = makeLock(setting)
        lock.unlockForTesting()
        let start = Date()
        lock.didGoAway(now: start)
        lock.refresh(now: start.addingTimeInterval(61))
        #expect(lock.requiresUnlock)
    }

    @Test func switchingTheSettingOffEndsTheLock() {
        let setting = Setting()
        let lock = makeLock(setting)
        #expect(lock.requiresUnlock)
        setting.enabled = false
        lock.settingChanged()
        #expect(!lock.isLocked)
        // Switching it on doesn't lock the app the user is looking at.
        setting.enabled = true
        lock.settingChanged()
        #expect(!lock.requiresUnlock)
    }

    /// Versions before kept the setting in the app's own defaults, where the widgets and the share extension can't read it.
    @Test func theSettingMovesToTheAppGroup() throws {
        let old = try #require(UserDefaults(suiteName: "photos-lock-old-\(UUID().uuidString)"))
        let new = try #require(UserDefaults(suiteName: "photos-lock-new-\(UUID().uuidString)"))
        old.set(true, forKey: AppLockSettings.enabledKey)
        old.set(300.0, forKey: AppLockSettings.timeoutKey)
        AppLockSettings.moveSettings(from: old, to: new)
        #expect(AppLockSettings.isEnabled(new))
        #expect(AppLockSettings.timeout(new) == 300)
        #expect(old.object(forKey: AppLockSettings.enabledKey) == nil)
        #expect(AppLockSettings.timeout(old) == AppLockSettings.defaultTimeout)
    }
}

/// The diagnostics log that survives restarts (SPEC §4.5).
@Suite struct PersistentLogTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "photos-log-tests-\(UUID().uuidString)")

    @Test func rotatesAndStaysSmall() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = PersistentLog(directory: directory, maxBytes: 1000, rotations: 2)
        for index in 0..<100 { try log.append([String(repeating: "x", count: 90) + " \(index)"]) }
        let files = Sandbox.files(in: directory).map { ($0 as NSString).lastPathComponent }
        #expect(files == ["diagnostics.1.log", "diagnostics.2.log", "diagnostics.log"])
        let sizes = try log.files.map { try #require($0.resourceValues(forKeys: [.fileSizeKey]).fileSize) }
        #expect(sizes.allSatisfy { $0 <= 1000 })
        // Oldest first, the newest line last; the oldest lines were dropped.
        let lines = log.lines()
        #expect(lines.last?.hasSuffix(" 99") == true)
        #expect(!lines.contains { $0.hasSuffix(" 0") })
        #expect(lines.count < 100)
        log.removeAll()
        #expect(Sandbox.files(in: directory).isEmpty)
    }

    @Test func entriesAreRedactedWhenWrittenAndListedByRun() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = PersistentLog(directory: directory)
        let now = Date()
        // An earlier run of the app wrote this.
        let earlier = DiagnosticsLogWriter(log: log, run: "earlier1")
        await earlier.flush(
            secrets: ["alice", "cloud.example.com"],
            enabled: true,
            entries: [
                Diagnostics.Entry(
                    date: now.addingTimeInterval(-60), level: "error", category: "sync",
                    message: "sync of alice failed at https://cloud.example.com/remote.php/dav?token=abc")
            ])
        let current = DiagnosticsLogWriter(log: log, run: "current1")
        let entries = [
            Diagnostics.Entry(date: now, level: "info", category: "backup", message: "uploading IMG_0001.HEIC"),
            Diagnostics.Entry(date: now.addingTimeInterval(1), level: "info", category: "backup", message: "done"),
        ]
        await current.flush(secrets: [], enabled: true, entries: entries)
        // Written once: a second flush with the same entries adds nothing; nothing is written when the log is off.
        await current.flush(secrets: [], enabled: true, entries: entries)
        await current.flush(
            secrets: [], enabled: false,
            entries: [Diagnostics.Entry(date: now.addingTimeInterval(5), level: "info", category: "x", message: "off")])

        let lines = log.lines()
        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("earlier1 "))
        #expect(lines[0].hasSuffix("error [sync] sync of <account> failed at <url>"))
        #expect(lines[1].hasSuffix("info [backup] uploading <file>"))
        let text = lines.joined(separator: "\n")
        for secret in ["alice", "cloud.example.com", "token", "IMG_0001"] { #expect(!text.contains(secret)) }

        // The export lists the earlier run apart; this run's entries come from the system log.
        let earlierRuns = await current.earlierRuns()
        #expect(earlierRuns.count == 1)
        let report = Diagnostics.report(
            context: Diagnostics.Context(appVersion: "1", system: "test"), entries: [], hours: 48, earlierRuns: earlierRuns)
        #expect(report.contains("Log of earlier runs of the app, kept on this device (1 entries)."))
        #expect(report.contains("earlier1 "))
    }
}

/// What account removal and unfinished logins leave behind (SPEC §8).
@Suite struct LeftoverTraceTests {
    @Test func certificatesOfHostsWithoutAccountGo() throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        let store = TrustStore(directory: sandbox.layout.certificates)
        let alice = makeAccount("alice", server: "https://cloud.example.com")
        try sandbox.populate(alice, trustStore: store)
        // Trusted during a login that was cancelled.
        try store.trust(certificate: Data([1]), for: "evil.example.net")
        let purge = AccountPurge(layout: sandbox.layout, keychain: sandbox.keychain, trustStore: store)

        purge.removeUnusedCertificates(remaining: [alice])
        #expect(store.trustedHosts == ["cloud.example.com"])
        #expect(TrustStore(directory: sandbox.layout.certificates).trustedHosts == ["cloud.example.com"])

        try store.trust(certificate: Data([1]), for: "evil.example.net")
        purge.purge(alice, remaining: [])
        #expect(store.trustedHosts.isEmpty)
        #expect(sandbox.files().filter { $0.hasSuffix(".der") }.isEmpty)
    }

    @Test func withoutALiveStoreTheFilesGo() throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        try sandbox.write(to: sandbox.layout.certificates.appending(path: "evil.example.net.der"))
        let bob = makeAccount("bob", server: "https://cloud.example.com")
        try sandbox.write(to: sandbox.layout.certificates.appending(path: "cloud.example.com.der"))
        AccountPurge(layout: sandbox.layout, keychain: sandbox.keychain, trustStore: nil).removeUnusedCertificates(remaining: [bob])
        #expect(sandbox.files() == ["Library/Application Support/Certificates/cloud.example.com.der"])
    }

    @Test func diagnosticsReportsAreRemoved() throws {
        let report = Diagnostics.exportsDirectory.appending(path: "\(UUID().uuidString)/report.txt")
        try FileManager.default.createDirectory(at: report.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: report)
        Diagnostics.removeExports()
        #expect(!FileManager.default.fileExists(atPath: report.path(percentEncoded: false)))
    }
}

/// A login that trusted a certificate and then ended without an account on that host takes the trust back.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct UnfinishedLoginTests {
    @Test func trustFromAnUnfinishedLoginIsTakenBack() async throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        let server = StubServer()
        let suite = "photos-core-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let app = AppModel(
            appVersion: "1.0", layout: sandbox.layout, keychain: sandbox.keychain, defaults: defaults,
            httpConfiguration: server.configuration)
        try await app.addAccount(
            LoginService.Credentials(serverURL: server.url, loginName: "alice", appPassword: "pw"), askForNotifications: false)
        try app.http.trustStore.trust(certificate: Data([1]), for: server.host)
        try app.http.trustStore.trust(certificate: Data([2]), for: "Evil.Example.Net")

        app.forgetUnusedTrust([server.host, "evil.example.net"])

        // The account's host keeps its certificate; the other one is gone, also on disk.
        #expect(app.http.trustStore.trustedHosts == [server.host])
        #expect(TrustStore(directory: sandbox.layout.certificates).trustedHosts == [server.host])
        await app.session?.shutdown(closeDatabase: true)
    }
}

/// "The server's certificate changed": banner state, what can be trusted, and that it ends once requests go through.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct CertificateChangeTests {
    let sandbox = Sandbox()
    let server = StubServer()

    /// A self-signed certificate (nothing trusts it): what an attacker on the network, or a renewed self-signed server, shows.
    static let certificate = Data(
        base64Encoded: """
            MIIC+zCCAeOgAwIBAgITIddj7L1kEEXD3TphHcuu4suGMDANBgkqhkiG9w0BAQsFADAdMRswGQYDVQQDDBJjbG91ZC5leGFtcGxlLnRlc3QwIB\
            cNMjYxMTIzMjEzNjU0WhgPMjEyNjEwMzAyMTM2NTRaMB0xGzAZBgNVBAMMEmNsb3VkLmV4YW1wbGUudGVzdDCCASIwDQYJKoZIhvcNAQEBBQAD\
            ggEPADCCAQoCggEBAM9BXGVie628p0nfNBHUoXLIhAsT+nz4TB/m7dk6zdF5JmY6c8c0NuC47JGQnX5Xu2jA72p7cOs6Hcez4l8ZbXt5QT603Q\
            Cq3p9O4yx64heEKWfJi7dvu42K0gu+SkQkeJ5HGYIQsji/RJ9BwqLfuS88cO8vNuLqLRlPEsIoCUNOnvepn0ntMI7EgDC+kEiPA1aCb4buoKHg\
            jTEOMQSbtmYBgCTDYDqr+3ZTORo4fArxCUZSgDtxSRUMkcs6UglwQXVkY4BnmRiAHPXRWI55pYcIFVl4XtvaPWKuXwQKg23Nn0vf+OfQpoRFLB\
            H2ZRkbKa57dXHa5xB1rHP8AJTnUtkCAwEAAaMyMDAwHQYDVR0OBBYEFGOGNdZrdlV3u7OrDWCheBCcirsyMA8GA1UdEwEB/wQFMAMBAf8wDQYJ\
            KoZIhvcNAQELBQADggEBAINh9nSnEnFNwx6iEmi75URO8/S+SsVOCigM+hIyWaUMGPQvNbWcQizLwYta9pCB5ckZSIgHptb2/ki8c6E06JY3GP\
            ozeH5czqkRhqyXvGJrDvYBHTH585OoyQ4fudonZrPvBS2RK5VgBmQsiS4tUHEH9NCST3Bx/JUfbTi4Y0RhgcSkuQaOGHoS6citd5nxkyJZm1SE\
            cf6MtXZT+qCIDxi/ft9pOKo22aLdT6PEybmExJSUM5qFqgBxZhmLCEvmykTdFQTQc8ljTuL4cB6KeaX+npqZwL16oCuCO9AnwjeDsQNT0Q/QtC\
            8vpPCxBaeVQK+TNJnPZPk/OvadliYvom8=
            """)!

    func serverTrust() throws -> SecTrust {
        let certificate = try #require(SecCertificateCreateWithData(nil, Self.certificate as CFData))
        var trust: SecTrust?
        #expect(SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, server.host as CFString), &trust) == errSecSuccess)
        return try #require(trust)
    }

    func makeSession() async throws -> (AppModel, SessionModel, SessionDelegate) {
        let account = makeAccount("alice", server: server.url.absoluteString)
        try sandbox.keychain.set("password", for: Keychain.passwordKey(account.id.rawValue))
        try AccountRegistry(accounts: [account], activeAccountID: account.id).save(to: sandbox.layout.accountsFile)
        let defaults = try #require(UserDefaults(suiteName: "photos-core-tests-\(UUID().uuidString)"))
        let app = AppModel(
            appVersion: "1.0", layout: sandbox.layout, keychain: sandbox.keychain, defaults: defaults,
            httpConfiguration: server.configuration)
        let session = try #require(app.session)
        await session.syncNow()
        let delegate = try #require(app.http.session.delegate as? SessionDelegate)
        return (app, session, delegate)
    }

    /// The server was trusted by the system and now shows a certificate nothing trusts: shown, but not trustable in place.
    @Test func aSystemTrustedServerCantBeTrustedInPlace() async throws {
        defer { sandbox.remove() }
        let (app, session, delegate) = try await makeSession()
        #expect(try !delegate.accepts(serverTrust(), host: server.host))
        session.refreshCertificateProblem()
        let problem = try #require(session.certificateProblem)
        #expect(problem.certificate == Self.certificate)
        #expect(!problem.canTrustInApp)

        await session.trust(problem)
        #expect(app.http.trustStore.trustedCertificate(for: server.host) == nil)
        #expect(session.certificateProblem != nil)
        await app.session?.shutdown(closeDatabase: true)
    }

    /// Requests that go through (here over the stubbed connection, which asks no trust question) end the state: the banner
    /// doesn't stay while syncs succeed.
    @Test func theBannerEndsWhenSyncsSucceed() async throws {
        defer { sandbox.remove() }
        let (app, session, delegate) = try await makeSession()
        #expect(try !delegate.accepts(serverTrust(), host: server.host))
        session.refreshCertificateProblem()
        #expect(session.certificateProblem != nil)

        await session.syncNow()

        #expect(session.certificateProblem == nil)
        await app.session?.shutdown(closeDatabase: true)
    }

    /// A renewed self-signed certificate: the one trusted before is shown next to the new one, and the new one can be trusted.
    @Test func aRenewedSelfSignedCertificateCanBeTrusted() async throws {
        defer { sandbox.remove() }
        let (app, session, delegate) = try await makeSession()
        let old = Data([0x30, 0x01, 0x02])
        try app.http.trustStore.trust(certificate: old, for: server.host)
        #expect(try !delegate.accepts(serverTrust(), host: server.host))
        session.refreshCertificateProblem()
        let problem = try #require(session.certificateProblem)
        #expect(problem.canTrustInApp)
        #expect(problem.previouslyTrusted == old)
        #expect(problem.previous == old)

        await session.trust(problem)

        #expect(app.http.trustStore.trustedCertificate(for: server.host) == Self.certificate)
        #expect(try delegate.accepts(serverTrust(), host: server.host))
        #expect(session.certificateProblem == nil)
        await app.session?.shutdown(closeDatabase: true)
    }
}

/// The Mac counts windows: the app is away only when none of them is in front.
@MainActor
@Suite struct MacWindowLockTests {
    @Test func closingOneOfTwoWindowsIsNotAway() {
        let lock = AppLock(settings: { (true, 60) })
        lock.unlockForTesting()
        let main = UUID()
        let settings = UUID()
        let start = Date()
        lock.windowDidBecomeActive(main, now: start)
        lock.windowDidBecomeActive(settings, now: start)
        lock.windowDidLeave(settings, now: start)
        // Long after, the main window is still in front: nothing locks.
        lock.windowDidBecomeActive(settings, now: start.addingTimeInterval(600))
        #expect(!lock.requiresUnlock)
        // Both minimised for longer than the timeout: locked when one comes back.
        lock.windowDidLeave(main, now: start.addingTimeInterval(700))
        lock.windowDidLeave(settings, now: start.addingTimeInterval(700))
        lock.windowDidBecomeActive(main, now: start.addingTimeInterval(800))
        #expect(lock.requiresUnlock)
    }
}
