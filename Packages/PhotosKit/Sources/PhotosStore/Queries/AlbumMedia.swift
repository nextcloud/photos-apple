// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import PhotosModel

extension CollectionStore {
    /// The items of an album in the album's order, as full items: those of the index and those that are only in the album
    /// (shared albums). For screens that show the photos one by one (the Apple TV app, SPEC §15.3).
    public func albumMedia(albumId: String) async throws -> [MediaItem] {
        try await database.writer.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT fileId FROM albumItem WHERE albumId = ? ORDER BY position", arguments: [albumId])
            let ids: [FileID] = rows.map { $0["fileId"] }
            var byId: [FileID: MediaItem] = [:]
            for item in try MediaItem.fetchAll(db, keys: ids) { byId[item.fileId] = item }
            for record in try CollectionMediaRecord.fetchAll(db, keys: ids.filter { byId[$0] == nil }) { byId[record.fileId] = record.item }
            return ids.compactMap { byId[$0] }.filter { !$0.isLivePhotoVideo }
        }
    }

    /// One item of the index or of an album only (a shared album's cover).
    public func mediaItem(fileId: FileID) throws -> MediaItem? {
        try database.writer.read { db in
            try MediaItem.fetchOne(db, key: fileId) ?? CollectionMediaRecord.fetchOne(db, key: fileId)?.item
        }
    }
}
