// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import PhotosModel

/// The per-account SQLite database (SPEC §5.4.2). Readers anywhere (app, widgets, extensions); writers serialize through GRDB.
public final class AccountDatabase: Sendable {
    public let writer: DatabasePool
    public let url: URL

    public init(url: URL, readOnly: Bool = false) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.readonly = readOnly
        configuration.label = "PhotosStore"
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        writer = try DatabasePool(path: url.path(percentEncoded: false), configuration: configuration)
        if !readOnly {
            try Self.migrator.migrate(writer)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path(percentEncoded: false))
        }
    }

    /// In-memory-like temporary database for tests and previews.
    public static func temporary() throws -> AccountDatabase {
        let url = FileManager.default.temporaryDirectory.appending(path: "photos-\(UUID().uuidString).sqlite")
        return try AccountDatabase(url: url)
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "media") { t in
                t.primaryKey("fileId", .integer)
                t.column("path", .text).notNull()
                t.column("name", .text).notNull()
                t.column("mimeType", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("size", .integer).notNull().defaults(to: 0)
                t.column("etag", .text).notNull().defaults(to: "")
                t.column("modifiedAt", .double).notNull()
                t.column("uploadedAt", .double)
                t.column("capturedAt", .double)
                t.column("captureOffset", .integer)
                t.column("width", .integer)
                t.column("height", .integer)
                t.column("latitude", .double)
                t.column("longitude", .double)
                t.column("altitude", .double)
                t.column("place", .text)
                t.column("placeCountry", .text)
                t.column("isFavorite", .boolean).notNull().defaults(to: false)
                t.column("permissions", .text).notNull().defaults(to: "")
                t.column("mountType", .text).notNull().defaults(to: "")
                t.column("ownerId", .text)
                t.column("ownerDisplayName", .text)
                t.column("hasPreview", .boolean).notNull().defaults(to: true)
                t.column("blurhash", .text)
                t.column("livePhotoPeer", .integer)
                t.column("isLivePhotoVideo", .boolean).notNull().defaults(to: false)
                t.column("caption", .text)
                t.column("isArchived", .boolean).notNull().defaults(to: false)
                t.column("duration", .double)
                t.column("timestamp", .double).generatedAs(sql: "coalesce(capturedAt, modifiedAt)", .virtual)
                // Sync bookkeeping
                t.column("syncGeneration", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "media_timestamp", on: "media", columns: ["timestamp"])
            try db.create(index: "media_kind_timestamp", on: "media", columns: ["kind", "timestamp"])
            try db.create(index: "media_favorite", on: "media", columns: ["isFavorite"])
            try db.create(index: "media_place", on: "media", columns: ["place"])
            try db.create(index: "media_location", on: "media", columns: ["latitude", "longitude"])
            try db.create(index: "media_path", on: "media", columns: ["path"])
            try db.create(index: "media_peer", on: "media", columns: ["livePhotoPeer"])

            try db.create(table: "album") { t in
                t.primaryKey("id", .text)  // "<kind>:<name>"
                t.column("kind", .text).notNull()
                t.column("name", .text).notNull()
                t.column("title", .text).notNull()
                t.column("ownerId", .text)
                t.column("ownerDisplayName", .text)
                t.column("location", .text).notNull().defaults(to: "")
                t.column("albumDescription", .text).notNull().defaults(to: "")
                t.column("coverFileId", .integer)
                t.column("lastPhotoFileId", .integer)
                t.column("itemCount", .integer).notNull().defaults(to: 0)
                t.column("dateStart", .double)
                t.column("dateEnd", .double)
                t.column("filters", .text)
                t.column("collaborators", .text)
                t.column("serverAlbumId", .integer)
                t.column("lastModified", .double)
                t.column("publicToken", .text)
                t.column("fetchedAt", .double)
                t.column("contentFetchedAt", .double)
            }
            try db.create(table: "albumItem") { t in
                t.column("albumId", .text).notNull().references("album", onDelete: .cascade)
                t.column("fileId", .integer).notNull()
                t.column("childName", .text).notNull()
                t.column("origin", .text)
                t.column("ownerPath", .text)
                t.column("position", .integer).notNull().defaults(to: 0)
                t.primaryKey(["albumId", "fileId"])
            }
            try db.create(index: "albumItem_file", on: "albumItem", columns: ["fileId"])
            // Media of collections that is not part of the timeline index (e.g. photos of albums shared by others).
            try db.create(table: "collectionMedia") { t in
                t.primaryKey("fileId", .integer)
                t.column("item", .jsonText).notNull()
            }

            try db.create(table: "place") { t in
                t.primaryKey("name", .text)
                t.column("countryCode", .text)
                t.column("itemCount", .integer).notNull().defaults(to: 0)
                t.column("coverFileId", .integer)
            }
            try db.create(table: "placeItem") { t in
                t.column("place", .text).notNull().references("place", onDelete: .cascade)
                t.column("fileId", .integer).notNull()
                t.primaryKey(["place", "fileId"])
            }

            try db.create(table: "person") { t in
                t.primaryKey("name", .text)
                t.column("itemCount", .integer).notNull().defaults(to: 0)
                t.column("coverFileId", .integer)
                t.column("coverBox", .jsonText)
            }
            try db.create(table: "personItem") { t in
                t.column("person", .text).notNull().references("person", onDelete: .cascade, onUpdate: .cascade)
                t.column("detectionId", .integer).notNull()
                t.column("fileId", .integer).notNull()
                t.column("childName", .text).notNull()
                t.column("box", .jsonText)
                t.primaryKey(["person", "detectionId"])
            }
            try db.create(index: "personItem_file", on: "personItem", columns: ["fileId"])

            try db.create(table: "tag") { t in
                t.primaryKey("id", .integer)
                t.column("name", .text).notNull()
                t.column("isUserVisible", .boolean).notNull().defaults(to: true)
                t.column("isUserAssignable", .boolean).notNull().defaults(to: true)
                t.column("canAssign", .boolean).notNull().defaults(to: true)
                t.column("itemCount", .integer).notNull().defaults(to: 0)
                t.column("coverFileId", .integer)
                t.column("color", .text)
            }
            try db.create(table: "tagItem") { t in
                t.column("tagId", .integer).notNull().references("tag", onDelete: .cascade)
                t.column("fileId", .integer).notNull()
                t.primaryKey(["tagId", "fileId"])
            }

            try db.create(table: "smartAlbum") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("filters", .jsonText).notNull()
                t.column("isLocal", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "operation") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()
                t.column("payload", .jsonText).notNull()
                t.column("state", .text).notNull().defaults(to: "pending")
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("lastError", .text)
                t.column("createdAt", .double).notNull()
                t.column("nextAttemptAt", .double)
            }

            try db.create(table: "offlinePin") { t in
                t.primaryKey("id", .text)  // "album:<id>", "file:<fileId>", "place:<name>", "person:<name>", "smart:<id>"
                t.column("title", .text).notNull()
                t.column("createdAt", .double).notNull()
            }
            try db.create(table: "offlineFile") { t in
                t.primaryKey("fileId", .integer)
                t.column("etag", .text).notNull()
                t.column("localPath", .text).notNull()
                t.column("bytes", .integer).notNull()
                t.column("downloadedAt", .double).notNull()
            }

            try db.create(table: "faceDetections") { t in
                t.primaryKey("fileId", .integer)
                t.column("detections", .jsonText).notNull()
                t.column("fetchedAt", .double).notNull()
            }
            try db.create(table: "exifCache") { t in
                t.primaryKey("fileId", .integer)
                t.column("etag", .text).notNull()
                t.column("values", .jsonText).notNull()
            }

            try db.create(table: "syncState") { t in
                t.primaryKey("key", .text)
                t.column("value", .text)
            }

            try db.create(virtualTable: "searchIndex", using: FTS5()) { t in
                t.tokenizer = .unicode61(diacritics: .remove)
                t.column("fileId").notIndexed()
                t.column("text")
            }
        }
        migrator.registerMigration("v1-backup") { db in
            try db.create(table: "backupAsset") { t in
                t.column("localIdentifier", .text).notNull()
                t.column("resourceKind", .text).notNull()
                t.column("fingerprint", .text)
                t.column("state", .text).notNull()
                t.column("serverPath", .text)
                t.column("serverFileId", .integer)
                t.column("serverEtag", .text)
                t.column("matchedBy", .text)
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("lastError", .text)
                t.column("assetCreatedAt", .double)
                t.column("assetModifiedAt", .double)
                t.column("updatedAt", .double).notNull()
                t.primaryKey(["localIdentifier", "resourceKind"])
            }
            try db.create(index: "backupAsset_state", on: "backupAsset", columns: ["state"])
        }
        return migrator
    }
}

// MARK: - Key/value sync state

extension AccountDatabase {
    public func syncValue(_ key: String) throws -> String? {
        try writer.read { db in try String.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = ?", arguments: [key]) }
    }

    public func setSyncValue(_ key: String, _ value: String?) throws {
        try writer.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO syncState(key, value) VALUES (?, ?)", arguments: [key, value])
        }
    }
}
