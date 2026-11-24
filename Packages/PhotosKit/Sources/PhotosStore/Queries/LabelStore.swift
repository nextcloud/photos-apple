// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import PhotosModel
import PhotosNetworking

/// Local copies of what the search index needs beyond the file itself (SPEC SR-3): system tags and their files, people
/// and their photos (both read from the server by `LabelSync`), and the labels this device recognised in previews.
///
/// Writing any of them updates the full-text index through the triggers of `SearchLabels`.
public struct LabelStore: Sendable {
    public let database: AccountDatabase

    public init(database: AccountDatabase) {
        self.database = database
    }

    // MARK: Tags

    /// The tags known locally, most used first.
    public func tags() throws -> [SystemTag] {
        try database.writer.read { db in
            try SystemTag.fetchAll(db, sql: "SELECT * FROM tag ORDER BY itemCount DESC, name")
        }
    }

    /// The stored count of each tag: the server's count when its files were last read, -1 when they must be read again.
    func storedTagCounts() throws -> [Int: Int] {
        try database.writer.read { db in
            Dictionary(
                try Row.fetchAll(db, sql: "SELECT id, itemCount FROM tag").map { ($0["id"] as Int, $0["itemCount"] as Int) },
                uniquingKeysWith: { first, _ in first })
        }
    }

    /// Takes the server's tag list: names and flags are updated, tags that are gone are removed with their memberships.
    /// The counts stay as they were (new tags get -1) until `setMembers(ofTag:)` stores the files they count.
    public func mergeTags(_ tags: [SystemTag]) throws {
        try database.writer.write { db in
            let keep = Set(tags.map(\.id))
            for id in try Int.fetchAll(db, sql: "SELECT id FROM tag") where !keep.contains(id) {
                _ = try SystemTag.deleteOne(db, key: id)
            }
            for tag in tags {
                try db.execute(
                    sql: """
                        INSERT INTO tag(id, name, isUserVisible, isUserAssignable, canAssign, itemCount, coverFileId, color)
                        VALUES (?, ?, ?, ?, ?, -1, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET name = excluded.name, isUserVisible = excluded.isUserVisible,
                            isUserAssignable = excluded.isUserAssignable, canAssign = excluded.canAssign,
                            coverFileId = excluded.coverFileId, color = excluded.color
                        """,
                    arguments: [tag.id, tag.name, tag.isUserVisible, tag.isUserAssignable, tag.canAssign, tag.coverFileId, tag.color])
            }
        }
    }

    /// Stores the files of a tag (only what changed is written, so the index is touched for those files alone) and the
    /// server count they belong to.
    public func setMembers(ofTag tagId: Int, _ fileIds: Set<FileID>, serverCount: Int) throws {
        try database.writer.write { db in
            let stored = Set(try FileID.fetchAll(db, sql: "SELECT fileId FROM tagItem WHERE tagId = ?", arguments: [tagId]))
            for fileId in stored.subtracting(fileIds) {
                try db.execute(sql: "DELETE FROM tagItem WHERE tagId = ? AND fileId = ?", arguments: [tagId, fileId])
            }
            for fileId in fileIds.subtracting(stored) {
                try db.execute(sql: "INSERT OR IGNORE INTO tagItem(tagId, fileId) VALUES (?, ?)", arguments: [tagId, fileId])
            }
            try db.execute(sql: "UPDATE tag SET itemCount = ? WHERE id = ?", arguments: [serverCount, tagId])
        }
    }

