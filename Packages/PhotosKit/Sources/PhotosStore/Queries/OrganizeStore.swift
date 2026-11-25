// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import PhotosDomain
import PhotosModel

/// What smart album rules and folder rules read from the index (SPEC §16.4), and the camera details the index keeps
/// for them (make, model, lens, exposure from the server's EXIF; read in the background when a rule needs them).
public struct OrganizeStore: Sendable {
    public let database: AccountDatabase

    public init(database: AccountDatabase) {
        self.database = database
    }

    static func migrate(_ db: Database) throws {
        try db.create(table: "cameraDetails") { t in
            t.primaryKey("fileId", .integer)
            // The file version the details were read from: a changed file is read again.
            t.column("etag", .text).notNull()
            t.column("make", .text)
            t.column("model", .text)
            t.column("lens", .text)
            t.column("focalLength", .double)
            t.column("aperture", .double)
            t.column("iso", .double)
        }
    }

    /// Everything a rule may ask (`SmartRuleContext`), read in one transaction.
    /// - Parameter camera: also the camera details (only when a rule needs them; they are the largest part).
    public func ruleContext(camera: Bool, now: Date = Date()) async throws -> SmartRuleContext {
        try await database.writer.read { db in
            var context = SmartRuleContext(now: now)
            for row in try Row.fetchAll(
                db, sql: "SELECT tag.name AS name, tagItem.fileId AS fileId FROM tagItem JOIN tag ON tag.id = tagItem.tagId")
            {
                context.tagMembers[SmartRuleContext.fold(row["name"]), default: []].insert(row["fileId"])
            }
            for row in try Row.fetchAll(db, sql: "SELECT person, fileId FROM personItem") {
                context.personMembers[SmartRuleContext.fold(row["person"]), default: []].insert(row["fileId"])
            }
            let albumSQL =
                "SELECT album.name AS name, albumItem.fileId AS fileId FROM albumItem JOIN album ON album.id = albumItem.albumId WHERE album.kind = 'own'"
            for row in try Row.fetchAll(db, sql: albumSQL) {
                context.albumMembers[SmartRuleContext.fold(row["name"]), default: []].insert(row["fileId"])
            }
            context.marks = try CullingStore.fetchMarks(db)
            if camera {
                for row in try Row.fetchAll(db, sql: "SELECT * FROM cameraDetails") {
                    let details = CameraDetails(
                        make: row["make"], model: row["model"], lens: row["lens"], focalLength: row["focalLength"],
                        aperture: row["aperture"], iso: row["iso"])
                    if !details.isEmpty { context.camera[row["fileId"]] = details }
                }
            }
            return context
        }
    }

    /// The photos and videos rules look at: the visible library (no archive, no Live Photo motion parts), without the
    /// excluded folders.
    public func ruleItems(excludedFolders: [String] = []) async throws -> [MediaItem] {
        try await database.writer.read { db in
            var conditions = ["isLivePhotoVideo = 0", "isArchived = 0"]
            var arguments: StatementArguments = []
            for prefix in excludedFolders {
                conditions.append("path NOT LIKE ? ESCAPE '\\'")
                arguments += [LibraryStore.likePrefix(prefix)]
            }
            return try MediaItem.fetchAll(
                db, sql: "SELECT * FROM media WHERE \(conditions.joined(separator: " AND ")) ORDER BY timestamp DESC", arguments: arguments)
        }
    }

    /// Photos whose camera details are missing or older than the file, newest first.
    public func filesNeedingCameraDetails(limit: Int) async throws -> [FileID] {
        try await database.writer.read { db in
            try FileID.fetchAll(
                db,
                sql: """
                    SELECT media.fileId FROM media LEFT JOIN cameraDetails ON cameraDetails.fileId = media.fileId
                    WHERE media.kind = 'image' AND media.isLivePhotoVideo = 0 AND media.mountType != ?
                      AND (cameraDetails.fileId IS NULL OR cameraDetails.etag != media.etag)
                    ORDER BY media.timestamp DESC LIMIT ?
                    """, arguments: [MediaItem.collectionChildMountType, limit])
        }
    }

