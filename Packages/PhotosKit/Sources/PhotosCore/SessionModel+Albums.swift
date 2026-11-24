// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel
import PhotosNetworking
import PhotosStore

/// Album and sharing actions (SPEC §7.5, §7.6).
extension SessionModel {
    var extendedAlbums: Bool {
        features.has(.albumCover) || features.has(.albumDescription) || features.has(.albumComments) || features.has(.albumLastModified)
    }

    /// Refreshes the album lists when older than `maxAge` (album listing is expensive on the server).
    public func refreshAlbums(maxAge: TimeInterval = 600, force: Bool = false) async throws {
        guard let services else { return }
        if !force, let last = albumsRefreshedAt, Date().timeIntervalSince(last) < maxAge { return }
        try await services.sync.refreshAlbums()
        albumsRefreshedAt = Date()
    }

    public func refreshAlbumContent(_ album: Album, force: Bool = false) async throws {
        guard let services else { return }
        if !force, let fetched = try? services.collections.albumContentFetchedAt(albumId: album.id), Date().timeIntervalSince(fetched) < 120
        {
            return
        }
        if album.kind == .publicLink { return }
        try await services.sync.refreshAlbumContent(album)
    }

    @discardableResult
    public func createAlbum(name: String, location: String = "", description: String = "") async throws -> Album {
        guard let services else { throw NetworkError.unauthorized }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try await services.api.createAlbum(
            name: trimmed, location: location, description: features.has(.albumDescription) ? description : nil)
        let album = Album(kind: .own, name: trimmed, location: location, albumDescription: description)
        try services.collections.upsertAlbum(album)
        try? await refreshAlbums(force: true)
        return (try? services.collections.album(id: album.id)) ?? album
    }

    public func renameAlbum(_ album: Album, to newName: String) async throws {
        guard let services else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != album.name else { return }
        try await services.api.renameAlbum(album, to: trimmed)
        try services.collections.deleteAlbum(id: album.id)
        try await refreshAlbums(force: true)
    }

    /// Deletes an own album or leaves a shared one (which also removes the photos the user added).
    public func deleteAlbum(_ album: Album) async throws {
        guard let services else { return }
        try await services.api.deleteAlbum(album)
        try services.collections.deleteAlbum(id: album.id)
    }

    public func updateAlbum(
        _ album: Album, location: String? = nil, description: String? = nil, cover: FileID? = nil, filters: AlbumFilters? = nil
    )
        async throws
    {
        guard let services else { return }
        try await services.api.updateAlbum(
            album, location: location, description: features.has(.albumDescription) ? description : nil,
            cover: features.has(.albumCover) ? cover : nil, filters: filters)
        if let updated = try await services.api.album(album, extended: extendedAlbums) { try services.collections.upsertAlbum(updated) }
        if filters != nil { try await refreshAlbumContent(album, force: true) }
    }

    public func setCollaborators(_ collaborators: [Collaborator], of album: Album) async throws -> Album {
        guard let services else { throw NetworkError.unauthorized }
        let updated = try await services.api.setCollaborators(collaborators, of: album, extended: extendedAlbums) ?? album
        try services.collections.upsertAlbum(updated)
        return updated
    }

    /// Removes photos from an album; undoable with `undoManager`, the one of the window it is done in
    /// (`SessionModel+Undo.swift`).
    public func removeFromAlbum(_ items: [MediaItem], album: Album, undoManager: UndoManager?) async {
        guard let services, let infos = try? services.collections.albumItems(albumId: album.id) else { return }
        let byFile = Dictionary(infos.map { ($0.fileId, $0) }, uniquingKeysWith: { a, _ in a })
        let members: [UndoableChange.AlbumMember] = items.compactMap { item in
            guard let info = byFile[item.fileId], info.isRemovable else { return nil }
            return UndoableChange.AlbumMember(
                fileId: item.fileId, childName: info.childName, ownPath: info.ownerPath ?? (item.isOwnStorage ? item.path : nil))
        }
        await perform(.removeFromAlbum(members, album: album), undoManager: undoManager)
    }

    public func addToAlbum(_ items: [MediaItem], album: Album) async {
        await add(items, to: album)
    }

    /// Creates a public link album from a selection and returns the link (SPEC SH-4).
    public func quickShare(_ items: [MediaItem]) async throws -> URL {
        guard let services else { throw NetworkError.unauthorized }
        let own = items.filter(\.isOwnStorage)
        guard !own.isEmpty else {
            throw NetworkError.forbidden(message: String(localized: "Only your own photos can be shared by link.", bundle: .module))
        }
        let names = Set(((try? services.collections.albums(.own)) ?? []).map(\.name))
        let title = String(localized: "Shared on \(Date().formatted(date: .abbreviated, time: .omitted))", bundle: .module)
        let album = try await services.api.quickShare(
            userPaths: own.map(\.path), existingAlbumNames: names, title: title, extended: extendedAlbums)
        try services.collections.upsertAlbum(album)
        guard let token = album.publicLink?.id else { throw NetworkError.invalidResponse("no link token") }
        return services.api.publicAlbumLink(token: token)
    }

    public func publicLink(of album: Album) -> URL? {
        guard let token = album.publicLink?.id, !token.isEmpty, let services else { return nil }
        return services.api.publicAlbumLink(token: token)
    }
}
