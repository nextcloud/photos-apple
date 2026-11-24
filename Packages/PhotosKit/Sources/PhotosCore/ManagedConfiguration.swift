// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel
import PhotosNetworking

/// Settings an organisation pushes with its device management (MDM, AppConfig), SPEC §5.1.9.
///
/// The system writes them into the app's own defaults under `com.apple.configuration.managed`; they change while the app runs
/// (`AppModel.observeManagedConfiguration()`). The keys are the ones the Nextcloud Files app reads, so one configuration
/// serves both apps:
///
/// | Key | Effect |
/// |---|---|
/// | `serverUrl` | The login uses this server; logins to other servers are refused (also QR codes and links). |
/// | `username` | Proposed as the user name on the server's login page. |
/// | `disable_multiaccount` | No second account can be added (logging in again to an existing one still works). |
/// | `enforce_passcode_lock` | App lock is on and cannot be turned off. |
/// | `disable_log` | No log is kept on the device and no diagnostics report can be exported. |
/// | `disable_backup` | Automatic backup is off and cannot be turned on. |
///
/// Accounts that exist when a restriction arrives are kept (nothing is deleted behind the user's back); they can be removed
/// in Settings.
public struct ManagedConfiguration: Equatable, Sendable {
    /// Where the system puts the managed app configuration.
    public static let defaultsKey = "com.apple.configuration.managed"

    public enum Key {
        public static let serverURL = "serverUrl"
        public static let userName = "username"
        public static let disableMultipleAccounts = "disable_multiaccount"
        public static let enforceAppLock = "enforce_passcode_lock"
        public static let disableLog = "disable_log"
        public static let disableBackup = "disable_backup"
    }

    /// The server logins are limited to (normalised like a typed address).
    public var serverURL: URL?
    /// The user name the login page proposes.
    public var userName: String?
    public var disablesMultipleAccounts = false
    public var enforcesAppLock = false
    public var disablesLog = false
    public var disablesBackup = false

    public init() {}

    /// Reads the managed dictionary. Values the system delivers as strings or numbers (`"true"`, `1`) count like booleans;
    /// anything unreadable is ignored.
    public init(_ dictionary: [String: Any]?) {
        guard let dictionary else { return }
        if let text = Self.string(dictionary[Key.serverURL]) { serverURL = LoginService.normalizeServerAddress(text) }
        userName = Self.string(dictionary[Key.userName])
        disablesMultipleAccounts = Self.bool(dictionary[Key.disableMultipleAccounts])
        enforcesAppLock = Self.bool(dictionary[Key.enforceAppLock])
        disablesLog = Self.bool(dictionary[Key.disableLog])
        disablesBackup = Self.bool(dictionary[Key.disableBackup])
    }

    /// The configuration in effect now. `UserDefaults` is thread-safe, so this can be read anywhere (the log writer, the
    /// app lock setting).
    public static func current(_ defaults: UserDefaults = .standard) -> ManagedConfiguration {
        ManagedConfiguration(defaults.dictionary(forKey: defaultsKey))
    }

    /// Something is managed: Settings says so where it matters.
    public var isManaged: Bool { self != ManagedConfiguration() }

    // MARK: Login policy

    /// Why a login to this server is not allowed, or nil.
    public func loginRefusal(serverURL: URL) -> LoginRefusal? {
        guard let managed = self.serverURL else { return nil }
        return Self.sameServer(managed, serverURL) ? nil : .otherServer(managed)
    }

    /// Why this login may not become an account next to `existing`, or nil. Logging in again to an account that is already
    /// on the device (same server and user) is always allowed.
    public func loginRefusal(serverURL: URL, loginName: String, existing: [Account]) -> LoginRefusal? {
        if let refusal = loginRefusal(serverURL: serverURL) { return refusal }
        guard disablesMultipleAccounts, !existing.isEmpty else { return nil }
        let again = existing.contains { Self.sameServer($0.serverURL, serverURL) && ($0.loginName == loginName || $0.userId == loginName) }
        return again ? nil : .multipleAccounts
    }

    /// Whether another account may be added (the "Add account" buttons).
    public func allowsAddingAccount(existing: [Account]) -> Bool {
        !(disablesMultipleAccounts && !existing.isEmpty)
    }

    /// The Login Flow's page with the managed user name proposed (`?user=`, read by the server's login page).
    public func loginPage(_ url: URL) -> URL {
        guard let userName, !userName.isEmpty else { return url }
        return url.appending(queryItems: [URLQueryItem(name: "user", value: userName)])
    }

    /// Same host, port and path; the scheme only counts where the managed address names https (a login over http to a
    /// server that is managed with https is another server).
    static func sameServer(_ managed: URL, _ other: URL) -> Bool {
        func path(_ url: URL) -> String { url.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        func port(_ url: URL) -> Int? { url.port ?? (url.scheme?.lowercased() == "http" ? 80 : 443) }
        let schemeMatches = managed.scheme?.lowercased() != "https" || other.scheme?.lowercased() == "https"
        return schemeMatches && managed.host()?.lowercased() == other.host()?.lowercased() && port(managed) == port(other)
            && path(managed) == path(other)
    }

    private static func string(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    private static func bool(_ value: Any?) -> Bool {
        switch value {
        case let flag as Bool: flag
        case let number as NSNumber: number.boolValue
        case let text as String: ["true", "yes", "1"].contains(text.lowercased().trimmingCharacters(in: .whitespaces))
        default: false
        }
    }
}

/// Why the managed configuration refuses a login.
public enum LoginRefusal: Error, Equatable, LocalizedError {
    /// Only the managed server is allowed.
    case otherServer(URL)
    /// Only one account is allowed, and there is one.
    case multipleAccounts

    public var errorDescription: String? {
        switch self {
        case .otherServer(let server):
            let name = server.host(percentEncoded: false) ?? server.absoluteString
            return String(
                localized: "Your organization only allows logging in to \(name).", bundle: .module,
                comment: "Login refused by the device management. The placeholder is the server's host name.")
        case .multipleAccounts:
            return String(
                localized: "Your organization allows only one account in this app.", bundle: .module,
                comment: "Login refused by the device management: a second account cannot be added.")
        }
    }
}
