// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import PhotosModel
import PhotosNetworking

/// Albums, places, people, tags and smart albums in the local store.
public struct CollectionStore: Sendable {
    public let database: AccountDatabase

    public init(database: AccountDatabase) {
        self.database = database
    }

    // MARK: Albums

    public func albums(_ kind: AlbumKind) throws -> [Album] {
        try database.writer.read { db in
            try AlbumRecord.filter(Column("kind") == kind.rawValue).fetchAll(db).map(\.album)
        }
    }

    public func observeAlbums(_ kind: AlbumKind) -> AsyncThrowingStream<[Album], any Error> {
        ValueObservation.tracking { db in try AlbumRecord.filter(Column("kind") == kind.rawValue).fetchAll(db).map(\.album) }
            .removeDuplicates()
            .values(in: database.writer)
            .stream()
    }

    public func album(id: String) throws -> Album? {
        try database.writer.read { db in try AlbumRecord.fetchOne(db, key: id)?.album }
    }

    public func observeAlbum(id: String) -> AsyncThrowingStream<Album?, any Error> {
        ValueObservation.tracking { db in try AlbumRecord.fetchOne(db, key: id)?.album }
            .removeDuplicates()
            .values(in: database.writer)
            .stream()
    }

    /// Replaces the album list of one kind (keeps content of albums that still exist).
    public func replaceAlbums(_ albums: [Album], kind: AlbumKind) throws {
        let now = Date()
        try database.writer.write { db in
            let existing = try AlbumRecord.filter(Column("kind") == kind.rawValue).fetchAll(db)
            try SharedAlbumActivity.record(existing: existing.map(\.album), incoming: albums, kind: kind, db: db, now: now)
            let byId = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let keep = Set(albums.map(\.id))
            for record in existing where !keep.contains(record.id) { _ = try record.delete(db) }
            for album in albums {
                try AlbumRecord(album, fetchedAt: now, contentFetchedAt: byId[album.id]?.contentFetchedAt).upsert(db)
            }
        }
    }

    public func upsertAlbum(_ album: Album) throws {
        try database.writer.write { db in
            let existing = try AlbumRecord.fetchOne(db, key: album.id)
            try AlbumRecord(album, fetchedAt: Date(), contentFetchedAt: existing?.contentFetchedAt).upsert(db)
        }
    }

    public func deleteAlbum(id: String) throws {
        try database.writer.write { db in _ = try AlbumRecord.deleteOne(db, key: id) }
    }

    /// Stores album content. Items that are not in the timeline index are kept in `collectionMedia`.
    ///
    /// Only what differs from the stored content is written: re-reading an unchanged album of 5000 photos writes one row
    /// (the album's fetch time) instead of deleting and inserting 5000.
    public func replaceAlbumContent(albumId: String, children: [MediaParser.CollectionChild]) throws {
        try database.writer.write { db in
            var stored: [FileID: AlbumItemRecord] = [:]
            for record in try AlbumItemRecord.filter(Column("albumId") == albumId).fetchAll(db) { stored[record.fileId] = record }
            // A file listed twice keeps its last place, as the rows inserted one after the other did.
            var wanted: [FileID: AlbumItemRecord] = [:]
            for (position, child) in children.enumerated() {
                wanted[child.item.fileId] = AlbumItemRecord(
                    albumId: albumId, fileId: child.item.fileId, childName: child.childName, origin: child.origin,
                    ownerPath: child.ownerPath, position: position)
            }
            let gone = stored.keys.filter { wanted[$0] == nil }
            for chunk in gone.chunked(500) {
                try db.execute(
                    sql: "DELETE FROM albumItem WHERE albumId = ? AND fileId IN (\(chunk.map { String($0) }.joined(separator: ",")))",
                    arguments: [albumId])
            }
            for record in wanted.values where stored[record.fileId] != record { try record.insert(db, onConflict: .replace) }
            // Items that are not in the index are kept for the viewer; written only when they changed.
            let ids = Array(wanted.keys)
            var indexed: Set<FileID> = []
            var kept: [FileID: MediaItem] = [:]
            for chunk in ids.chunked(500) {
                indexed.formUnion(
                    try FileID.fetchAll(
                        db, sql: "SELECT fileId FROM media WHERE fileId IN (\(chunk.map { String($0) }.joined(separator: ",")))"))
                for record in try CollectionMediaRecord.fetchAll(db, keys: Array(chunk)) { kept[record.fileId] = record.item }
            }
            for child in children where !indexed.contains(child.item.fileId) && kept[child.item.fileId] != child.item {
                try CollectionMediaRecord(fileId: child.item.fileId, item: child.item).upsert(db)
                kept[child.item.fileId] = child.item
            }
            try db.execute(
                sql: "UPDATE album SET contentFetchedAt = ?, itemCount = ? WHERE id = ?",
                arguments: [Date().timeIntervalSince1970, children.count, albumId])
            // What is still queued for the album is not on the server yet: it stays as the user left it.
            try Outbox.reapplyPendingAlbumChanges(albumId: albumId, db: db)
        }
    }

