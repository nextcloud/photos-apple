// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import PhotosDomain
import PhotosModel

/// What the sharing and family features keep in the account's database (SPEC §16.7): the family library's decisions
/// and the photos copied to the device for the Lock Screen.
public struct FamilyStore: Sendable {
    public let database: AccountDatabase

    public init(database: AccountDatabase) {
        self.database = database
    }

    /// What the user did with a suggested photo; such a photo is never suggested again.
    public enum Decision: String, Sendable {
        case moved, copied, dismissed
    }

    static func migrateDecisions(_ db: Database) throws {
        try db.create(table: "familyDecision") { t in
            t.primaryKey("fileId", .integer)
            t.column("decision", .text).notNull()
            t.column("decidedAt", .double).notNull()
        }
    }

    static func migrateDeviceMirror(_ db: Database) throws {
        try db.create(table: "deviceMirror") { t in
            t.column("fileId", .integer).notNull()
            t.column("etag", .text).notNull()
            t.column("localIdentifier", .text).notNull().unique()
        }
        try db.create(index: "deviceMirror_file", on: "deviceMirror", columns: ["fileId"])
    }

    // MARK: Family library (SPEC §16.7.2)

    public func decidedFileIds() throws -> Set<FileID> {
        try database.writer.read { db in Set(try FileID.fetchAll(db, sql: "SELECT fileId FROM familyDecision")) }
    }

