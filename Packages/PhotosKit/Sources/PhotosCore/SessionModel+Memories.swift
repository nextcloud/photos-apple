// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosDomain
import PhotosModel
import PhotosNetworking

/// What "Save as album" did with a memory.
public struct MemoryAlbumResult: Sendable, Equatable {
    public var album: Album
    /// Photos put into the album (through the outbox: they arrive on the server shortly after).
    public var added: Int
    /// Photos left out: they are not the user's own (a shared folder's), and the Photos server only takes own files.
    public var skipped: Int
}

/// Memory actions (SPEC ME-4): save as a Nextcloud album, share by public link. Both make an ordinary own album on the
/// server, so the web app and the other clients see it too.
extension SessionModel {
    /// The memory's photos as stored in the index, in the memory's order; Live Photo videos go with their photo.
    func memoryItems(_ memory: Memory) async throws -> [MediaItem] {
        guard let services else { throw NetworkError.unauthorized }
        let stored = try await services.library.fetchItems(memory.items)
        return memory.items.compactMap { stored[$0] }.filter { !$0.isLivePhotoVideo }
    }

    /// Creates an own album named after the memory (`Memories.albumName`) and adds the user's own photos of it. A trip's
    /// places become the album's location.
    public func saveAsAlbum(_ memory: Memory) async throws -> MemoryAlbumResult {
        guard let services else { throw NetworkError.unauthorized }
        let items = try await memoryItems(memory)
        let own = items.filter(\.isOwnStorage)
        guard !own.isEmpty else {
            throw NetworkError.forbidden(message: String(localized: "Only your own photos can be added to an album.", bundle: .module))
        }
        let names = Set(((try? services.collections.albums(.own)) ?? []).map(\.name))
        let name = Memories.albumName(for: memory, existing: names)
        let location = memory.kind == .trip ? memory.title : ""
        let album = try await createAlbum(name: name, location: location)
        await addToAlbum(own, album: album)
        return MemoryAlbumResult(album: album, added: own.count, skipped: items.count - own.count)
    }

    /// A public link to the memory's photos: a new album with a public link (SPEC SH-4), named after the memory.
    public func shareLink(for memory: Memory) async throws -> URL {
        try await quickShare(try await memoryItems(memory), title: Memories.albumName(for: memory, existing: []))
    }
}
