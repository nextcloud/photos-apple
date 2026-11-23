// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import OSLog
import Observation
import PhotosModel
import PhotosNetworking
import Security

/// App-wide state: accounts, the active session, login.
@MainActor
@Observable
public final class AppModel {
    public private(set) var registry: AccountRegistry
    public private(set) var session: SessionModel?
    /// A destination requested from outside (notification tap, widget, deep link), consumed by the main view.
    public var requestedDestination: String?
    /// The Notifications switch in Settings. Change it with `setPushEnabled(_:)`.
    public private(set) var pushEnabled: Bool
    @ObservationIgnored private var deviceToken: Data?
    @ObservationIgnored private var unauthorizedChecks: Set<AccountID> = []
    /// Sessions that were replaced and are still shutting down.
    @ObservationIgnored private var retiring: [ObjectIdentifier: Task<Void, Never>] = [:]
    public let http: HTTPClient
    public let keychain: Keychain
    public let userAgent: String
    public let appVersion: String
    /// The app's backup; it belongs to one account and runs independently of the active session.
    public let backup: BackupModel
    @ObservationIgnored let layout: StorageLayout
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored private let logger = Logger(subsystem: "com.nextcloud.photos", category: "app")

    public convenience init(appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0") {
        self.init(appVersion: appVersion, layout: AppPaths.layout, keychain: Keychain(), defaults: .standard)
        #if DEBUG
            // Development and UI tests: PHOTOS_DEBUG_LOGIN=nc://login/server:…&user:…&password:… signs in without a browser
            // (and without the notification permission prompt).
            if registry.accounts.isEmpty, let link = ProcessInfo.processInfo.environment["PHOTOS_DEBUG_LOGIN"],
                let credentials = LoginService.parseLoginURL(link)
            {
                Task { try? await self.addAccount(credentials, askForNotifications: false) }
            }
        #endif
    }

    /// Everything the model touches is passed in, so tests can run it in a temporary directory against a stubbed server.
    init(
        appVersion: String, layout: StorageLayout, keychain: Keychain, defaults: UserDefaults,
        httpConfiguration: URLSessionConfiguration = HTTPClient.defaultConfiguration()
    ) {
        self.appVersion = appVersion
        self.userAgent = UserAgent.make(appVersion: appVersion)
        self.keychain = keychain
        self.layout = layout
        self.defaults = defaults
        self.pushEnabled = PushNotifications.isEnabled(defaults)
        let trustStore = TrustStore(directory: layout.certificates)
        self.http = HTTPClient(
            trustStore: trustStore, clientCredentials: { host in AppModel.clientCredential(host: host, keychain: keychain) },
            configuration: httpConfiguration)
        self.registry = AccountRegistry.load(from: layout.accountsFile)
        self.backup = BackupModel(settingsFile: layout.backupSettingsFile)
        backup.attach(self)
        if let account = registry.activeAccount { activate(account) }
    }

    public var accounts: [Account] { registry.accounts }
    public var activeAccount: Account? { session?.account }
    public var needsLogin: Bool { registry.accounts.isEmpty }

    public func loginService() -> LoginService { LoginService(http: http, userAgent: userAgent) }

