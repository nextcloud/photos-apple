// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import Synchronization
import Testing

@testable import PhotosCore
@testable import PhotosDomain
@testable import PhotosModel
@testable import PhotosNetworking
@testable import PhotosStore

/// The MDM / AppConfig keys of SPEC §5.1.9.
@Suite struct ManagedConfigurationTests {
    @Test func nothingConfiguredIsNotManaged() {
        #expect(!ManagedConfiguration(nil).isManaged)
        #expect(!ManagedConfiguration([:]).isManaged)
        #expect(!ManagedConfiguration(["unrelated": true, ManagedConfiguration.Key.serverURL: 5]).isManaged)
    }

    @Test func theFilesAppKeysAreRead() {
        let configuration = ManagedConfiguration([
            "serverUrl": " cloud.example.com/ ", "username": "alice", "disable_multiaccount": true,
            "enforce_passcode_lock": NSNumber(value: 1),
            "disable_log": "true", "disable_backup": "YES",
        ])
        #expect(configuration.serverURL == URL(string: "https://cloud.example.com"))
        #expect(configuration.userName == "alice")
        #expect(configuration.disablesMultipleAccounts)
        #expect(configuration.enforcesAppLock)
        #expect(configuration.disablesLog)
        #expect(configuration.disablesBackup)
    }

    @Test func falseAndGarbageAreOff() {
        let configuration = ManagedConfiguration([
            "disable_multiaccount": false, "enforce_passcode_lock": "no", "disable_log": 0, "disable_backup": ["x"], "username": "  ",
        ])
        #expect(configuration == ManagedConfiguration())
    }

    @Test func onlyTheManagedServerCanBeLoggedInTo() {
        let configuration = ManagedConfiguration(["serverUrl": "https://cloud.example.com/nextcloud"])
        #expect(configuration.loginRefusal(serverURL: URL(string: "https://cloud.example.com/nextcloud")!) == nil)
        #expect(configuration.loginRefusal(serverURL: URL(string: "https://CLOUD.example.com:443/nextcloud/")!) == nil)
        #expect(configuration.loginRefusal(serverURL: URL(string: "https://cloud.example.com")!) != nil)
        #expect(configuration.loginRefusal(serverURL: URL(string: "https://evil.example.com/nextcloud")!) != nil)
        // Managed with https: the same host over http is not the same server.
        #expect(configuration.loginRefusal(serverURL: URL(string: "http://cloud.example.com/nextcloud")!) != nil)
        #expect(ManagedConfiguration().loginRefusal(serverURL: URL(string: "https://any.example.com")!) == nil)
    }

    @Test func aSecondAccountIsRefusedButLoggingInAgainIsNot() {
        let configuration = ManagedConfiguration(["disable_multiaccount": true])
        let alice = makeAccount("alice", server: "https://cloud.example.com")
        let server = URL(string: "https://cloud.example.com")!
        #expect(configuration.loginRefusal(serverURL: server, loginName: "bob", existing: []) == nil)
        #expect(configuration.loginRefusal(serverURL: server, loginName: "bob", existing: [alice]) == .multipleAccounts)
        #expect(configuration.loginRefusal(serverURL: server, loginName: "alice", existing: [alice]) == nil)
        #expect(configuration.allowsAddingAccount(existing: []))
        #expect(!configuration.allowsAddingAccount(existing: [alice]))
        #expect(ManagedConfiguration().allowsAddingAccount(existing: [alice]))
    }

    @Test func theUserNameIsProposedOnTheLoginPage() {
        let page = URL(string: "https://cloud.example.com/login/v2/flow/abc")!
        #expect(ManagedConfiguration().loginPage(page) == page)
        #expect(
            ManagedConfiguration(["username": "a b@c"]).loginPage(page).absoluteString
                == "https://cloud.example.com/login/v2/flow/abc?user=a%20b@c")
    }
}

