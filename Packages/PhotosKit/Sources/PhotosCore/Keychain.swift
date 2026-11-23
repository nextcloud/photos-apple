// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Security

/// Generic-password keychain items of the app (service `com.nextcloud.photos`).
///
/// Uses the data-protection keychain with the app's default access group (shared with its extensions).
/// Unsigned development builds on macOS lack the entitlement; they fall back to the login keychain.
public struct Keychain: Sendable {
    public let service: String
    /// Items are kept as files in this directory instead of the keychain: unsigned Debug builds on the Mac, and unit
    /// tests (also when they are built in Release). The app's public initializer sets it only in Debug builds.
    let fileStore: DevelopmentSecretStore?

    public init(service: String = "com.nextcloud.photos") {
        self.service = service
        #if DEBUG && os(macOS)
            fileStore = Self.useDevelopmentStore ? DevelopmentSecretStore(directory: DevelopmentSecretStore.defaultDirectory) : nil
        #else
            fileStore = nil
        #endif
    }

    /// A store that never touches the keychain: one file per item in `directory`. For tests only (internal).
    init(service: String, fileStore directory: URL) {
        self.service = service
        self.fileStore = DevelopmentSecretStore(directory: directory)
    }

    public enum KeychainError: Error {
        case status(OSStatus)
    }

    func baseQuery(_ key: String, dataProtection: Bool) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
        ]
        if dataProtection { query[kSecUseDataProtectionKeychain] = true }
        return query
    }

    public func set(_ value: String, for key: String) throws {
        try set(Data(value.utf8), for: key)
    }

    public func set(_ data: Data, for key: String) throws {
        if let fileStore {
            try fileStore.set(data, for: "\(service).\(key)")
            return
        }
        for dataProtection in [true, false] {
            let query = baseQuery(key, dataProtection: dataProtection)
            SecItemDelete(query as CFDictionary)
            var add = query
            add[kSecValueData] = data
            add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            let status = SecItemAdd(add as CFDictionary, nil)
            if status == errSecSuccess { return }
            if status != errSecMissingEntitlement { throw KeychainError.status(status) }
        }
    }

    public func data(for key: String) -> Data? {
        if let fileStore { return fileStore.data(for: "\(service).\(key)") }
        for dataProtection in [true, false] {
            var query = baseQuery(key, dataProtection: dataProtection)
            query[kSecReturnData] = true
            query[kSecMatchLimit] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecSuccess { return result as? Data }
        }
        return nil
    }

    public func string(for key: String) -> String? {
        data(for: key).flatMap { String(data: $0, encoding: .utf8) }
    }

    public func delete(_ key: String) {
        if let fileStore {
            fileStore.delete("\(service).\(key)")
            return
        }
        for dataProtection in [true, false] {
            SecItemDelete(baseQuery(key, dataProtection: dataProtection) as CFDictionary)
        }
    }

    // MARK: Conventions

    public static func passwordKey(_ account: String) -> String { "password:\(account)" }
    public static func clientCertificateKey(_ host: String) -> String { "client-certificate:\(host)" }
    public static func clientCertificatePasswordKey(_ host: String) -> String { "client-certificate-password:\(host)" }
    public static func pushPrivateKeyKey(_ account: String) -> String { "push-private-key:\(account)" }
    public static func pushRegistrationKey(_ account: String) -> String { "push-registration:\(account)" }

    /// Every item that belongs to one account alone. Client certificates are per host and handled by `AccountPurge`.
    public static func accountKeys(_ account: String) -> [String] {
        [passwordKey(account), pushPrivateKeyKey(account), pushRegistrationKey(account)]
    }
}

#if DEBUG && os(macOS)
    extension Keychain {
        /// Unsigned Debug builds on macOS can't use the data-protection keychain (no entitlement), and every rebuild changes the
        /// ad-hoc signature, so the login keychain would prompt on each launch. They keep secrets in the sandbox container instead.
        static let useDevelopmentStore: Bool = {
            let probe: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword, kSecAttrService: "com.nextcloud.photos.probe", kSecAttrAccount: "probe",
                kSecUseDataProtectionKeychain: true, kSecValueData: Data(),
            ]
            let status = SecItemAdd(probe as CFDictionary, nil)
            if status == errSecSuccess || status == errSecDuplicateItem {
                SecItemDelete(probe as CFDictionary)
                return false
            }
            return status == errSecMissingEntitlement
        }()
    }
#endif

/// Secret store of unsigned Debug builds and unit tests (one file per key in a directory).
struct DevelopmentSecretStore: Sendable {
    let directory: URL

    /// In the app's sandbox container.
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "DevelopmentSecrets")
    }

    func file(_ key: String) -> URL {
        directory.appending(path: Data(key.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_"))
    }

    func set(_ data: Data, for key: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: file(key), options: .atomic)
    }

    func data(for key: String) -> Data? { try? Data(contentsOf: file(key)) }

    func delete(_ key: String) { try? FileManager.default.removeItem(at: file(key)) }
}
