// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import OSLog
import PhotosModel
import PhotosNetworking
import Security
import UserNotifications

/// Push notifications through the Nextcloud push proxy (SPEC §7.21; docs/reference/nextcloud-ios-and-nextcloudkit.md §5).
public enum PushNotifications {
    public static let proxyServer = "https://push-notifications.nextcloud.com"
    static let logger = Logger(subsystem: "com.nextcloud.photos", category: "push")

    /// `UserDefaults` key of the Notifications switch in Settings (default on).
    public static let enabledKey = "pushEnabled"

    static func privateKeyTag(_ account: AccountID) -> String { Keychain.pushPrivateKeyKey(account.rawValue) }
    static func registrationKey(_ account: AccountID) -> String { Keychain.pushRegistrationKey(account.rawValue) }

    public static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    /// True when the account has a registration with the server and the proxy.
    public static func isRegistered(_ account: AccountID, keychain: Keychain) -> Bool {
        keychain.data(for: registrationKey(account)) != nil
    }

    struct Registration: Codable {
        var deviceIdentifier: String
        var signature: String
        var publicKey: String
        var tokenHash: String
    }

    /// Registers the device token for an account with the server and the proxy. Safe to call on every launch.
    public static func register(
        deviceToken: Data, account: Account, appPassword: String, http: HTTPClient, userAgent: String, keychain: Keychain
    )
        async throws
    {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        let tokenHash = SHA512.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        if let data = keychain.data(for: registrationKey(account.id)),
            let existing = try? JSONDecoder().decode(Registration.self, from: data),
            existing.tokenHash == tokenHash
        {
            return
        }
        let privateKey = try loadOrCreateKey(account: account.id, keychain: keychain)
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else { throw NetworkError.invalidResponse("no public key") }
        let pem = try publicKeyPEM(publicKey)
        let connection = ServerConnection(
            serverURL: account.serverURL, userId: account.userId, loginName: account.loginName, appPassword: appPassword,
            userAgent: userAgent)
        let ocs = OCSClient(http: http, connection: connection)
        struct ServerResponse: Decodable {
            var publicKey: String
            var deviceIdentifier: String
            var signature: String
        }
        let server: ServerResponse = try await ocs.request(
            "POST", "ocs/v2.php/apps/notifications/api/v2/push",
            form: ["pushTokenHash": tokenHash, "devicePublicKey": pem, "proxyServer": proxyServer])
        let body = Data(
            OCSClient.formEncode([
                "pushToken": token, "deviceIdentifier": server.deviceIdentifier, "deviceIdentifierSignature": server.signature,
                "userPublicKey": server.publicKey,
            ]).utf8)
        let response = try await http.send(
            HTTPRequest(
                method: "POST", url: URL(string: "\(proxyServer)/devices?format=json")!,
                headers: ["User-Agent": userAgent, "Content-Type": "application/x-www-form-urlencoded"], body: body))
        guard response.isSuccess else { throw NetworkError.http(status: response.status, message: response.text) }
        let registration = Registration(
            deviceIdentifier: server.deviceIdentifier, signature: server.signature, publicKey: server.publicKey, tokenHash: tokenHash)
        try keychain.set(try JSONEncoder().encode(registration), for: registrationKey(account.id))
    }

    /// Removes the registration on the server and the proxy, then the key and the registration on this device.
    ///
    /// Needs a still valid app password for the server part, so on logout it has to run before the password is revoked.
    /// The proxy part works without one (remote wipe, where the server already rejects the password).
    public static func unregister(account: Account, appPassword: String, http: HTTPClient, userAgent: String, keychain: Keychain) async {
        defer {
            keychain.delete(registrationKey(account.id))
            keychain.delete(privateKeyTag(account.id))
        }
        guard let data = keychain.data(for: registrationKey(account.id)),
            let registration = try? JSONDecoder().decode(Registration.self, from: data)
        else { return }
        let connection = ServerConnection(
            serverURL: account.serverURL, userId: account.userId, loginName: account.loginName, appPassword: appPassword,
            userAgent: userAgent)
        _ = try? await OCSClient(http: http, connection: connection).raw("DELETE", "ocs/v2.php/apps/notifications/api/v2/push")
        let body = Data(
            OCSClient.formEncode([
                "deviceIdentifier": registration.deviceIdentifier, "deviceIdentifierSignature": registration.signature,
                "userPublicKey": registration.publicKey,
            ]).utf8)
        _ = try? await http.send(
            HTTPRequest(
                method: "DELETE", url: URL(string: "\(proxyServer)/devices")!,
                headers: ["User-Agent": userAgent, "Content-Type": "application/x-www-form-urlencoded"], body: body))
    }