    public func record(_ decision: Decision, for fileIds: [FileID], at date: Date = Date()) throws {
        try database.writer.write { db in
            for fileId in fileIds {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO familyDecision(fileId, decision, decidedAt) VALUES (?, ?, ?)",
                    arguments: [fileId, decision.rawValue, date.timeIntervalSince1970])
            }
        }
    }

    /// Forgets every decision (the user chose another family folder or asked to see dismissed photos again).
    public func forgetDecisions() throws {
        try database.writer.write { db in try db.execute(sql: "DELETE FROM familyDecision") }
    }

    public func decisionCount(_ decision: Decision) throws -> Int {
        try database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM familyDecision WHERE decision = ?", arguments: [decision.rawValue]) ?? 0
        }
    }

    /// The user's own photos and videos that could be suggested: in the user's own storage, outside the family folder
    /// and the excluded folders, not archived, no Live Photo motion parts; only those with one of `members` in them or
    /// taken within one of `days`. Each comes with the named people in it.
    public func candidates(
        members: [String], days: [DateInterval], familyFolder: String, excludedFolders: [String]
    ) async throws -> [(item: MediaItem, people: Set<String>)] {
        guard !members.isEmpty || !days.isEmpty else { return [] }
        var conditions = [LibraryStore.visible, "media.mountType = ''"]
        var arguments: StatementArguments = []
        for prefix in excludedFolders + [familyFolder] {
            conditions.append("media.path NOT LIKE ? ESCAPE '\\'")
            arguments += [LibraryStore.likePrefix(prefix)]
        }
        var matches: [String] = []
        if !members.isEmpty {
            let marks = Array(repeating: "?", count: members.count).joined(separator: ", ")
            matches.append("media.fileId IN (SELECT fileId FROM personItem WHERE person IN (\(marks)))")
            arguments += StatementArguments(members)
        }
        for day in days {
            matches.append("(\(LibraryStore.timestamp) >= ? AND \(LibraryStore.timestamp) < ?)")
            arguments += [day.start.timeIntervalSince1970, day.end.timeIntervalSince1970]
        }
        let sql = "SELECT media.* FROM media WHERE \(conditions.joined(separator: " AND ")) AND (\(matches.joined(separator: " OR ")))"
        let finalArguments = arguments
        return try await database.writer.read { db in
            let items = try MediaItem.fetchAll(db, sql: sql, arguments: finalArguments)
            var people: [FileID: Set<String>] = [:]
            let rows = try Row.fetchAll(
                db, sql: "SELECT fileId, person FROM personItem WHERE person GLOB '*[^0-9]*'")
            let wanted = Set(items.map(\.fileId))
            for row in rows {
                let fileId: FileID = row["fileId"]
                guard wanted.contains(fileId) else { continue }
                people[fileId, default: []].insert(row["person"])
            }
            return items.map { ($0, people[$0.fileId] ?? []) }
        }
    }

    /// The Live Photo motion parts of photos, to move or copy them along (file id of the photo → the motion part).
    public func livePhotoVideos(of fileIds: [FileID]) throws -> [FileID: MediaItem] {
        guard !fileIds.isEmpty else { return [:] }
        return try database.writer.read { db in
            var result: [FileID: MediaItem] = [:]
            for chunk in stride(from: 0, to: fileIds.count, by: 500).map({ Array(fileIds[$0..<min($0 + 500, fileIds.count)]) }) {
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
                let photos = try MediaItem.fetchAll(
                    db, sql: "SELECT * FROM media WHERE fileId IN (\(marks))", arguments: StatementArguments(chunk))
                for photo in photos {
                    guard let peer = photo.livePhotoPeer, let video = try MediaItem.fetchOne(db, key: peer), video.isLivePhotoVideo else {
                        continue
                    }
                    result[photo.fileId] = video
                }
            }
            return result
        }
    }

    /// The named people in each of some photos (for the Lock Screen album's hidden people).
    public func people(of fileIds: [FileID]) throws -> [FileID: Set<String>] {
        guard !fileIds.isEmpty else { return [:] }
        return try database.writer.read { db in
            var result: [FileID: Set<String>] = [:]
            for chunk in stride(from: 0, to: fileIds.count, by: 500).map({ Array(fileIds[$0..<min($0 + 500, fileIds.count)]) }) {
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
                for row in try Row.fetchAll(
                    db, sql: "SELECT fileId, person FROM personItem WHERE fileId IN (\(marks))", arguments: StatementArguments(chunk))
                {
                    result[row["fileId"], default: []].insert(row["person"])
                }
            }
            return result
        }
    }

    /// The named people, most photos first (to pick family members from).
    public func namedPeople() throws -> [Person] {
        try database.writer.read { db in
            try PersonRecord.fetchAll(
                db, sql: "SELECT * FROM person WHERE name GLOB '*[^0-9]*' AND itemCount != 0 ORDER BY itemCount DESC, name"
            ).map(\.person)
        }
    }

    // MARK: Weekly prompts (SPEC §16.7.3)

    /// The user's own photos and videos taken within `week`, newest first, as the library shows them.
    public func photosTaken(in week: DateInterval, excludedFolders: [String]) async throws -> [MediaItem] {
        var conditions = [LibraryStore.visible, "media.mountType = ''", "\(LibraryStore.timestamp) >= ?", "\(LibraryStore.timestamp) < ?"]
        var arguments: StatementArguments = [week.start.timeIntervalSince1970, week.end.timeIntervalSince1970]
        for prefix in excludedFolders {
            conditions.append("media.path NOT LIKE ? ESCAPE '\\'")
            arguments += [LibraryStore.likePrefix(prefix)]
        }
        let sql = "SELECT media.* FROM media WHERE \(conditions.joined(separator: " AND ")) \(LibraryStore.displayOrder) LIMIT 2000"
        let finalArguments = arguments
        return try await database.writer.read { db in try MediaItem.fetchAll(db, sql: sql, arguments: finalArguments) }
    }

    // MARK: Lock Screen album (SPEC §16.7.4)

    public func mirroredEntries() throws -> [DeviceMirror.Entry] {
        try database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT fileId, etag, localIdentifier FROM deviceMirror").map { row in
                DeviceMirror.Entry(fileId: row["fileId"], etag: row["etag"], localIdentifier: row["localIdentifier"])
            }
        }
    }

    public func addMirrored(_ entry: DeviceMirror.Entry) throws {
        try database.writer.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO deviceMirror(fileId, etag, localIdentifier) VALUES (?, ?, ?)",
                arguments: [entry.fileId, entry.etag, entry.localIdentifier])
        }
    }

    public func removeMirrored(localIdentifiers: [String]) throws {
        try database.writer.write { db in
            for identifier in localIdentifiers {
                try db.execute(sql: "DELETE FROM deviceMirror WHERE localIdentifier = ?", arguments: [identifier])
            }
        }
    }
}
