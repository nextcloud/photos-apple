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
    @ObservationIgnored private var deviceToken: Data?
    public let http: HTTPClient
    public let keychain: Keychain
    public let userAgent: String
    public let appVersion: String
    @ObservationIgnored private let logger = Logger(subsystem: "com.nextcloud.photos", category: "app")

    public init(appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0") {
        self.appVersion = appVersion
        self.userAgent = UserAgent.make(appVersion: appVersion)
        self.keychain = Keychain()
        let trustStore = TrustStore(directory: AppPaths.certificates)
        let keychain = self.keychain
        self.http = HTTPClient(
            trustStore: trustStore, clientCredentials: { host in AppModel.clientCredential(host: host, keychain: keychain) })
        self.registry = AccountRegistry.load()
        if let account = registry.activeAccount { activate(account) }
        #if DEBUG
            // Development and UI tests: PHOTOS_DEBUG_LOGIN=nc://login/server:…&user:…&password:… signs in without a browser.
            if registry.accounts.isEmpty, let link = ProcessInfo.processInfo.environment["PHOTOS_DEBUG_LOGIN"],
                let credentials = LoginService.parseLoginURL(link)
            {
                Task { try? await self.addAccount(credentials) }
            }
        #endif
    }

    public var accounts: [Account] { registry.accounts }
    public var activeAccount: Account? { session?.account }
    public var needsLogin: Bool { registry.accounts.isEmpty }

    public func loginService() -> LoginService { LoginService(http: http, userAgent: userAgent) }

    /// Completes a login: verifies the credentials, stores them and activates the account.
    public func addAccount(_ credentials: LoginService.Credentials) async throws {
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
        do {
            try registry.save()
        } catch {
            logger.error("could not save accounts: \(error.localizedDescription, privacy: .public)")
        }
        activate(account)
    }

    public func switchTo(_ id: AccountID) {
        guard let account = registry.accounts.first(where: { $0.id == id }), account.id != session?.account.id else { return }
        registry.activeAccountID = id
        try? registry.save()
        activate(account)
    }

    /// Signs out and removes all local data of an account; revokes its app password on the server.
    public func removeAccount(_ id: AccountID) async {
        guard let account = registry.accounts.first(where: { $0.id == id }) else { return }
        if let password = keychain.string(for: Keychain.passwordKey(id.rawValue)) {
            let connection = ServerConnection(
                serverURL: account.serverURL, userId: account.userId, loginName: account.loginName, appPassword: password,
                userAgent: userAgent)
            try? await AccountAPI(ocs: OCSClient(http: http, connection: connection)).revokeAppPassword()
        }
        if let password = keychain.string(for: Keychain.passwordKey(id.rawValue)) {
            await PushNotifications.unregister(
                account: account, appPassword: password, http: http, userAgent: userAgent, keychain: keychain)
        }
        if session?.account.id == id {
            session?.stop()
            session = nil
        }
        keychain.delete(Keychain.passwordKey(id.rawValue))
        AccountServices.deleteLocalData(id)
        registry.remove(id)
        try? registry.save()
        if let next = registry.activeAccount { activate(next) }
    }

    /// Marks an account as signed out after a confirmed 401 (local data is kept).
    func markSignedOut(_ id: AccountID) {
        guard var account = registry.accounts.first(where: { $0.id == id }) else { return }
        account.isSignedOut = true
        registry.upsert(account)
        try? registry.save()
        if session?.account.id == id { session?.account = account }
    }

    /// Server-requested wipe: delete everything and confirm.
    func wipe(_ id: AccountID, api: AccountAPI) async {
        session?.stop()
        session = nil
        keychain.delete(Keychain.passwordKey(id.rawValue))
        AccountServices.deleteLocalData(id)
        try? await api.confirmRemoteWipe()
        registry.remove(id)
        try? registry.save()
        if let next = registry.activeAccount { activate(next) }
    }

    private func activate(_ account: Account) {
        session?.stop()
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

    /// Registers all accounts for push once APNs delivered a device token (SPEC §7.21).
    public func didRegisterForPush(deviceToken: Data) {
        self.deviceToken = deviceToken
        guard UserDefaults.standard.object(forKey: "pushEnabled") as? Bool ?? true else { return }
        for account in registry.accounts where !account.isSignedOut {
            guard let password = keychain.string(for: Keychain.passwordKey(account.id.rawValue)) else { continue }
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
    }

    /// Maps a delivered notification to a destination (On this day for the Photos "onthisday" notification).
    public func handleNotification(userInfo: [AnyHashable: Any]) {
        if let destination = userInfo["photosDestination"] as? String { requestedDestination = destination }
    }

    nonisolated static func clientCredential(host: String, keychain: Keychain) -> URLCredential? {
        guard let data = keychain.data(for: Keychain.clientCertificateKey(host)) else { return nil }
        let password = keychain.string(for: Keychain.clientCertificatePasswordKey(host)) ?? ""
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase: password] as CFDictionary, &items)
        guard status == errSecSuccess, let first = (items as? [[CFString: Any]])?.first,
            let identity = first[kSecImportItemIdentity].map({ $0 as! SecIdentity })
        else { return nil }
        return URLCredential(identity: identity, certificates: nil, persistence: .forSession)
    }

    /// Imports a PKCS#12 client certificate for a host (mTLS).
    public func importClientCertificate(_ data: Data, password: String, host: String) throws {
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase: password] as CFDictionary, &items)
        guard status == errSecSuccess else { throw Keychain.KeychainError.status(status) }
        try keychain.set(data, for: Keychain.clientCertificateKey(host.lowercased()))
        try keychain.set(password, for: Keychain.clientCertificatePasswordKey(host.lowercased()))
    }
}
