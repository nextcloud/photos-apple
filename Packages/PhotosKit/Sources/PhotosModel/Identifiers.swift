// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

/// Nextcloud file id (`oc:fileid`). Primary key of media everywhere (previews, albums, faces).
public typealias FileID = Int64

/// Identifies one account: `"<userId> <serverURL>"`, the same convention as the Nextcloud Files app.
public struct AccountID: Hashable, Codable, Sendable, RawRepresentable, CustomStringConvertible, Comparable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(userId: String, serverURL: URL) {
        self.rawValue = "\(userId) \(serverURL.absoluteString)"
    }

    public var description: String { rawValue }

    /// A short, file-system safe key derived from the account id (used for per-account directories).
    public var storageKey: String {
        let digest = SHA256.hash(data: Data(rawValue.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    public static func < (lhs: AccountID, rhs: AccountID) -> Bool { lhs.rawValue < rhs.rawValue }
}
