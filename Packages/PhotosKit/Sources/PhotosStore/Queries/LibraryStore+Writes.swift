// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import PhotosDomain
import PhotosModel

extension LibraryStore {
    // MARK: Writes

    /// Inserts or updates index rows. Rows that are already stored exactly like this are not written again: a sync that
    /// re-reads known items (recent uploads, the overlap of the delta window) then neither rewrites rows and indexes nor
    /// wakes the observers of the timeline.
    public func upsert(_ items: [MediaItem]) throws {
        guard !items.isEmpty else { return }
        try database.writer.write { db in
            for chunk in items.chunked(1000) {
                var stored: [FileID: MediaItem] = [:]
                for item in try MediaItem.fetchAll(db, keys: chunk.map(\.fileId)) { stored[item.fileId] = item }
                for item in chunk where stored[item.fileId] != item { try item.upsert(db) }
            }
        }
    }

    public func delete(_ fileIds: [FileID]) throws {
        guard !fileIds.isEmpty else { return }
        try database.writer.write { db in
            for chunk in fileIds.chunked(5000) { _ = try MediaItem.deleteAll(db, keys: chunk) }
        }
    }

    /// Optimistic local update (outbox applies it on the server).
    public func update(_ fileId: FileID, _ change: @Sendable (inout MediaItem) -> Void) throws {
        try database.writer.write { db in
            guard var item = try MediaItem.fetchOne(db, key: fileId) else { return }
            change(&item)
            try item.update(db)
        }
    }

    /// Keeps items that are not in the timeline index (shared albums, other folders, people…) so viewers can show them.
    public func storeCollectionMedia(_ items: [MediaItem]) throws {
        try database.writer.write { db in
            for item in items where try !MediaItem.exists(db, key: item.fileId) {
                try CollectionMediaRecord(fileId: item.fileId, item: item).upsert(db)
            }
        }
    }

    /// Empties the timeline index and the sync state (the timeline folders changed). Albums and their content stay:
    /// they do not depend on the folders, and offline albums are defined by them.
    public func deleteIndex() throws {
        try database.writer.write { db in
            try db.execute(sql: SearchDescriptions.dropTriggersSQL)
            try db.execute(sql: SearchIndex.dropSQL)
            try db.execute(sql: "DELETE FROM media; DELETE FROM syncState; DELETE FROM reconcileUnseen; DELETE FROM reconcileSuspect")
            try db.execute(sql: SearchIndex.createSQL)
            try db.execute(sql: SearchDescriptions.triggersSQL)
        }
    }

    public func deleteAll() throws {
        try database.writer.write { db in
            // Without the triggers the tables are emptied in one step each instead of row by row.
            try db.execute(sql: SearchDescriptions.dropTriggersSQL)
            try db.execute(sql: SearchIndex.dropSQL)
            try db.execute(
                sql:
                    "DELETE FROM media; DELETE FROM albumItem; DELETE FROM album; DELETE FROM syncState; DELETE FROM reconcileUnseen; DELETE FROM reconcileSuspect"
            )
            try db.execute(sql: SearchIndex.createSQL)
            try db.execute(sql: SearchDescriptions.triggersSQL)
        }
    }
}