/// The app follows the managed configuration at launch and when it changes.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct ManagedPolicyTests {
    let sandbox = Sandbox()
    let server = StubServer()

    func makeApp(_ defaults: UserDefaults, system: SystemTraces = .none) -> AppModel {
        AppModel(
            appVersion: "1.0", layout: sandbox.layout, keychain: sandbox.keychain, defaults: defaults,
            httpConfiguration: server.configuration, system: system)
    }

    func makeDefaults() -> UserDefaults {
        let suite = "photos-core-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func aLoginToAnotherServerIsRefusedAndItsPasswordRevoked() async throws {
        defer { sandbox.remove() }
        let defaults = makeDefaults()
        defaults.set(["serverUrl": "https://managed.example.com"], forKey: ManagedConfiguration.defaultsKey)
        let app = makeApp(defaults)
        await #expect(throws: LoginRefusal.otherServer(URL(string: "https://managed.example.com")!)) {
            try await app.addAccount(
                LoginService.Credentials(serverURL: server.url, loginName: "alice", appPassword: "pw"), askForNotifications: false)
        }
        #expect(app.accounts.isEmpty)
        // Nothing but the revocation of the password the Login Flow had granted.
        #expect(server.requests.map(\.line) == ["DELETE /ocs/v2.php/core/apppassword"])
    }

    @Test func aSecondAccountIsRefused() async throws {
        defer { sandbox.remove() }
        let defaults = makeDefaults()
        let app = makeApp(defaults)
        try await app.addAccount(
            LoginService.Credentials(serverURL: server.url, loginName: "alice", appPassword: "pw"), askForNotifications: false)
        defaults.set(["disable_multiaccount": true], forKey: ManagedConfiguration.defaultsKey)
        app.managedConfigurationChanged()
        #expect(!app.canAddAccount)
        await #expect(throws: LoginRefusal.multipleAccounts) {
            try await app.addAccount(
                LoginService.Credentials(serverURL: server.url, loginName: "bob", appPassword: "pw2"), askForNotifications: false)
        }
        // Logging in again to the same account still works.
        try await app.addAccount(
            LoginService.Credentials(serverURL: server.url, loginName: "alice", appPassword: "pw3"), askForNotifications: false)
        #expect(app.accounts.count == 1)
    }

    @Test func appLockIsTurnedOnAndBackupOff() throws {
        defer { sandbox.remove() }
        let defaults = makeDefaults()
        let lockDefaults = makeDefaults()
        let removedLog = Mutex(false)
        var system = SystemTraces.none
        system.removeLog = { removedLog.withLock { $0 = true } }
        let app = makeApp(defaults, system: system)
        app.backup.update { $0.isEnabled = true }

        // Nothing managed: nothing changes.
        app.applyManagedConfiguration(lockDefaults: lockDefaults)
        #expect(!lockDefaults.bool(forKey: AppLockSettings.enabledKey))
        #expect(app.backup.settings.isEnabled)

        defaults.set(
            ["enforce_passcode_lock": true, "disable_backup": true, "disable_log": true], forKey: ManagedConfiguration.defaultsKey)
        app.managedConfigurationChanged()
        app.applyManagedConfiguration(lockDefaults: lockDefaults)
        #expect(lockDefaults.bool(forKey: AppLockSettings.enabledKey))
        #expect(!app.backup.settings.isEnabled)
        #if !os(visionOS)
            #expect(!app.backup.isAvailable)
        #endif
        #expect(app.backup.isDisabledByOrganization)
        #expect(!PersistentLog.isEnabled(defaults))
    }
}

/// What reaches Spotlight (SPEC §7.23): albums, named people and places, never anything hidden or archived.
@Suite struct SpotlightContentTests {
    let library = SpotlightContent.Library(
        albums: [Album(kind: .own, name: "Trip"), Album(kind: .shared, name: "Party (bob)"), Album(kind: .publicLink, name: "tok")],
        people: ["Anna", "42", "Secret friend"],
        places: [(name: "Lisboa", countryCode: "PT")])