    private func saveRegistry() {
        do {
            try registry.save(to: layout.accountsFile)
        } catch {
            logger.error("could not save accounts: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Completes a login: verifies the credentials, stores them and activates the account.
    ///
    /// - Parameter askForNotifications: ask for the notification permission now that there is an account to notify about
    ///   (the system only prompts the first time; nothing is asked at first launch).
    public func addAccount(_ credentials: LoginService.Credentials, askForNotifications: Bool = true) async throws {
        let status = try await loginService().status(serverURL: credentials.serverURL)
        let provisional = ServerConnection(
            serverURL: credentials.serverURL, userId: credentials.loginName, loginName: credentials.loginName,
            appPassword: credentials.appPassword, userAgent: userAgent)
        let profile = try await AccountAPI(ocs: OCSClient(http: http, connection: provisional)).profile()
        let account = Account(
            serverURL: credentials.serverURL, userId: profile.id, loginName: credentials.loginName,
            displayName: profile.displayname ?? profile.id, serverVersion: status.serverVersion)
        try keychain.set(credentials.appPassword, for: Keychain.passwordKey(account.id.rawValue))
        registry.upsert(account)
        registry.activeAccountID = account.id
        saveRegistry()
        activate(account)
        if pushEnabled {
            if askForNotifications {
                Task { await PushNotifications.requestAuthorization() }
            } else if let deviceToken {
                registerForPush(account, deviceToken: deviceToken)
            }
        }
    }

    public func switchTo(_ id: AccountID) {
        guard let account = registry.accounts.first(where: { $0.id == id }), account.id != session?.account.id else { return }
        registry.activeAccountID = id
        saveRegistry()
        activate(account)
    }

    /// Signs out and removes all local data of an account; revokes its app password on the server.
    public func removeAccount(_ id: AccountID) async {
        guard let account = registry.accounts.first(where: { $0.id == id }) else { return }
        if let password = keychain.string(for: Keychain.passwordKey(id.rawValue)) {
            await Self.signOutOnServer(account: account, appPassword: password, http: http, userAgent: userAgent, keychain: keychain)
        }
        await purge(account)
    }

    /// The server side of a logout, in the only order that works: the push registration is removed while the app password
    /// is still valid, then the app password is revoked.
    static func signOutOnServer(account: Account, appPassword: String, http: HTTPClient, userAgent: String, keychain: Keychain) async {
        await PushNotifications.unregister(account: account, appPassword: appPassword, http: http, userAgent: userAgent, keychain: keychain)
        let connection = ServerConnection(
            serverURL: account.serverURL, userId: account.userId, loginName: account.loginName, appPassword: appPassword,
            userAgent: userAgent)
        try? await AccountAPI(ocs: OCSClient(http: http, connection: connection)).revokeAppPassword()
    }

    /// Removes an account from this device: stops everything that runs for it, waits, then deletes every local trace
    /// (`AccountPurge`). Shared by account removal and remote wipe.
    private func purge(_ account: Account) async {
        let id = account.id
        // Out of the list first: nothing new starts for this account while its work is being stopped.
        registry.remove(id)
        saveRegistry()
        let removed = session?.account.id == id ? session : nil
        if removed != nil { session = nil }
        await backup.accountWillBeRemoved(id)
        for task in Array(retiring.values) { await task.value }
        await removed?.shutdown(closeDatabase: true)
        AccountPurge(layout: layout, keychain: keychain, trustStore: http.trustStore).purge(account, remaining: registry.accounts)
        if session == nil, let next = registry.activeAccount { activate(next) }
    }

    /// Marks an account as signed out after a confirmed 401 (local data is kept until the account is removed, SPEC §5.1.6).
    func markSignedOut(_ id: AccountID) {
        guard var account = registry.accounts.first(where: { $0.id == id }) else { return }
        account.isSignedOut = true
        registry.upsert(account)
        saveRegistry()
        if session?.account.id == id { session?.account = account }
        backup.accountSignedOut(id)
    }

    /// Server-requested wipe: delete everything and confirm.
    func wipe(_ id: AccountID, api: AccountAPI) async {
        guard let account = registry.accounts.first(where: { $0.id == id }) else { return }
        // The server no longer accepts the app password, but the push proxy can still be told to forget this device.
        await PushNotifications.unregister(
            account: account, appPassword: api.ocs.connection.appPassword, http: http, userAgent: userAgent, keychain: keychain)
        await purge(account)
        try? await api.confirmRemoteWipe()
    }

    // MARK: Unauthorized (SPEC §5.1.6)

    /// A request of this account was answered with 401: check whether the app password really stopped working, then wipe
    /// (when the server asks for it) or mark the account as signed out.
    func handleUnauthorized(_ id: AccountID) async {
        guard !unauthorizedChecks.contains(id), let account = registry.accounts.first(where: { $0.id == id }), !account.isSignedOut,
            let password = keychain.string(for: Keychain.passwordKey(id.rawValue))
        else { return }
        unauthorizedChecks.insert(id)
        defer { unauthorizedChecks.remove(id) }
        let connection = ServerConnection(
            serverURL: account.serverURL, userId: account.userId, loginName: account.loginName, appPassword: password,
            userAgent: userAgent)
        let accountAPI = AccountAPI(ocs: OCSClient(http: http, connection: connection))
        do {
            _ = try await accountAPI.profile()
            return  // credentials still valid
        } catch NetworkError.unauthorized {
            if (try? await accountAPI.remoteWipeRequested()) == true {
                await wipe(id, api: accountAPI)
            } else {
                markSignedOut(id)
            }
        } catch {
            return
        }
    }

    // MARK: Sessions

    private func activate(_ account: Account) {
        retire(session)
        guard let password = keychain.string(for: Keychain.passwordKey(account.id.rawValue)) else {
            logger.error("no password for account")
            var signedOut = account
            signedOut.isSignedOut = true
            session = SessionModel(app: self, account: signedOut, password: nil)
            return
        }
        session = SessionModel(app: self, account: account, password: password)
        session?.start()
    }

    /// Stops a session that is being replaced: its tasks are cancelled at once, and it is kept alive until its sync,
    /// outbox worker, uploads and offline downloads have really stopped.
    private func retire(_ old: SessionModel?) {
        guard let old else { return }
        old.stop()
        let key = ObjectIdentifier(old)
        retiring[key] = Task { [weak self] in
            await old.shutdown()
            self?.retiring[key] = nil
        }
    }

    /// Waits until replaced sessions have stopped (tests).
    func waitForRetiredSessions() async {
        for task in Array(retiring.values) { await task.value }
    }

    /// Services for an account that is not the active one (the backup account while another account is shown).
    func makeServices(for account: Account) -> AccountServices? {
        guard !account.isSignedOut, let password = keychain.string(for: Keychain.passwordKey(account.id.rawValue)) else { return nil }
        let id = account.id
        let features =
            AccountServices.loadFeatures(id, layout: layout)
            ?? ServerFeatures(serverVersion: account.serverVersion ?? ServerVersion(major: 0))
        do {
            return try AccountServices(
                account: account, appPassword: password, http: http, features: features, userAgent: userAgent, layout: layout,
                onUnauthorized: { [weak self] in Task { @MainActor in await self?.handleUnauthorized(id) } })
        } catch {
            logger.error("could not open account database: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: Push (SPEC §7.21)

    /// Registers all accounts for push once APNs delivered a device token.
    public func didRegisterForPush(deviceToken: Data) {
        self.deviceToken = deviceToken
        guard pushEnabled else { return }
        for account in registry.accounts where !account.isSignedOut { registerForPush(account, deviceToken: deviceToken) }
    }

    private func registerForPush(_ account: Account, deviceToken: Data) {
        guard let password = keychain.string(for: Keychain.passwordKey(account.id.rawValue)) else { return }
        Task {
            do {
                try await PushNotifications.register(
                    deviceToken: deviceToken, account: account, appPassword: password, http: http, userAgent: userAgent,
                    keychain: keychain)
            } catch {
                logger.error("push registration failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The Notifications switch. Off: every account is unregistered on its server and the push proxy, and the push keys are
    /// deleted. On: asks for permission when needed and registers every account again.
    public func setPushEnabled(_ enabled: Bool) async {
        guard enabled != pushEnabled else { return }
        pushEnabled = enabled
        defaults.set(enabled, forKey: PushNotifications.enabledKey)
        if enabled {
            // With permission the system delivers the device token (again), which registers all accounts.
            let asked = await PushNotifications.requestAuthorization()
            if !asked, let deviceToken { didRegisterForPush(deviceToken: deviceToken) }
        } else {
            for account in registry.accounts {
                guard let password = keychain.string(for: Keychain.passwordKey(account.id.rawValue)) else { continue }
                await PushNotifications.unregister(
                    account: account, appPassword: password, http: http, userAgent: userAgent, keychain: keychain)
            }
        }
    }

    /// Maps a delivered notification to a destination (On this day for the Photos "onthisday" notification).
    public func handleNotification(userInfo: [AnyHashable: Any]) {
        if let destination = userInfo[PushNotifications.destinationKey] as? String { requestedDestination = destination }
    }

    /// A silent push (`content-available`): the server withdrew notifications. Removes them from Notification Centre.
    /// Returns false when the push was not one of ours.
    @discardableResult
    public func handleBackgroundPush(subject: String?) async -> Bool {
        guard let subject else { return false }
        return await PushNotifications.handleBackgroundPush(subject: subject, accounts: registry.accounts, keychain: keychain)
    }

    // MARK: Client certificates

    nonisolated static func clientCredential(host: String, keychain: Keychain) -> URLCredential? {
        let host = host.lowercased()
        guard let data = keychain.data(for: Keychain.clientCertificateKey(host)) else { return nil }
        let password = keychain.string(for: Keychain.clientCertificatePasswordKey(host)) ?? ""
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase: password] as CFDictionary, &items)
        guard status == errSecSuccess, let first = (items as? [[CFString: Any]])?.first,
            let identity = first[kSecImportItemIdentity].map({ $0 as! SecIdentity })
        else { return nil }
        return URLCredential(identity: identity, certificates: nil, persistence: .forSession)
    }

    /// Imports a PKCS#12 client certificate for a host (mTLS). It is removed with the last account on that host.
    public func importClientCertificate(_ data: Data, password: String, host: String) throws {
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase: password] as CFDictionary, &items)
        guard status == errSecSuccess else { throw Keychain.KeychainError.status(status) }
        try keychain.set(data, for: Keychain.clientCertificateKey(host.lowercased()))
        try keychain.set(password, for: Keychain.clientCertificatePasswordKey(host.lowercased()))
    }
}
