// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// A file of settings shared by all of the user's devices (SPEC §22.5): one JSON file per kind in the hidden folder
/// `/.nextcloud-photos/` (`settings.json`, `people.json`, `family.json`…), each a map of keys to values.
///
/// Merging is **per key, the last writer wins** by the time the change was made (`modifiedAt`, milliseconds); a removal
/// is a tombstone so it reaches devices that were offline. Nothing a person typed is lost to a race: when two devices
/// changed the same key without having seen each other's change, the losing value is kept in the winner's `replaced`
/// list (the newest five), so a name given on one device survives a different name given at the same time on another.
/// Merging is commutative and idempotent: every device ends with the same document whatever order they write in.
public struct SyncedSettingsDocument: Codable, Hashable, Sendable {
    public static let format = "nextcloud-photos-settings"
    public static let currentVersion = 1
    /// How many replaced values a key keeps.
    public static let replacedLimit = 5
    /// Tombstones older than this are dropped when merging: every device has seen them by then.
    public static let tombstoneLifetime: TimeInterval = 90 * 86_400

    public struct Entry: Codable, Hashable, Sendable {
        /// nil for a removed key (a tombstone).
        public var value: JSONValue?
        /// When the change was made, to the millisecond.
        public var modifiedAt: Date
        /// `modifiedAt` of the version this change replaced, when the device knew one: tells a later change apart from a
        /// change made at the same time elsewhere.
        public var base: Date?
        /// Values that lost against this one in a race (newest first), kept so nothing typed is lost.
        public var replaced: [JSONValue]?

        public var isDeleted: Bool { value == nil }

        public init(value: JSONValue?, modifiedAt: Date, base: Date? = nil, replaced: [JSONValue]? = nil) {
            self.value = value
            self.modifiedAt = modifiedAt
            self.base = base
            self.replaced = replaced
        }