    /// The places of these photos in albums.
    public func memberships(of fileIds: [FileID]) throws -> [AlbumMembership] {
        guard !fileIds.isEmpty else { return [] }
        return try database.writer.read { db in
            var result: [AlbumMembership] = []
            for start in stride(from: 0, to: fileIds.count, by: 500) {
                let chunk = Array(fileIds[start..<min(start + 500, fileIds.count)])
                result += try AlbumItemRecord.filter(chunk.contains(Column("fileId"))).fetchAll(db).map {
                    AlbumMembership(
                        albumId: $0.albumId, fileId: $0.fileId, childName: $0.childName, origin: $0.origin, ownerPath: $0.ownerPath,
                        position: $0.position)
                }
            }
            return result
        }
    }

    /// Puts a photo back into an album it was taken out of locally (a delete that was taken back before it ran).
    static func insert(_ member: AlbumMembership, db: Database) throws {
        guard try AlbumRecord.exists(db, key: member.albumId) else { return }
        try AlbumItemRecord(
            albumId: member.albumId, fileId: member.fileId, childName: member.childName, origin: member.origin,
            ownerPath: member.ownerPath, position: member.position
        ).insert(db, onConflict: .ignore)
        if db.changesCount > 0 {
            try db.execute(sql: "UPDATE album SET itemCount = itemCount + 1 WHERE id = ?", arguments: [member.albumId])
        }
    }

    /// Marks an album's stored content as current without rewriting it (the server says it did not change).
    public func markAlbumContentFetched(albumId: String) throws {
        try database.writer.write { db in
            try db.execute(sql: "UPDATE album SET contentFetchedAt = ? WHERE id = ?", arguments: [Date().timeIntervalSince1970, albumId])
        }
    }

    /// The number of stored content rows of an album.
    public func albumItemCount(albumId: String) throws -> Int {
        try database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM albumItem WHERE albumId = ?", arguments: [albumId]) ?? 0
        }
    }

    public func albumItems(albumId: String) throws -> [AlbumItemInfo] {
        try database.writer.read { db in
            try Row.fetchAll(
                db, sql: "SELECT fileId, childName, origin, ownerPath FROM albumItem WHERE albumId = ? ORDER BY position",
                arguments: [albumId]
            )
            .map { AlbumItemInfo(fileId: $0["fileId"], childName: $0["childName"], origin: $0["origin"], ownerPath: $0["ownerPath"]) }
        }
    }

    /// Grid items of an album (index items and collection-only items).
    public func observeAlbumGrid(albumId: String) -> AsyncThrowingStream<[GridMedia], any Error> {
        ValueObservation.tracking { db -> [GridMedia] in
            let rows = try Row.fetchAll(db, sql: "SELECT fileId FROM albumItem WHERE albumId = ? ORDER BY position", arguments: [albumId])
            let ids: [FileID] = rows.map { $0["fileId"] }
            var byId: [FileID: GridMedia] = [:]
            for item in try MediaItem.fetchAll(db, keys: ids) { byId[item.fileId] = GridMedia(item) }
            for record in try CollectionMediaRecord.fetchAll(db, keys: ids.filter { byId[$0] == nil }) {
                byId[record.fileId] = GridMedia(record.item)
            }
            return ids.compactMap { byId[$0] }
        }
        .removeDuplicates()
        .values(in: database.writer)
        .stream()
    }

    public func albumContentFetchedAt(albumId: String) throws -> Date? {
        try database.writer.read { db in try AlbumRecord.fetchOne(db, key: albumId)?.contentFetchedAt }
    }

    // MARK: Places

    public func replacePlaces(_ places: [Place]) throws {
        try database.writer.write { db in
            _ = try Place.deleteAll(db)
            for place in places { try place.insert(db) }
        }
    }

    public func observePlaces() -> AsyncThrowingStream<[Place], any Error> {
        ValueObservation.tracking { db in try Place.order(Column("itemCount").desc).fetchAll(db) }
            .removeDuplicates()
            .values(in: database.writer)
            .stream()
    }

    // MARK: Smart albums

    public func smartAlbums() throws -> [(SmartAlbum, isLocal: Bool)] {
        try database.writer.read { db in
            try SmartAlbumRecord.fetchAll(db).map { (SmartAlbum(id: $0.id, name: $0.name, filters: $0.filters), $0.isLocal) }
        }
    }

    public func replaceSmartAlbums(_ albums: [SmartAlbum], isLocal: Bool) throws {
        try database.writer.write { db in
            _ = try SmartAlbumRecord.filter(Column("isLocal") == isLocal).deleteAll(db)
            for album in albums {
                try SmartAlbumRecord(id: album.id, name: album.name, filters: album.filters, isLocal: isLocal).upsert(db)
            }
        }
    }
}

/// A photo's place in an album, as the index has it.
public struct AlbumMembership: Hashable, Sendable {
    public var albumId: String
    public var fileId: FileID
    /// Name of the photo inside the album collection.
    public var childName: String
    /// `filters` for a photo the album's filters put there (it cannot be removed or added by hand).
    public var origin: String?
    public var ownerPath: String?
    public var position: Int

    public init(albumId: String, fileId: FileID, childName: String, origin: String?, ownerPath: String?, position: Int) {
        self.albumId = albumId
        self.fileId = fileId
        self.childName = childName
        self.origin = origin
        self.ownerPath = ownerPath
        self.position = position
    }
}

public struct AlbumItemInfo: Hashable, Sendable {
    public var fileId: FileID
    public var childName: String
    public var origin: String?
    public var ownerPath: String?

    public var isRemovable: Bool { origin != "filters" }
}
