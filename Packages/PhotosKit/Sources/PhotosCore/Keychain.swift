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

    public init(service: String = "com.nextcloud.photos") {
        self.service = service
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
        #if DEBUG && os(macOS)
            if Self.useDevelopmentStore {
                try DevelopmentSecretStore.set(data, for: "\(service).\(key)")
                return
            }
        #endif
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
        #if DEBUG && os(macOS)
            if Self.useDevelopmentStore { return DevelopmentSecretStore.data(for: "\(service).\(key)") }
        #endif
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
        #if DEBUG && os(macOS)
            if Self.useDevelopmentStore {
                DevelopmentSecretStore.delete("\(service).\(key)")
                return
            }
        #endif
        for dataProtection in [true, false] {
            SecItemDelete(baseQuery(key, dataProtection: dataProtection) as CFDictionary)
        }
    }

    // MARK: Conventions

    public static func passwordKey(_ account: String) -> String { "password:\(account)" }
    public static func clientCertificateKey(_ account: String) -> String { "client-certificate:\(account)" }
    public static func clientCertificatePasswordKey(_ account: String) -> String { "client-certificate-password:\(account)" }
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

    /// Development-only secret store (one file per key in the app's sandbox container).
    enum DevelopmentSecretStore {
        static var directory: URL {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "DevelopmentSecrets")
        }

        static func file(_ key: String) -> URL {
            directory.appending(path: Data(key.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_"))
        }

        static func set(_ data: Data, for key: String) throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file(key), options: .atomic)
        }

        static func data(for key: String) -> Data? { try? Data(contentsOf: file(key)) }

        static func delete(_ key: String) { try? FileManager.default.removeItem(at: file(key)) }
    }
#endif
