// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import OSLog
import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosStore
import TVServices

/// What the TV's home screen shows, read from the account's store after each sync (SPEC §15.3). The sync itself is the
/// session's, the same as on the other platforms.
@MainActor
@Observable
final class TVLibrary {
    let session: SessionModel
    private(set) var memories: [Memory] = []
    private(set) var albums: [Album] = []
    private(set) var sharedAlbums: [Album] = []
    private(set) var favorites: [MediaItem] = []
    private(set) var recent: [MediaItem] = []
    private(set) var hasLoaded = false
    @ObservationIgnored private let logger = Logger(subsystem: "com.nextcloud.photos", category: "tv")

    /// Shelves show this many photos; the grid behind "Show All" has the rest.
    static let shelfLimit = 30

    init(session: SessionModel) {
        self.session = session
    }

    /// Reads the shelves again; also refreshes the albums from the server when they are older than a few minutes and the
    /// Top Shelf's memories.
    func load() async {
        guard let services = session.services else { return }
        let library = services.library
        if let snapshot = try? await library.memories() {
            memories = TVShelves.memories(onThisDay: snapshot.onThisDay, recap: snapshot.recap, trips: snapshot.trips)
        }
        favorites = await items(.favorites, limit: Self.shelfLimit)
        recent = await items(.all, limit: Self.shelfLimit)
        readAlbums()
        hasLoaded = true
        if await CompanionExport.exportTopShelf(memories, services: services) {
            TVTopShelfContentProvider.topShelfContentDidChange()
        }
        do {
            try await session.refreshAlbums()
            readAlbums()
        } catch {
            logger.error("tv: albums not refreshed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func readAlbums() {
        guard let collections = session.services?.collections else { return }
        let newest: (Album, Album) -> Bool = { lhs, rhs in
            (lhs.dateEnd ?? lhs.lastModified ?? .distantPast) > (rhs.dateEnd ?? rhs.lastModified ?? .distantPast)
        }
        albums = ((try? collections.albums(.own)) ?? []).filter { $0.itemCount > 0 }.sorted(by: newest)
        sharedAlbums = ((try? collections.albums(.shared)) ?? []).filter { $0.itemCount > 0 }.sorted(by: newest)
    }

    /// Full items of a filter, newest first.
    func items(_ filter: MediaFilter, limit: Int? = nil) async -> [MediaItem] {
        guard let services = session.services else { return [] }
        let rows = (try? await services.library.fetchGridItems(filter, excludedFolders: session.excludedFolders)) ?? []
        let ids = limit.map { Array(rows.prefix($0)) } ?? rows
        return await media(ids.map(\.fileId))
    }

    /// Full items of these ids, in this order.
    func media(_ ids: [FileID]) async -> [MediaItem] {
        guard let services = session.services, !ids.isEmpty else { return [] }
        let byId = (try? await services.library.fetchItems(ids)) ?? [:]
        return ids.compactMap { byId[$0] }.filter { !$0.isLivePhotoVideo }
    }

    /// The photos and videos of an album, fetched from the server when they were never or not recently loaded.
    func media(of album: Album) async -> [MediaItem] {
        guard let services = session.services else { return [] }
        let local = (try? await services.collections.albumMedia(albumId: album.id)) ?? []
        let fetchedAt = try? services.collections.albumContentFetchedAt(albumId: album.id)
        if local.isEmpty || fetchedAt == nil || Date().timeIntervalSince(fetchedAt ?? .distantPast) > 600 {
            try? await session.refreshAlbumContent(album)
            return (try? await services.collections.albumMedia(albumId: album.id)) ?? local
        }
        return local
    }

    func album(id: String) -> Album? {
        (albums + sharedAlbums).first { $0.id == id } ?? (try? session.services?.collections.album(id: id)) ?? nil
    }
}
