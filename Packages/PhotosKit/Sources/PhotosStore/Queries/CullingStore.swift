// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import PhotosModel

/// Ratings and flags (SPEC §15.2) as the local index has them: the system tags named in `CullingTags` and their files,
/// which `LabelSync` copies from the server and `TagChange` changes at once when the user rates.
public struct CullingStore: Sendable {
    public let database: AccountDatabase

    public init(database: AccountDatabase) {
        self.database = database
    }

    /// `name COLLATE NOCASE IN (?, …)` for the names, with their arguments. NOCASE folds ASCII only, which is all
    /// "Pick" and "Rejected" need; the stars are compared as they are.
    static func nameCondition(_ names: [String], column: String = "tag.name") -> (String, StatementArguments) {
        let marks = names.map { _ in "?" }.joined(separator: ",")
        return ("\(column) COLLATE NOCASE IN (\(marks))", StatementArguments(names))
    }

    /// The files carrying one of the tags.
    static func filesWith(_ names: [String]) -> (String, StatementArguments) {
        let (condition, arguments) = nameCondition(names)
        return ("SELECT tagItem.fileId FROM tagItem JOIN tag ON tag.id = tagItem.tagId WHERE \(condition)", arguments)
    }

    /// The condition on `media.fileId` that shows only the photos of `filter`, for the grid queries (`LibraryStore`);
    /// nil for `.all`. The same rules as `CullingFilter.matches` (Pick wins over Rejected, the highest rating counts).
    static func condition(for filter: CullingFilter) -> (String, StatementArguments)? {
        func inside(_ names: [String]) -> (String, StatementArguments) {
            let (sql, arguments) = filesWith(names)
            return ("media.fileId IN (\(sql))", arguments)
        }
        func outside(_ names: [String]) -> (String, StatementArguments) {
            let (sql, arguments) = filesWith(names)
            return ("media.fileId NOT IN (\(sql))", arguments)
        }
        switch filter {
        case .all:
            return nil
        case .picks:
            return inside([CullingTags.pick])
        case .rejected:
            let rejected = inside([CullingTags.rejected])
            let picked = outside([CullingTags.pick])
            return ("\(rejected.0) AND \(picked.0)", rejected.1 + picked.1)
        case .unflagged:
            return outside([CullingTags.pick, CullingTags.rejected])
        case .notRejected:
            let rejected = outside([CullingTags.rejected])
            let picked = inside([CullingTags.pick])
            return ("(\(rejected.0) OR \(picked.0))", rejected.1 + picked.1)
        case .rating(let stars):
            return inside(Array(CullingTags.ratingNames.dropFirst(min(max(stars, 1), CullingTags.maxRating) - 1)))
        case .unrated:
            return outside(CullingTags.ratingNames)
        }
    }

    static let marksSQL: (String, StatementArguments) = {
        let (condition, arguments) = nameCondition(CullingTags.allNames)
        return ("SELECT tagItem.fileId, tag.name FROM tagItem JOIN tag ON tag.id = tagItem.tagId WHERE \(condition)", arguments)
    }()

    static func fetchMarks(_ db: Database) throws -> [FileID: CullingMark] {
        var names: [FileID: [String]] = [:]
        let (sql, arguments) = marksSQL
        for row in try Row.fetchAll(db, sql: sql, arguments: arguments) {
            names[row["fileId"], default: []].append(row["name"])
        }
        return names.compactMapValues { list in
            let mark = CullingTags.mark(fromTagNames: list)
            return mark.isEmpty ? nil : mark
        }
    }

    /// Every rated or flagged file. Small: only files someone rated or flagged are in it.
    public func marks() throws -> [FileID: CullingMark] {
        try database.writer.read { db in try Self.fetchMarks(db) }
    }

    /// The marks, again whenever a rating or flag changes (here or by the tag refresh).
    public func observeMarks() -> AsyncThrowingStream<[FileID: CullingMark], any Error> {
        ValueObservation.tracking { db in try Self.fetchMarks(db) }
            .removeDuplicates()
            .values(in: database.writer)
            .stream()
    }

    /// The culling tags each file has now, as named on the server (files without any are missing).
    public func cullingTagNames(of fileIds: [FileID]) throws -> [FileID: [String]] {
        guard !fileIds.isEmpty else { return [:] }
        return try database.writer.read { db in
            var result: [FileID: [String]] = [:]
            let (names, nameArguments) = Self.nameCondition(CullingTags.allNames)
            for start in stride(from: 0, to: fileIds.count, by: 500) {
                let chunk = Array(fileIds[start..<min(start + 500, fileIds.count)])
                let marks = chunk.map { _ in "?" }.joined(separator: ",")
                let sql = """
                    SELECT tagItem.fileId, tag.name FROM tagItem JOIN tag ON tag.id = tagItem.tagId
                    WHERE tagItem.fileId IN (\(marks)) AND \(names)
                    """
                for row in try Row.fetchAll(db, sql: sql, arguments: StatementArguments(chunk) + nameArguments) {
                    result[row["fileId"], default: []].append(row["name"])
                }
            }
            return result
        }
    }

    /// The culling tags the index knows, by meaning; a meaning with two tags (another case) keeps the one with the
    /// lower id, as the server's own lookup does.
    public func knownTags() throws -> [CullingTags.Meaning: SystemTag] {
        try database.writer.read { db in
            let (condition, arguments) = Self.nameCondition(CullingTags.allNames, column: "name")
            var result: [CullingTags.Meaning: SystemTag] = [:]
            for tag in try SystemTag.fetchAll(db, sql: "SELECT * FROM tag WHERE \(condition) ORDER BY id", arguments: arguments) {
                guard let meaning = CullingTags.meaning(of: tag.name), result[meaning] == nil else { continue }
                result[meaning] = tag
            }
            return result
        }
    }

    /// Notes a tag found or created on the server, so the next rating needs no lookup. Its files are read by the next
    /// tag refresh (count unknown).
    public func remember(_ tag: SystemTag) throws {
        try database.writer.write { db in
            try db.execute(
                sql:
                    "INSERT OR IGNORE INTO tag(id, name, isUserVisible, isUserAssignable, canAssign, itemCount) VALUES (?, ?, ?, ?, ?, -1)",
                arguments: [tag.id, tag.name, tag.isUserVisible, tag.isUserAssignable, tag.canAssign])
        }
    }

    /// The indexed photos and videos of a filter, newest first (archived and Live Photo motion parts left out):
    /// "Delete Rejected…".
    public func items(matching filter: CullingFilter, excludedFolders: [String] = []) throws -> [MediaItem] {
        try database.writer.read { db in
            var conditions = ["media.isLivePhotoVideo = 0", "media.isArchived = 0"]
            var arguments: StatementArguments = []
            if let (condition, values) = Self.condition(for: filter) {
                conditions.append(condition)
                arguments += values
            }
            for prefix in excludedFolders {
                conditions.append("media.path NOT LIKE ? ESCAPE '\\'")
                arguments += [LibraryStore.likePrefix(prefix)]
            }
            return try MediaItem.fetchAll(
                db, sql: "SELECT * FROM media WHERE \(conditions.joined(separator: " AND ")) ORDER BY timestamp DESC",
                arguments: arguments)
        }
    }
}