        enum CodingKeys: String, CodingKey { case value, modifiedAt, base, replaced, deleted }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            modifiedAt = try c.decode(Date.self, forKey: .modifiedAt)
            base = try? c.decodeIfPresent(Date.self, forKey: .base)
            replaced = try? c.decodeIfPresent([JSONValue].self, forKey: .replaced)
            let deleted = (try? c.decodeIfPresent(Bool.self, forKey: .deleted)) ?? false
            value = deleted ? nil : (try? c.decodeIfPresent(JSONValue.self, forKey: .value)) ?? nil
            if !deleted && value == nil { value = .null }
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(modifiedAt, forKey: .modifiedAt)
            try c.encodeIfPresent(base, forKey: .base)
            if let replaced, !replaced.isEmpty { try c.encode(replaced, forKey: .replaced) }
            if let value {
                try c.encode(value, forKey: .value)
            } else {
                try c.encode(true, forKey: .deleted)
            }
        }
    }

    public var format = Self.format
    public var version = Self.currentVersion
    /// The kind of settings (`people`, `family`…), the file's name without `.json`.
    public var kind: String
    public var entries: [String: Entry]

    public init(kind: String, entries: [String: Entry] = [:]) {
        self.kind = kind
        self.entries = entries
    }

    // MARK: Reading

    /// The value of a key; nil when it was never set or was removed.
    public func value(_ key: String) -> JSONValue? { entries[key]?.value }

    /// The value of a key decoded as `T`; nil when missing or of another shape.
    public func value<T: Decodable>(_ key: String, as type: T.Type) -> T? {
        guard let value = value(key), let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// The live (not removed) values, by key; with `prefix`, only the keys that start with it.
    public func values(prefix: String = "") -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for (key, entry) in entries where key.hasPrefix(prefix) {
            if let value = entry.value { result[key] = value }
        }
        return result
    }

    // MARK: Changing

    /// Sets (or with nil removes) a key, stamped `now`, or a moment after the version it replaces when the device clock is
    /// behind, so the change always wins over what it changes. Returns false when nothing changed.
    @discardableResult
    public mutating func set(_ value: JSONValue?, for key: String, now: Date = Date()) -> Bool {
        let previous = entries[key]
        if previous?.value == value && (value != nil || previous != nil) { return false }
        if previous == nil && value == nil { return false }
        let stamp = Self.stamp(after: previous?.modifiedAt, now: now)
        entries[key] = Entry(value: value, modifiedAt: stamp, base: previous?.modifiedAt, replaced: previous?.replaced)
        return true
    }

    /// Sets a key to an encodable value.
    @discardableResult
    public mutating func set<T: Encodable>(encoding value: T, for key: String, now: Date = Date()) -> Bool {
        guard let data = try? JSONEncoder().encode(value), let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return false
        }
        return set(json, for: key, now: now)
    }

    /// A change always gets a newer stamp than the version it changes, even when the device clock is behind.
    static func stamp(after previous: Date?, now: Date) -> Date {
        let now = rounded(now)
        guard let previous, previous >= now else { return now }
        return rounded(previous.addingTimeInterval(0.001))
    }

    /// To the millisecond the file keeps.
    static func rounded(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
    }

    // MARK: Merging

    /// Both documents in one: per key the later change; on the same time the one that sorts first by its JSON, so every
    /// device picks the same. Values that lost a race are kept in `replaced`. Tombstones older than
    /// `tombstoneLifetime` are dropped.
    public func merged(with other: SyncedSettingsDocument, now: Date = Date()) -> SyncedSettingsDocument {
        var result = SyncedSettingsDocument(kind: kind)
        result.version = max(version, other.version)
        let cutoff = now.addingTimeInterval(-Self.tombstoneLifetime)
        for key in Set(entries.keys).union(other.entries.keys) {
            let merged: Entry
            switch (entries[key], other.entries[key]) {
            case (let a?, let b?): merged = Self.merge(a, b)
            case (let a?, nil): merged = a
            case (nil, let b?): merged = b
            case (nil, nil): continue
            }
            if merged.isDeleted && merged.modifiedAt < cutoff { continue }
            result.entries[key] = merged
        }
        return result
    }

    static func merge(_ a: Entry, _ b: Entry) -> Entry {
        if a == b { return a }
        var winner = Self.winner(a, b)
        let loser = winner == a ? b : a
        var replaced = (a.replaced ?? []) + (b.replaced ?? [])
        // A race: the winner was not made over the loser. Its value (when it says something else) is kept.
        if let lost = loser.value, lost != winner.value, winner.base != loser.modifiedAt, loser.base != winner.modifiedAt {
            replaced.insert(lost, at: 0)
        }
        var unique: [JSONValue] = []
        for value in replaced where value != winner.value && !unique.contains(value) { unique.append(value) }
        winner.replaced = unique.isEmpty ? nil : Array(unique.prefix(Self.replacedLimit))
        return winner
    }

    static func winner(_ a: Entry, _ b: Entry) -> Entry {
        if a.modifiedAt != b.modifiedAt { return a.modifiedAt > b.modifiedAt ? a : b }
        if a.isDeleted != b.isDeleted { return a.isDeleted ? b : a }
        return sortKey(a) <= sortKey(b) ? a : b
    }

    private static func sortKey(_ entry: Entry) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var plain = entry
        plain.replaced = nil
        return (try? encoder.encode(plain)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    // MARK: Coding

    /// Dates with milliseconds: two devices changing a key within the same second still tell which change was later.
    static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            // Half a millisecond on: the style cuts off, so a time kept to the millisecond is written as that millisecond.
            let rounded = SyncedSettingsDocument.rounded(date).addingTimeInterval(0.0005)
            try container.encode(rounded.formatted(SyncedSettingsDocument.dateStyle))
        }
        return try encoder.encode(self)
    }

    /// A document read from the server or the device; nil when it is not one (another format, broken JSON).
    public static func decoded(_ data: Data) -> SyncedSettingsDocument? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? dateStyle.parse(text) { return rounded(date) }
            if let date = try? Date.ISO8601FormatStyle().parse(text) { return rounded(date) }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a date: \(text)"))
        }
        guard let document = try? decoder.decode(Lenient.self, from: data), document.format == format else { return nil }
        return SyncedSettingsDocument(kind: document.kind ?? "", entries: document.entries.compactMapValues(\.entry))
            .withVersion(document.version ?? currentVersion)
    }

    private func withVersion(_ version: Int) -> SyncedSettingsDocument {
        var copy = self
        copy.version = version
        return copy
    }

    /// Reads entries one by one: an entry this version cannot read is skipped rather than failing the whole file.
    private struct Lenient: Decodable {
        var format: String
        var version: Int?
        var kind: String?
        var entries: [String: Optional]

        struct Optional: Decodable {
            var entry: Entry?
            init(from decoder: any Decoder) throws { entry = try? Entry(from: decoder) }
        }
    }
}
