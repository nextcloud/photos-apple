// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// An automation that runs after each sync (SPEC §16.4): photos matching `rule` get `action`. Stored in
/// `.nextcloud-photos/folder-rules.json`, so every device of the user has the same rules; only one device at a time runs
/// them (`FolderRuleLease`).
public struct FolderRule: SyncedRecord {
    public enum Action: Hashable, Sendable {
        /// Add to the own album of this name (created when missing).
        case addToAlbum(String)
        case archive
        case favorite
        /// Give the system tag of this name (created when missing).
        case addTag(String)
    }

    public var id: String
    public var name: String
    public var isEnabled: Bool
    public var rule: SmartRule
    public var action: Action
    /// Also act on photos that were already there when the rule was made; otherwise only on photos uploaded after
    /// `createdAt`.
    public var includesExisting: Bool
    public var createdAt: Date
    public var modifiedAt: Date
    public var isDeleted: Bool

    public init(
        id: String = UUID().uuidString, name: String, isEnabled: Bool = true, rule: SmartRule, action: Action,
        includesExisting: Bool = false, createdAt: Date = Date(), modifiedAt: Date = Date(), isDeleted: Bool = false
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.rule = rule
        self.action = action
        self.includesExisting = includesExisting
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.isDeleted = isDeleted
    }

    enum CodingKeys: String, CodingKey {
        case id, name, enabled, rule, action, album, tag, includesExisting, createdAt, modifiedAt, deleted
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        isEnabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        rule = (try? c.decode(RawJSON.self, forKey: .rule)).map(SmartRule.decodeLenient) ?? .all([])
        switch (try? c.decode(String.self, forKey: .action)) ?? "" {
        case "addToAlbum": action = .addToAlbum((try? c.decode(String.self, forKey: .album)) ?? "")
        case "archive": action = .archive
        case "favorite": action = .favorite
        case "addTag": action = .addTag((try? c.decode(String.self, forKey: .tag)) ?? "")
        default:
            // An action of a newer version: the rule is kept but never runs here.
            action = .addToAlbum("")
            isEnabled = false
        }
        includesExisting = (try? c.decode(Bool.self, forKey: .includesExisting)) ?? false
        createdAt = Date(timeIntervalSince1970: (try? c.decode(Double.self, forKey: .createdAt)) ?? 0)
        modifiedAt = Date(timeIntervalSince1970: (try? c.decode(Double.self, forKey: .modifiedAt)) ?? 0)
        isDeleted = (try? c.decode(Bool.self, forKey: .deleted)) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(isEnabled, forKey: .enabled)
        try c.encode(rule, forKey: .rule)
        switch action {
        case .addToAlbum(let album):
            try c.encode("addToAlbum", forKey: .action)
            try c.encode(album, forKey: .album)
        case .archive: try c.encode("archive", forKey: .action)
        case .favorite: try c.encode("favorite", forKey: .action)
        case .addTag(let tag):
            try c.encode("addTag", forKey: .action)
            try c.encode(tag, forKey: .tag)
        }
        try c.encode(includesExisting, forKey: .includesExisting)
        try c.encode(createdAt.timeIntervalSince1970, forKey: .createdAt)
        try c.encode(modifiedAt.timeIntervalSince1970, forKey: .modifiedAt)
        if isDeleted { try c.encode(true, forKey: .deleted) }
    }

    /// The rule can run: enabled, with a condition (a rule without one would act on every photo) and a complete action.
    public var isRunnable: Bool {
        guard isEnabled, !isDeleted, !rule.isEmpty, !rule.hasUnsupportedConditions else { return false }
        switch action {
        case .addToAlbum(let name), .addTag(let name): return !name.trimmingCharacters(in: .whitespaces).isEmpty
        case .archive, .favorite: return true
        }
    }
}

/// What the device running the rules remembers for all devices (`.nextcloud-photos/folder-rules-state.json`): the
/// photos each rule has handled (so a photo the user took out of the album again is not put back) and a log.
public struct FolderRuleState: Codable, Hashable, Sendable {
    public struct LogEntry: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var date: Date
        public var ruleId: String
        public var ruleName: String
        /// How many photos the rule acted on.
        public var count: Int
        /// The device that ran it (its name as the user set it).
        public var device: String
        /// Why it failed, when it did.
        public var error: String?

        public init(
            id: String = UUID().uuidString, date: Date, ruleId: String, ruleName: String, count: Int, device: String, error: String? = nil
        ) {
            self.id = id
            self.date = date
            self.ruleId = ruleId
            self.ruleName = ruleName
            self.count = count
            self.device = device
            self.error = error
        }
    }

    /// File ids each rule has acted on, by rule id.
    public var handled: [String: [FileID]]
    /// Newest first.
    public var log: [LogEntry]

    public init(handled: [String: [FileID]] = [:], log: [LogEntry] = []) {
        self.handled = handled
        self.log = log
    }

    public static let maxLogEntries = 200
    /// More handled ids per rule are dropped oldest first (they are then only protected by the action being done).
    public static let maxHandledPerRule = 50_000

    /// Notes what a run did.
    public mutating func record(_ entry: LogEntry, handled fileIds: [FileID]) {
        if !fileIds.isEmpty {
            var list = handled[entry.ruleId] ?? []
            let known = Set(list)
            list.append(contentsOf: fileIds.filter { !known.contains($0) })
            if list.count > Self.maxHandledPerRule { list.removeFirst(list.count - Self.maxHandledPerRule) }
            handled[entry.ruleId] = list
        }
        log.insert(entry, at: 0)
        if log.count > Self.maxLogEntries { log.removeLast(log.count - Self.maxLogEntries) }
    }

    /// Forgets rules that no longer exist.
    public mutating func prune(keeping ruleIds: Set<String>) {
        handled = handled.filter { ruleIds.contains($0.key) }
    }
}

/// The lock that lets one device at a time run the folder rules (`.nextcloud-photos/folder-rules.lock`). It expires, so
/// a device that went away does not block the others for long.
public struct FolderRuleLease: Codable, Hashable, Sendable {
    /// A random id of this app installation and account (not a hardware id).
    public var holder: String
    public var device: String
    public var expiresAt: Date

    public init(holder: String, device: String, expiresAt: Date) {
        self.holder = holder
        self.device = device
        self.expiresAt = expiresAt
    }

    /// How long a lease lasts; the runner renews it while it works.
    public static let duration: TimeInterval = 10 * 60

    /// Whether `holder` may take the lock now: there is none, it is its own, or it has expired.
    public static func canAcquire(_ current: FolderRuleLease?, holder: String, now: Date) -> Bool {
        guard let current else { return true }
        return current.holder == holder || current.expiresAt <= now
    }
}
