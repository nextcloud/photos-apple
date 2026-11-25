// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// A list that devices share through one JSON file in the user's Nextcloud (smart albums, folder rules; SPEC §16.4).
///
/// The file is written with `If-Match` on the ETag read just before (`AppDataFile`), so two devices never overwrite each
/// other blindly; when the write loses, the device reads again, merges and retries. The merge works record by record:
/// the newer `modifiedAt` wins, and deletions are tombstones, so a device that was offline does not bring a deleted
/// record back. Merging is commutative: both devices end with the same list whatever order they write in.
public struct SyncedList<Record: SyncedRecord>: Codable, Hashable, Sendable {
    public var version: Int
    public var records: [Record]

    public static var currentVersion: Int { 1 }

    public init(records: [Record] = []) {
        self.version = Self.currentVersion
        self.records = records
    }

    enum CodingKeys: String, CodingKey { case version, items }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? Self.currentVersion
        // A record this version cannot read is skipped rather than failing the whole list.
        let raw = (try? c.decode([RawJSON].self, forKey: .items)) ?? []
        records = raw.compactMap { value in
            guard let data = try? JSONEncoder().encode(value) else { return nil }
            return try? JSONDecoder().decode(Record.self, from: data)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(records, forKey: .items)
    }

    /// The records that are not deleted.
    public var live: [Record] { records.filter { !$0.isDeleted } }

    /// Tombstones older than this are dropped when merging: every device has seen them by then.
    public static var tombstoneLifetime: TimeInterval { 90 * 86_400 }

    /// Both lists in one: per id, the newer record (on a tie, the one that sorts first by its JSON, so every device picks
    /// the same). Order: the order of `self`, then new records of `other` in their order.
    public func merged(with other: SyncedList<Record>, now: Date = Date()) -> SyncedList<Record> {
        var byId: [String: Record] = [:]
        var order: [String] = []
        for record in records + other.records {
            if let existing = byId[record.id] {
                byId[record.id] = Self.winner(existing, record)
            } else {
                byId[record.id] = record
                order.append(record.id)
            }
        }
        let cutoff = now.addingTimeInterval(-Self.tombstoneLifetime)
        let merged = order.compactMap { byId[$0] }.filter { !($0.isDeleted && $0.modifiedAt < cutoff) }
        var result = SyncedList(records: merged)
        result.version = max(version, other.version)
        return result
    }

    static func winner(_ a: Record, _ b: Record) -> Record {
        if a.modifiedAt != b.modifiedAt { return a.modifiedAt > b.modifiedAt ? a : b }
        if a.isDeleted != b.isDeleted { return a.isDeleted ? a : b }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let left = (try? encoder.encode(a)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let right = (try? encoder.encode(b)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return left <= right ? a : b
    }

    /// Adds or replaces a record, stamping it now.
    public mutating func upsert(_ record: Record, now: Date = Date()) {
        var stamped = record
        stamped.modifiedAt = Self.stamp(after: records.first { $0.id == record.id }?.modifiedAt, now: now)
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = stamped
        } else {
            records.append(stamped)
        }
    }

    /// Replaces a record by a tombstone.
    public mutating func delete(id: String, now: Date = Date()) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].isDeleted = true
        records[index].modifiedAt = Self.stamp(after: records[index].modifiedAt, now: now)
    }

    /// A change always gets a newer stamp than the version it changes, even when the device clock is behind.
    static func stamp(after previous: Date?, now: Date) -> Date {
        guard let previous, previous >= now else { return now }
        return previous.addingTimeInterval(0.001)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decoded(_ data: Data) throws -> SyncedList<Record> {
        try JSONDecoder().decode(SyncedList<Record>.self, from: data)
    }
}
