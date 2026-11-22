// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import OSLog
import PhotosModel
import PhotosNetworking
import Security

/// Push notifications through the Nextcloud push proxy (SPEC §7.21; docs/reference/nextcloud-ios-and-nextcloudkit.md §5).
public enum PushNotifications {
    public static let proxyServer = "https://push-notifications.nextcloud.com"
    static let logger = Logger(subsystem: "com.nextcloud.photos", category: "push")

    static func privateKeyTag(_ account: AccountID) -> String { "push-private-key:\(account.rawValue)" }
    static func registrationKey(_ account: AccountID) -> String { "push-registration:\(account.rawValue)" }

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

    /// Removes the registration on the server and the proxy (logout).
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

    /// A decrypted push payload.
    public struct Payload: Decodable, Sendable {
        public var app: String
        public var subject: String
        public var nid: Int?
        public var type: String?
        public var delete: Bool?
        public var deleteAll: Bool?

        enum CodingKeys: String, CodingKey {
            case app, subject, nid, type, delete
            case deleteAll = "delete-all"
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
}