    /// The tags of one file as the server reported them just now (tag sheet): replaces what is stored for the file.
    public func setTags(_ tags: [SystemTag], ofFile fileId: FileID) throws {
        try database.writer.write { db in
            for tag in tags {
                try db.execute(
                    sql:
                        "INSERT OR IGNORE INTO tag(id, name, isUserVisible, isUserAssignable, canAssign, itemCount) VALUES (?, ?, ?, ?, ?, -1)",
                    arguments: [tag.id, tag.name, tag.isUserVisible, tag.isUserAssignable, tag.canAssign])
            }
            let ids = Set(tags.map(\.id))
            let stored = Set(try Int.fetchAll(db, sql: "SELECT tagId FROM tagItem WHERE fileId = ?", arguments: [fileId]))
            for id in stored.subtracting(ids) {
                try db.execute(sql: "DELETE FROM tagItem WHERE tagId = ? AND fileId = ?", arguments: [id, fileId])
            }
            for id in ids.subtracting(stored) {
                try db.execute(sql: "INSERT OR IGNORE INTO tagItem(tagId, fileId) VALUES (?, ?)", arguments: [id, fileId])
            }
        }
    }

    /// The tag ids of each of the files (files without tags are missing).
    public func tagIds(of fileIds: [FileID]) throws -> [FileID: Set<Int>] {
        guard !fileIds.isEmpty else { return [:] }
        return try database.writer.read { db in
            var result: [FileID: Set<Int>] = [:]
            for chunk in stride(from: 0, to: fileIds.count, by: 500).map({ fileIds[$0..<min($0 + 500, fileIds.count)] }) {
                let marks = chunk.map { _ in "?" }.joined(separator: ",")
                for row in try Row.fetchAll(
                    db, sql: "SELECT fileId, tagId FROM tagItem WHERE fileId IN (\(marks))", arguments: StatementArguments(Array(chunk)))
                {
                    result[row["fileId"], default: []].insert(row["tagId"])
                }
            }
            return result
        }
    }

    /// Indexed items with a tag, newest first (browsing a tag without the server).
    public func items(withTag tagId: Int) throws -> [MediaItem] {
        try database.writer.read { db in
            try MediaItem.fetchAll(
                db,
                sql:
                    "SELECT * FROM media WHERE isLivePhotoVideo = 0 AND isArchived = 0 AND fileId IN (SELECT fileId FROM tagItem WHERE tagId = ?) ORDER BY timestamp DESC",
                arguments: [tagId])
        }
    }

    /// Files with a tag (search filter without the server).
    public func fileIds(withTag tagId: Int) throws -> Set<FileID> {
        try database.writer.read { db in
            Set(try FileID.fetchAll(db, sql: "SELECT fileId FROM tagItem WHERE tagId = ?", arguments: [tagId]))
        }
    }

    // MARK: People

    func storedPersonCounts() throws -> [String: Int] {
        try database.writer.read { db in
            Dictionary(
                try Row.fetchAll(db, sql: "SELECT name, itemCount FROM person").map { ($0["name"] as String, $0["itemCount"] as Int) },
                uniquingKeysWith: { first, _ in first })
        }
    }

    /// Takes the server's people: like `mergeTags`, counts stay until the photos are stored.
    public func mergePeople(_ people: [Person]) throws {
        try database.writer.write { db in
            let keep = Set(people.map(\.name))
            for name in try String.fetchAll(db, sql: "SELECT name FROM person") where !keep.contains(name) {
                _ = try PersonRecord.deleteOne(db, key: name)
            }
            for person in people {
                let box = try person.coverBox.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
                try db.execute(
                    sql: """
                        INSERT INTO person(name, itemCount, coverFileId, coverBox) VALUES (?, -1, ?, ?)
                        ON CONFLICT(name) DO UPDATE SET coverFileId = excluded.coverFileId, coverBox = excluded.coverBox
                        """,
                    arguments: [person.name, person.coverFileId, box])
            }
        }
    }

