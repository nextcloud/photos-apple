// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import PhotosDomain
import PhotosModel
import PhotosStore

/// Where the photos around the user come from (SPEC §15.4): the photo frame widget and the Mac's desktop pictures.
public enum AmbientSource: Codable, Hashable, Sendable {
    /// The favourites.
    case favorites
    /// On this day; on a day without, the newest memory (year in review, then trips).
    case memories
    /// An album of the account, by its id (`Album.id`); the title is kept to name it while it is not loaded.
    case album(id: String, title: String)
    /// The whole library, newest first.
    case library

    /// A stable text for the source, for the seed of its shuffled order (`AmbientRotation.seed`).
    public var key: String {
        switch self {
        case .favorites: "favorites"
        case .memories: "memories"
        case .album(let id, _): "album:\(id)"
        case .library: "library"
        }
    }
}

/// Reads the photos of an ambient source from the account's store. Only still images: no videos, no motion halves of
/// Live Photos, nothing archived (SPEC §7.22: widgets never show archived photos).
public enum AmbientPhotos {
    /// At most this many photos take part in a rotation; enough for weeks of changing pictures.
    public static let limit = 500

    /// An item may hang on a wall or a desktop.
    public static func isEligible(_ item: MediaItem) -> Bool {
        item.kind == .image && !item.isLivePhotoVideo && !item.isArchived
    }

    /// The photos of `source`, in the source's order (newest first; an album in its own order).
    public static func items(
        _ source: AmbientSource, library: LibraryStore, collections: CollectionStore, now: Date = Date(), calendar: Calendar = .current
    ) async throws -> [MediaItem] {
        let items: [MediaItem]
        switch source {
        case .favorites:
            items = try library.favoriteImages(limit: limit)
        case .library:
            items = try library.recentImages(limit: limit)
        case .album(let id, _):
            let ids = try collections.albumItems(albumId: id).map(\.fileId)
            let map = try await library.fetchItems(ids)
            items = ids.compactMap { map[$0] }
        case .memories:
            items = try await memoryItems(library: library, now: now, calendar: calendar)
        }
        return Array(items.filter(isEligible).prefix(limit))
    }

    /// On this day when the day has photos; otherwise the newest memory there is.
    static func memoryItems(library: LibraryStore, now: Date, calendar: Calendar) async throws -> [MediaItem] {
        let today = try library.onThisDayItems(now: now, calendar: calendar, limit: limit)
        if today.contains(where: isEligible) { return today }
        let memories = try await library.memories(now: now, calendar: calendar)
        guard let memory = memories.recap ?? memories.trips.first else { return [] }
        let ids = Array(memory.items.prefix(limit))
        let map = try await library.fetchItems(ids)
        return ids.compactMap { map[$0] }
    }

    /// A line about the photo: its place, else the day it was taken.
    public static func caption(_ item: MediaItem) -> String {
        if let place = item.place, !place.isEmpty { return place }
        return item.timestamp.formatted(date: .abbreviated, time: .omitted)
    }
}

extension LibraryStore {
    /// The newest still images of the library (for the "Library" source of ambient photos).
    public func recentImages(limit: Int) throws -> [MediaItem] {
        try database.writer.read { db in
            try MediaItem.fetchAll(
                db,
                sql: """
                    SELECT * FROM media WHERE isLivePhotoVideo = 0 AND isArchived = 0 AND kind = 'image'
                    ORDER BY timestamp DESC LIMIT ?
                    """,
                arguments: [limit])
        }
    }
}
