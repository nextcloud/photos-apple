// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// The list of accounts and the active one, stored as JSON in the App Group.
public struct AccountRegistry: Codable, Sendable, Equatable {
    public var accounts: [Account]
    public var activeAccountID: AccountID?

    public init(accounts: [Account] = [], activeAccountID: AccountID? = nil) {
        self.accounts = accounts
        self.activeAccountID = activeAccountID
    }

    public var activeAccount: Account? {
        accounts.first { $0.id == activeAccountID } ?? accounts.first
    }

    public static func load(from url: URL = AppPaths.accountsFile) -> AccountRegistry {
        guard let data = try? Data(contentsOf: url), let registry = try? JSONDecoder().decode(AccountRegistry.self, from: data) else {
            return AccountRegistry()
        }
        return registry
    }

    public func save(to url: URL = AppPaths.accountsFile) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        #if os(macOS)
            try encoder.encode(self).write(to: url, options: [.atomic])
        #else
            try encoder.encode(self).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #endif
    }

    public mutating func upsert(_ account: Account) {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
    }

    public mutating func remove(_ id: AccountID) {
        accounts.removeAll { $0.id == id }
        if activeAccountID == id { activeAccountID = accounts.first?.id }
    }
}

/// Accounts known to other Nextcloud apps (Files, Talk, Notes) via `group.com.nextcloud.apps` (SPEC §5.1.3).
public enum SharedNextcloudAccounts {
    public struct Entry: Codable, Sendable, Hashable {
        public var url: String
        public var user: String
        public var name: String?
    }

    public static let group = "group.com.nextcloud.apps"

    /// Server/user pairs only; never passwords.
    public static func load() -> [Entry] {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return [] }
        let file = container.appending(path: "Library/Application Support/NextcloudAccounts/accounts.json")
        guard let data = try? Data(contentsOf: file),
            let root = try? JSONDecoder().decode([String: [String: [Entry]]].self, from: data)
        else { return [] }
        var seen = Set<String>()
        return (root["apps"] ?? [:]).values.flatMap { $0 }.filter { seen.insert("\($0.user)@\($0.url)").inserted }
    }
}