    /// How many photos have camera details, of all photos that can have them.
    public func cameraDetailsProgress() async throws -> (read: Int, total: Int) {
        try await database.writer.read { db in
            let total =
                try Int.fetchOne(
                    db, sql: "SELECT count(*) FROM media WHERE kind = 'image' AND isLivePhotoVideo = 0 AND mountType != ?",
                    arguments: [MediaItem.collectionChildMountType]) ?? 0
            let read =
                try Int.fetchOne(
                    db,
                    sql: """
                        SELECT count(*) FROM media JOIN cameraDetails ON cameraDetails.fileId = media.fileId AND cameraDetails.etag = media.etag
                        WHERE media.kind = 'image' AND media.isLivePhotoVideo = 0 AND media.mountType != ?
                        """, arguments: [MediaItem.collectionChildMountType]) ?? 0
            return (read, total)
        }
    }

    /// Stores details read from the server, for the file versions the index has now.
    public func storeCameraDetails(_ details: [FileID: CameraDetails]) async throws {
        guard !details.isEmpty else { return }
        try await database.writer.write { db in
            for (fileId, value) in details {
                guard let etag = try String.fetchOne(db, sql: "SELECT etag FROM media WHERE fileId = ?", arguments: [fileId]) else {
                    continue
                }
                try db.execute(
                    sql: """
                        INSERT OR REPLACE INTO cameraDetails(fileId, etag, make, model, lens, focalLength, aperture, iso)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [fileId, etag, value.make, value.model, value.lens, value.focalLength, value.aperture, value.iso])
            }
        }
    }

    /// The details of some files (rename patterns with `{camera}`).
    public func cameraDetails(of fileIds: [FileID]) throws -> [FileID: CameraDetails] {
        guard !fileIds.isEmpty else { return [:] }
        return try database.writer.read { db in
            var result: [FileID: CameraDetails] = [:]
            for start in stride(from: 0, to: fileIds.count, by: 500) {
                let chunk = Array(fileIds[start..<min(start + 500, fileIds.count)])
                let marks = chunk.map { _ in "?" }.joined(separator: ",")
                for row in try Row.fetchAll(
                    db, sql: "SELECT * FROM cameraDetails WHERE fileId IN (\(marks))", arguments: StatementArguments(chunk))
                {
                    result[row["fileId"]] = CameraDetails(
                        make: row["make"], model: row["model"], lens: row["lens"], focalLength: row["focalLength"],
                        aperture: row["aperture"], iso: row["iso"])
                }
            }
            return result
        }
    }

    /// The names of the files in some folders (`RenamePattern` avoids them), by folder.
    public func fileNames(inFolders folders: Set<String>) throws -> [String: Set<String>] {
        guard !folders.isEmpty else { return [:] }
        return try database.writer.read { db in
            var result: [String: Set<String>] = [:]
            for folder in folders {
                let rows = try Row.fetchAll(
                    db, sql: "SELECT path, name FROM media WHERE path LIKE ? ESCAPE '\\'", arguments: [LibraryStore.likePrefix(folder)])
                for row in rows {
                    let path: String = row["path"]
                    guard (path as NSString).deletingLastPathComponent == folder else { continue }
                    result[folder, default: []].insert(row["name"])
                }
            }
            return result
        }
    }

    /// Values for the rule builder's pickers: cameras and lenses the library has, most used first.
    public func cameraVocabulary(limit: Int = 30) async throws -> (cameras: [String], lenses: [String]) {
        try await database.writer.read { db in
            let cameras = try Row.fetchAll(
                db,
                sql:
                    "SELECT make, model, count(*) AS n FROM cameraDetails WHERE model IS NOT NULL GROUP BY make, model ORDER BY n DESC LIMIT ?",
                arguments: [limit]
            ).compactMap { row in CameraDetails(make: row["make"], model: row["model"]).cameraName }
            let lenses = try String.fetchAll(
                db, sql: "SELECT lens FROM cameraDetails WHERE lens IS NOT NULL GROUP BY lens ORDER BY count(*) DESC LIMIT ?",
                arguments: [limit])
            return (cameras, lenses)
        }
    }

    /// The folders of the library, for the folder picker (the parents of indexed files), most photos first.
    public func folders(limit: Int = 200) async throws -> [String] {
        try await database.writer.read { db in
            var counts: [String: Int] = [:]
            for path in try String.fetchAll(
                db, sql: "SELECT path FROM media WHERE isLivePhotoVideo = 0 AND mountType != ?",
                arguments: [MediaItem.collectionChildMountType])
            {
                counts[(path as NSString).deletingLastPathComponent, default: 0] += 1
            }
            return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(limit).map(\.key)
        }
    }
}