    // MARK: Keys

    /// RSA-2048 key per account, stored as PKCS#1 in the app keychain (shared with the notification extension).
    static func loadOrCreateKey(account: AccountID, keychain: Keychain) throws -> SecKey {
        if let data = keychain.data(for: privateKeyTag(account)), let key = rsaKey(fromPrivate: data) { return key }
        var error: Unmanaged<CFError>?
        guard
            let key = SecKeyCreateRandomKey(
                [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, &error),
            let data = SecKeyCopyExternalRepresentation(key, &error) as Data?
        else { throw error!.takeRetainedValue() as any Error }
        try keychain.set(data, for: privateKeyTag(account))
        return key
    }

    static func rsaKey(fromPrivate data: Data) -> SecKey? {
        SecKeyCreateWithData(
            data as CFData,
            [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate, kSecAttrKeySizeInBits: 2048] as CFDictionary,
            nil)
    }

    /// PEM "PUBLIC KEY" (SubjectPublicKeyInfo) from an RSA key; Security exports PKCS#1, so the SPKI header is prepended.
    static func publicKeyPEM(_ key: SecKey) throws -> String {
        var error: Unmanaged<CFError>?
        guard let pkcs1 = SecKeyCopyExternalRepresentation(key, &error) as Data? else { throw error!.takeRetainedValue() as any Error }
        let algorithm: [UInt8] = [0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00]
        let bitString = [0x00] + [UInt8](pkcs1)
        let spkiBody = algorithm + [0x03] + derLength(bitString.count) + bitString
        let spki = [0x30] + derLength(spkiBody.count) + spkiBody
        let base64 = Data(spki).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN PUBLIC KEY-----\n\(base64)\n-----END PUBLIC KEY-----\n"
    }

    static func derLength(_ length: Int) -> [UInt8] {
        if length < 128 { return [UInt8(length)] }
        var bytes: [UInt8] = []
        var value = length
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    // MARK: Payloads

    /// A decrypted push payload. Notifications carry `app` and `subject`; delete pushes only carry ids.
    public struct Payload: Decodable, Sendable, Equatable {
        public var app: String?
        public var subject: String?
        public var nid: Int?
        public var nids: [Int]?
        public var type: String?
        public var delete: Bool?
        public var deleteMultiple: Bool?
        public var deleteAll: Bool?

        enum CodingKeys: String, CodingKey {
            case app, subject, nid, nids, type, delete
            case deleteMultiple = "delete-multiple"
            case deleteAll = "delete-all"
        }

        public init(
            app: String? = nil, subject: String? = nil, nid: Int? = nil, nids: [Int]? = nil, type: String? = nil, delete: Bool? = nil,
            deleteMultiple: Bool? = nil, deleteAll: Bool? = nil
        ) {
            self.app = app
            self.subject = subject
            self.nid = nid
            self.nids = nids
            self.type = type
            self.delete = delete
            self.deleteMultiple = deleteMultiple
            self.deleteAll = deleteAll
        }
    }

    /// Decrypts `subject` (base64 RSA) with the account's key: OAEP first, then PKCS#1 v1.5.
    public static func decrypt(_ base64: String, account: AccountID, keychain: Keychain = Keychain()) -> Payload? {
        guard let encrypted = Data(base64Encoded: base64), let keyData = keychain.data(for: privateKeyTag(account)),
            let key = rsaKey(fromPrivate: keyData)
        else { return nil }
        for algorithm in [SecKeyAlgorithm.rsaEncryptionOAEPSHA1, .rsaEncryptionPKCS1] {
            if let plain = SecKeyCreateDecryptedData(key, algorithm, encrypted as CFData, nil) as Data?,
                let payload = try? JSONDecoder().decode(Payload.self, from: plain)
            {
                return payload
            }
        }
        return nil
    }

    // MARK: What to do with a payload

    /// What a notification of the Photos app looks like.
    public struct Presentation: Sendable, Equatable {
        public var title: String
        public var body: String
        public var threadIdentifier: String
        /// View to open on tap (`photosDestination` in the notification's `userInfo`).
        public var destination: String?
        public var notificationId: Int?
    }

    public enum Action: Sendable, Equatable {
        case show(Presentation)
        /// Not a notification of the Photos app (the server sends this device those of every app, SPEC §7.21): show nothing.
        case suppress
        /// The server withdrew these notifications: remove them from Notification Centre, show nothing.
        case removeDelivered([Int])
        case removeAllDelivered
    }

    /// The app whose notifications belong here.
    public static let appId = "photos"
    static let notificationIdKey = "photosNotificationId"
    static let accountKey = "photosAccount"
    public static let destinationKey = "photosDestination"

    public static func action(for payload: Payload) -> Action {
        if payload.deleteAll == true { return .removeAllDelivered }
        if payload.delete == true || payload.deleteMultiple == true {
            return .removeDelivered((payload.nids ?? []) + (payload.nid.map { [$0] } ?? []))
        }
        guard payload.app == appId, let subject = payload.subject, !subject.isEmpty else { return .suppress }
        return .show(
            Presentation(
                title: "Nextcloud Photos", body: subject, threadIdentifier: appId, destination: payload.type == nil ? "onThisDay" : nil,
                notificationId: payload.nid))
    }

    /// Fills a notification from a presentation and remembers which server notification it is, so a later delete push finds it.
    public static func apply(_ presentation: Presentation, account: AccountID, to content: UNMutableNotificationContent) {
        // Apple TV shows no notification banners and keeps none (SPEC §15.3).
        #if !os(tvOS)
            content.title = presentation.title
            content.body = presentation.body
            content.threadIdentifier = presentation.threadIdentifier
            content.userInfo[accountKey] = account.rawValue
            if let id = presentation.notificationId { content.userInfo[notificationIdKey] = id }
            if let destination = presentation.destination { content.userInfo[destinationKey] = destination }
        #endif
    }

    /// A delivered notification as far as removal is concerned.
    struct Delivered {
        var identifier: String
        var account: String?
        var notificationId: Int?
    }

    /// Request identifiers of the delivered notifications that a delete push of `account` withdraws.
    static func identifiersToRemove(_ action: Action, account: AccountID, delivered: [Delivered]) -> [String] {
        let own = delivered.filter { $0.account == account.rawValue }
        switch action {
        case .removeAllDelivered: return own.map(\.identifier)
        case .removeDelivered(let ids):
            return own.filter { item in item.notificationId.map(ids.contains) ?? false }.map(\.identifier)
        case .show, .suppress: return []
        }
    }

    /// Removes the notifications a delete push withdraws from Notification Centre.
    public static func removeDelivered(_ action: Action, account: AccountID) async {
        // Apple TV shows no notification banners and keeps none (SPEC §15.3).
        #if !os(tvOS)
            let center = UNUserNotificationCenter.current()
            let delivered = await center.deliveredNotifications().map { notification in
                let userInfo = notification.request.content.userInfo
                return Delivered(
                    identifier: notification.request.identifier, account: userInfo[accountKey] as? String,
                    notificationId: userInfo[notificationIdKey] as? Int)
            }
            let identifiers = identifiersToRemove(action, account: account, delivered: delivered)
            if !identifiers.isEmpty { center.removeDeliveredNotifications(withIdentifiers: identifiers) }
        #endif
    }

    /// A silent (background) push: delete pushes are handled, everything else is ignored. Returns true when something was removed
    /// or nothing had to be done; false when the payload could not be read.
    @discardableResult
    public static func handleBackgroundPush(subject: String, accounts: [Account], keychain: Keychain = Keychain()) async -> Bool {
        for account in accounts {
            guard let payload = decrypt(subject, account: account.id, keychain: keychain) else { continue }
            let action = action(for: payload)
            switch action {
            case .removeDelivered, .removeAllDelivered: await removeDelivered(action, account: account.id)
            case .show, .suppress: break
            }
            return true
        }
        return false
    }

    // MARK: Permission and registration with the system

    /// Installed by the app at launch: calls the platform's `registerForRemoteNotifications()`.
    /// (PhotosCore is also linked into extensions, where `UIApplication.shared` does not exist.)
    @MainActor static var registerWithSystem: (@MainActor () -> Void)?

    /// Call once at launch. Never shows the permission prompt: when notifications were allowed earlier (and are on in
    /// Settings) the device registers again, otherwise nothing happens until `requestAuthorization()` after a login or
    /// when the user turns the Notifications switch on.
    @MainActor
    public static func install(delegate: (any UNUserNotificationCenterDelegate)?, register: @escaping @MainActor () -> Void) {
        UNUserNotificationCenter.current().delegate = delegate
        registerWithSystem = register
        Task { @MainActor in
            guard isEnabled() else { return }
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            if shouldRegisterAtLaunch(status) { registerWithSystem?() }
        }
    }

    static func shouldRegisterAtLaunch(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional: true
        default: false
        }
    }

    /// Asks for permission (the system only prompts the first time) and registers with APNs when granted.
    /// Does nothing when the app did not call `install` (extensions, tests).
    @MainActor
    @discardableResult
    public static func requestAuthorization() async -> Bool {
        guard let registerWithSystem else { return false }
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])) ?? false
        if granted { registerWithSystem() }
        return granted
    }
}