    @Test func albumsPeopleAndPlacesAreIndexed() {
        let entries = SpotlightContent.entries(library, hiddenPeople: [], appLockEnabled: false, locale: Locale(identifier: "en_US"))
        #expect(
            entries.map(\.link) == [
                .album(id: "own:Trip"), .album(id: "shared:Party (bob)"), .person(name: "Anna"), .person(name: "Secret friend"),
                .place(name: "Lisboa"),
            ])
        #expect(entries.last?.detail == "Portugal")
    }

    @Test func hiddenPeopleAreLeftOut() {
        let entries = SpotlightContent.entries(library, hiddenPeople: ["Secret friend"], appLockEnabled: false)
        #expect(!entries.contains { $0.title == "Secret friend" })
    }

    @Test func nothingWhileAppLockIsOn() {
        #expect(SpotlightContent.entries(library, hiddenPeople: [], appLockEnabled: true).isEmpty)
    }

    @Test func placesOfArchivedPhotosAreNotIndexed() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "spotlight-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try AccountDatabase(url: directory.appending(path: "db.sqlite"))
        let store = LibraryStore(database: database)
        try store.upsert([
            MediaItem(fileId: 1, path: "/Photos/a.jpg", mimeType: "image/jpeg", place: "Lisboa", placeCountry: "PT"),
            MediaItem(fileId: 2, path: "/.archive/Photos/b.jpg", mimeType: "image/jpeg", place: "Hideaway", isArchived: true),
            MediaItem(fileId: 3, path: "/Photos/c.mov", mimeType: "video/quicktime", place: "Motion only", isLivePhotoVideo: true),
        ])
        let collections = CollectionStore(database: database)
        try collections.upsertAlbum(Album(kind: .own, name: "Trip"))
        try LabelStore(database: database).mergePeople([Person(name: "Anna"), Person(name: "7")])
        try database.writer.write { try $0.execute(sql: "UPDATE person SET itemCount = 3") }

        let read = try SpotlightContent.library(database, collections: collections)
        #expect(read.places.map(\.name) == ["Lisboa"])
        #expect(read.places.first?.countryCode == "PT")
        #expect(read.albums.map(\.id) == ["own:Trip"])
        #expect(read.people == ["Anna"])
    }

    @Test func hiddenPeopleAreReadFromTheAccountsFolder() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "hidden-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(HiddenPeopleFile.names(in: directory).isEmpty)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(["Anna"]).write(to: HiddenPeopleFile.url(in: directory))
        #expect(HiddenPeopleFile.names(in: directory) == ["Anna"])
    }

    /// One domain per account, without dots (a domain's sub-domains are deleted with it).
    @Test func eachAccountHasItsOwnDomain() {
        let alice = makeAccount("alice", server: "https://cloud.example.com")
        let alice2 = makeAccount("alice", server: "https://cloud.example.com.evil.org")
        #expect(SpotlightIndexer.domain(alice.id) != SpotlightIndexer.domain(alice2.id))
        #expect(!SpotlightIndexer.domain(alice.id).contains("."))
        #expect(SpotlightIndexer.domain(alice.id) == SpotlightIndexer.domain(makeAccount("alice", server: "https://cloud.example.com").id))
    }

    /// A Spotlight result opens its album in its account: the identifier is the account's link.
    @Test func itemsCarryTheAccountsLink() throws {
        let alice = makeAccount("alice", server: "https://cloud.example.com")
        let entries = SpotlightContent.entries(library, hiddenPeople: [], appLockEnabled: false)
        let items = SpotlightIndexer.items(entries, account: alice)
        #expect(items.count == entries.count)
        for (item, entry) in zip(items, entries) {
            let url = try #require(URL(string: item.uniqueIdentifier))
            #expect(IncomingLink.resolve(url, accounts: [alice], active: alice.id) == .open(entry.link))
            #expect(item.domainIdentifier == SpotlightIndexer.domain(alice.id))
            #expect(item.attributeSet.title == entry.title)
        }
    }
}

/// Logout and remote wipe take the account out of Spotlight.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct SpotlightCleanupTests {
    let sandbox = Sandbox()
    let server = StubServer()

    @Test func removingAnAccountRemovesItsSpotlightItems() async throws {
        defer { sandbox.remove() }
        let removed = Mutex<[AccountID]>([])
        var system = SystemTraces.none
        system.removeSearchIndex = { id in removed.withLock { $0.append(id) } }
        let suite = "photos-core-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let app = AppModel(
            appVersion: "1.0", layout: sandbox.layout, keychain: sandbox.keychain, defaults: defaults,
            httpConfiguration: server.configuration, system: system)
        try await app.addAccount(
            LoginService.Credentials(serverURL: server.url, loginName: "alice", appPassword: "pw"), askForNotifications: false)
        let account = try #require(app.activeAccount)
        await app.removeAccount(account.id)
        #expect(removed.withLock { $0 } == [account.id])
    }

    @Test func aRemoteWipeRemovesItsSpotlightItems() async throws {
        defer { sandbox.remove() }
        let removed = Mutex<[AccountID]>([])
        var system = SystemTraces.none
        system.removeSearchIndex = { id in removed.withLock { $0.append(id) } }
        let suite = "photos-core-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let app = AppModel(
            appVersion: "1.0", layout: sandbox.layout, keychain: sandbox.keychain, defaults: defaults,
            httpConfiguration: server.configuration, system: system)
        try await app.addAccount(
            LoginService.Credentials(serverURL: server.url, loginName: "alice", appPassword: "pw"), askForNotifications: false)
        let account = try #require(app.activeAccount)
        server.set {
            $0.unauthorized = true
            $0.wipeRequested = true
        }
        await app.handleUnauthorized(account.id)
        #expect(app.accounts.isEmpty)
        #expect(removed.withLock { $0 } == [account.id])
    }
}
