// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// A signed-in Nextcloud account. Secrets (the app password) are never part of this type; they live in the keychain.
public struct Account: Codable, Hashable, Sendable, Identifiable {
    public var id: AccountID
    /// Server base URL without trailing slash, e.g. `https://cloud.example.com` or `https://example.com/nextcloud`.
    public var serverURL: URL
    /// The user id used in DAV paths (may differ from the login name).
    public var userId: String
    /// The name used for HTTP basic authentication together with the app password.
    public var loginName: String
    public var displayName: String
    public var serverVersion: ServerVersion?
    /// True after a confirmed 401: the user has to sign in again. Local data is kept until the account is removed.
    public var isSignedOut: Bool
    public var addedAt: Date

    public init(
        serverURL: URL,
        userId: String,
        loginName: String,
        displayName: String,
        serverVersion: ServerVersion? = nil,
        isSignedOut: Bool = false,
        addedAt: Date = Date()
    ) {
        self.id = AccountID(userId: userId, serverURL: serverURL)
        self.serverURL = serverURL
        self.userId = userId
        self.loginName = loginName
        self.displayName = displayName
        self.serverVersion = serverVersion
        self.isSignedOut = isSignedOut
        self.addedAt = addedAt
    }

    /// Host for display, e.g. `cloud.example.com`.
    public var hostDisplayName: String {
        var host = serverURL.host() ?? serverURL.absoluteString
        if let port = serverURL.port { host += ":\(port)" }
        let path = serverURL.path(percentEncoded: false)
        if !path.isEmpty, path != "/" { host += path }
        return host
    }
}

/// Server version as reported by `status.php` / capabilities.
public struct ServerVersion: Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var micro: Int
    public var string: String

    public init(major: Int, minor: Int = 0, micro: Int = 0, string: String? = nil) {
        self.major = major
        self.minor = minor
        self.micro = micro
        self.string = string ?? "\(major).\(minor).\(micro)"
    }

    /// Parses `"33.0.1.2"` or `"36.0.0 dev"`.
    public init?(parsing value: String) {
        let numeric = value.split(whereSeparator: { !$0.isNumber && $0 != "." }).first.map(String.init) ?? value
        let parts = numeric.split(separator: ".").compactMap { Int($0) }
        guard let major = parts.first else { return nil }
        self.init(
            major: major,
            minor: parts.count > 1 ? parts[1] : 0,
            micro: parts.count > 2 ? parts[2] : 0,
            string: value
        )
    }

    public static let minimumSupportedMajor = 33

    public var isSupported: Bool { major >= Self.minimumSupportedMajor }

    public var description: String { string }

    public static func < (lhs: ServerVersion, rhs: ServerVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.micro) < (rhs.major, rhs.minor, rhs.micro)
    }
}