    public func setMembers(ofPerson name: String, _ members: [PhotosAPI.PersonMember], serverCount: Int) throws {
        try database.writer.write { db in
            let stored = Set(
                try Int.fetchAll(db, sql: "SELECT detectionId FROM personItem WHERE person = ?", arguments: [name]))
            let byDetection = Dictionary(members.map { ($0.detectionId, $0) }, uniquingKeysWith: { first, _ in first })
            for id in stored.subtracting(byDetection.keys) {
                try db.execute(sql: "DELETE FROM personItem WHERE person = ? AND detectionId = ?", arguments: [name, id])
            }
            for (id, member) in byDetection where !stored.contains(id) {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO personItem(person, detectionId, fileId, childName) VALUES (?, ?, ?, ?)",
                    arguments: [name, id, member.fileId, member.childName])
            }
            try db.execute(sql: "UPDATE person SET itemCount = ? WHERE name = ?", arguments: [serverCount, name])
        }
    }

    /// Files a person is in (search filter without the server).
    public func fileIds(ofPerson name: String) throws -> Set<FileID> {
        try database.writer.read { db in
            Set(try FileID.fetchAll(db, sql: "SELECT fileId FROM personItem WHERE person = ?", arguments: [name]))
        }
    }

    /// Named people known locally (search suggestions without the server).
    public func personNames() throws -> [String] {
        try database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM person WHERE name GLOB '*[^0-9]*' ORDER BY itemCount DESC")
        }
    }

    // MARK: Labels recognised on this device

    /// A photo whose cached preview can be labelled.
    public struct VisionCandidate: Sendable, Hashable {
        public var fileId: FileID
        public var etag: String
    }

    /// Images without labels for their current version, by descending file id (roughly newest uploads first), after
    /// `before` when given: a run pages through them and skips what it cannot label now without asking for it again.
    public func visionCandidates(limit: Int, before: FileID? = nil) throws -> [VisionCandidate] {
        try database.writer.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT media.fileId, media.etag FROM media LEFT JOIN visionLabel ON visionLabel.fileId = media.fileId
                    WHERE media.kind = 'image' AND media.isLivePhotoVideo = 0 AND media.hasPreview = 1 AND media.fileId < ?
                        AND (visionLabel.fileId IS NULL OR visionLabel.etag <> media.etag)
                    ORDER BY media.fileId DESC LIMIT ?
                    """, arguments: [before ?? FileID.max, limit]
            )
            .map { VisionCandidate(fileId: $0["fileId"], etag: $0["etag"]) }
        }
    }

    /// Stores what was recognised (an empty list too: the photo was looked at and is not looked at again).
    public func setVisionLabels(_ results: [(candidate: VisionCandidate, labels: [String])], at date: Date = Date()) throws {
        guard !results.isEmpty else { return }
        try database.writer.write { db in
            for (candidate, labels) in results {
                try db.execute(
                    sql: """
                        INSERT INTO visionLabel(fileId, etag, labels, labeledAt) VALUES (?, ?, ?, ?)
                        ON CONFLICT(fileId) DO UPDATE SET etag = excluded.etag, labels = excluded.labels, labeledAt = excluded.labeledAt
                        """,
                    arguments: [candidate.fileId, candidate.etag, labels.joined(separator: " "), date.timeIntervalSince1970])
            }
        }
    }

    /// How many photos have been looked at, and how many images there are (Settings).
    public func visionProgress() throws -> (labeled: Int, total: Int) {
        try database.writer.read { db in
            let total =
                try Int.fetchOne(
                    db, sql: "SELECT count(*) FROM media WHERE kind = 'image' AND isLivePhotoVideo = 0 AND hasPreview = 1") ?? 0
            let labeled =
                try Int.fetchOne(
                    db,
                    sql:
                        "SELECT count(*) FROM visionLabel JOIN media ON media.fileId = visionLabel.fileId AND media.etag = visionLabel.etag"
                )
                ?? 0
            return (labeled, total)
        }
    }

    /// Forgets every recognised label (the user turned the feature off).
    public func deleteVisionLabels() throws {
        try database.writer.write { db in try db.execute(sql: "DELETE FROM visionLabel") }
    }
}
