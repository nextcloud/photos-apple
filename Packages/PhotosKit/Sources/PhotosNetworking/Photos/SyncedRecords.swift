// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Records of one kind kept in a synced settings file, one key per record (`<prefix><id>`), for features whose records
/// merge in their own way (SPEC §22.5.1): on-device People (`people.json`, `person/<id>`), where two devices that changed
/// the same person at once must keep both devices' faces.
///
/// The store merges per key, the later change wins, and keeps the values that lost a race in `replaced`; `load()` folds
/// those back with the feature's `merge`, so nothing either device said is lost.
///
/// People's `DevicePeopleNames` (SPEC §22.3) on top of it, wired at the merge of round 12:
/// ```swift
/// struct SyncedDevicePeopleNames: DevicePeopleNames {
///     let records: SyncedRecords<DevicePeopleDocument.Person>
///     init(_ files: SyncedSettingsFiles) {
///         records = SyncedRecords(store: files.store(.people), prefix: "person/") { a, b in
///             DevicePeopleDocument(people: ["p": a]).merged(with: DevicePeopleDocument(people: ["p": b])).people["p"] ?? a
///         }
///     }
///     func load() async throws -> DevicePeopleDocument { DevicePeopleDocument(people: records.load()) }
///     func update(_ change: @Sendable (inout DevicePeopleDocument) -> Void) async throws -> DevicePeopleDocument {
///         var document = try await load()
///         change(&document)
///         await records.replace(document.people)
///         return document
///     }
/// }
/// ```
public struct SyncedRecords<Value: Codable & Sendable>: Sendable {
    public let store: SyncedSettingsStore
    public let prefix: String
    /// Two versions of one record in one (commutative: either may be the newer).
    public let merge: @Sendable (Value, Value) -> Value

    public init(store: SyncedSettingsStore, prefix: String, merge: @escaping @Sendable (Value, Value) -> Value) {
        self.store = store
        self.prefix = prefix
        self.merge = merge
    }

    /// Every record by id, each with the versions that lost a race to it merged in.
    public func load() -> [String: Value] {
        var result: [String: Value] = [:]
        for (key, entry) in store.snapshot().entries where key.hasPrefix(prefix) {
            guard let json = entry.value, var record = Self.decode(json) else { continue }
            for lost in entry.replaced ?? [] {
                if let other = Self.decode(lost) { record = merge(record, other) }
            }
            result[String(key.dropFirst(prefix.count))] = record
        }
        return result
    }

    /// Makes the records `records`: changed ones are set, missing ones removed, unchanged ones left alone (one change).
    public func replace(_ records: [String: Value]) async {
        let current = load()
        var values: [String: JSONValue?] = [:]
        for (id, record) in records {
            guard let json = Self.encode(record) else { continue }
            if let old = current[id], Self.encode(old) == json { continue }
            values[prefix + id] = .some(json)
        }
        for id in current.keys where records[id] == nil { values[prefix + id] = .some(nil) }
        guard !values.isEmpty else { return }
        await store.set(values)
    }

    static func decode(_ json: JSONValue) -> Value? {
        guard let data = try? JSONEncoder().encode(json) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    static func encode(_ value: Value) -> JSONValue? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(value) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }
}
