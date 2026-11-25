// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosDomain
import PhotosModel
import PhotosNetworking
import PhotosStore

/// What the Shortcuts actions do (SPEC §16.4), for the intents in the app target: they stay thin and this stays testable.
extension SessionModel {
    /// Photos of the index by file id, in the given order (unknown ids are left out).
    public func intentPhotos(_ fileIds: [FileID]) -> [MediaItem] {
        guard let services, !fileIds.isEmpty else { return [] }
        let map = (try? services.library.items(fileIds)) ?? [:]
        return fileIds.compactMap { map[$0] }
    }

    /// Finds photos: all criteria together, newest first, at most `limit`.
    public func intentFindPhotos(
        text: String? = nil, person: String? = nil, album: String? = nil, favoritesOnly: Bool = false, mediaType: SmartMediaType? = nil,
        from: Date? = nil, to: Date? = nil, limit: Int = 50
    ) async throws -> [MediaItem] {
        guard let organize else { return [] }
        var rules: [SmartRule] = []
        if let text, !text.trimmingCharacters(in: .whitespaces).isEmpty { rules.append(IntentSearch.rule(for: text)) }
        if let person { rules.append(.condition(.person(person))) }
        if let album { rules.append(.condition(.album(album))) }
        if favoritesOnly { rules.append(.condition(.favorite)) }
        if let mediaType { rules.append(.condition(.mediaType(mediaType))) }
        if from != nil || to != nil {
            rules.append(.condition(.dateRange(start: from ?? .distantPast, end: to ?? .distantFuture)))
        }
        let definition = SmartAlbumDefinition(name: "", rule: .all(rules), limit: max(1, limit))
        return try await organize.items(of: definition)
    }

    /// Makes an album of the photos a search finds ("Create album from search"). Only the user's own photos can be in an
    /// album; the others are counted as skipped.
    public func intentCreateAlbum(named name: String, search: String, limit: Int = 2000) async throws -> (
        album: Album, added: Int, skipped: Int
    ) {
        let found = try await intentFindPhotos(text: search, limit: limit)
        let album = try await createAlbum(name: name)
        let own = found.filter(\.isOwnStorage)
        await add(own, to: album)
        return (album, own.count, found.count - own.count)
    }

    /// The own or shared album with this id (`Album.id`).
    public func intentAlbum(id: String) -> Album? {
        try? services?.collections.album(id: id)
    }

    /// Favourite or not, through the outbox.
    public func intentSetFavorite(_ items: [MediaItem], _ value: Bool) async {
        await enqueue(items.filter { !$0.isCollectionChild }.map { .favorite(fileId: $0.fileId, path: $0.path, value: value) })
    }

    /// Archives the user's own photos.
    public func intentArchive(_ items: [MediaItem]) async -> Int {
        let own = items.filter { $0.isOwnStorage && !$0.isArchived }
        await enqueue(own.map { .archive(fileId: $0.fileId, path: $0.path) })
        return own.count
    }

    /// Downloads the originals into a temporary folder, for Shortcuts to pass on.
    public func intentExport(_ items: [MediaItem]) async throws -> [URL] {
        guard let services else { throw NetworkError.unauthorized }
        let folder = FileManager.default.temporaryDirectory.appending(path: "Shortcuts/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var files: [URL] = []
        for item in items {
            let original = try await services.images.originals.original(
                fileId: item.fileId, etag: item.etag, url: services.originalURL(for: item))
            let target = folder.appending(path: item.name)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: original, to: target)
            files.append(target)
        }
        return files
    }

    /// The memories the library has now (Shortcuts can list them).
    public func intentMemories() async -> [Memory] {
        guard let services, let snapshot = try? await services.library.memories() else { return [] }
        return snapshot.onThisDay + snapshot.trips + (snapshot.recap.map { [$0] } ?? [])
    }
}
