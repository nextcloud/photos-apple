// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import AppIntents
import Foundation
import PhotosCore
import PhotosDomain
import PhotosModel

// Shortcuts actions for organising (SPEC §16.4): find photos, make an album from a search, add to an album, rate, flag,
// favourite, archive, export, share as a link, show a photo or a memory. With `PhotoEntity` the actions chain in
// Shortcuts and personal automations ("every Sunday: find photos rated ★★★★★ from this week → add to album Best of").
// The work is done by `SessionModel+Intents` (PhotosCore); these types only describe the actions.

enum OrganizeIntentError: Error, CustomLocalizedStringResourceConvertible {
    case signedOut
    case albumNotFound
    case nothingFound

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .signedOut: "Sign in to Nextcloud Photos first."
        case .albumNotFound: "The album was not found in the account shown in Nextcloud Photos."
        case .nothingFound: "No photos were found."
        }
    }
}

@MainActor enum IntentSession {
    static func current() throws -> SessionModel {
        guard let session = AppHost.model.session, !session.isSignedOut else { throw OrganizeIntentError.signedOut }
        return session
    }

    /// The link that identifies a photo of the account shown (`nextcloudphotos://user@host/photo/<id>`).
    static func photoId(_ fileId: FileID, session: SessionModel) -> String {
        DeepLink.photo(fileId: fileId).url(for: session.account)?.absoluteString ?? "photo/\(fileId)"
    }

    /// The file ids of entity ids that belong to the account shown.
    static func fileIds(_ ids: [String], session: SessionModel) -> [FileID] {
        let prefix = DeepLink.photo(fileId: 0).url(for: session.account)?.absoluteString.dropLast(1) ?? "photo/"
        return ids.compactMap { id in
            guard id.hasPrefix(prefix) else { return nil }
            return FileID(id.dropFirst(prefix.count))
        }
    }

    static func entities(_ items: [MediaItem], session: SessionModel) -> [PhotoEntity] {
        items.map { PhotoEntity(id: photoId($0.fileId, session: session), name: $0.name, date: $0.timestamp) }
    }

    static func items(_ entities: [PhotoEntity], session: SessionModel) -> [MediaItem] {
        session.intentPhotos(fileIds(entities.map(\.id), session: session))
    }

    /// The album an `AlbumEntity` stands for in the account shown.
    static func album(_ entity: AlbumEntity, session: SessionModel) -> Album? {
        guard let services = session.services else { return nil }
        let albums = ((try? services.collections.albums(.own)) ?? []) + ((try? services.collections.albums(.shared)) ?? [])
        return albums.first { DeepLink.album(id: $0.id).url(for: session.account)?.absoluteString == entity.id }
    }
}

// MARK: - Entities

/// A photo or video of the account shown.
struct PhotoEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Photo"
    static let defaultQuery = PhotoQuery()

    let id: String
    let name: String
    let date: Date

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)", subtitle: "\(date.formatted(date: .abbreviated, time: .shortened))", image: .init(systemName: "photo"))
    }
}

struct PhotoQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [PhotoEntity] {
        let session = try IntentSession.current()
        let items = session.intentPhotos(IntentSession.fileIds(identifiers, session: session))
        return IntentSession.entities(items, session: session)
    }

    @MainActor func entities(matching string: String) async throws -> [PhotoEntity] {
        let session = try IntentSession.current()
        return IntentSession.entities(try await session.intentFindPhotos(text: string, limit: 50), session: session)
    }

    @MainActor func suggestedEntities() async throws -> [PhotoEntity] {
        let session = try IntentSession.current()
        return IntentSession.entities(try await session.intentFindPhotos(limit: 20), session: session)
    }
}

/// A memory the library offers now (on this day, trips, the year's recap).
struct MemoryEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Memory"
    static let defaultQuery = MemoryQuery()

    let id: String
    let title: String
    let isOnThisDay: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", image: .init(systemName: "sparkles.rectangle.stack"))
    }
}

struct MemoryQuery: EntityQuery {
    @MainActor static func all() async -> [(MemoryEntity, Memory)] {
        guard let session = try? IntentSession.current() else { return [] }
        return await session.intentMemories().map { memory in
            let onThisDay: Bool = if case .yearsAgo = memory.kind { true } else { false }
            return (MemoryEntity(id: memory.id, title: memory.title, isOnThisDay: onThisDay), memory)
        }
    }

    @MainActor func entities(for identifiers: [String]) async throws -> [MemoryEntity] {
        await Self.all().map(\.0).filter { identifiers.contains($0.id) }
    }

    @MainActor func suggestedEntities() async throws -> [MemoryEntity] {
        await Self.all().map(\.0)
    }
}

enum PhotoFlagEnum: String, AppEnum {
    case pick, reject, none

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Flag"
    static let caseDisplayRepresentations: [PhotoFlagEnum: DisplayRepresentation] = [
        .pick: "Pick", .reject: "Reject", .none: "No flag",
    ]

    var flag: CullingFlag {
        switch self {
        case .pick: .pick
        case .reject: .reject
        case .none: .none
        }
    }
}

enum PhotoKindEnum: String, AppEnum {
    case any, photo, video, livePhoto, screenshot

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Media type"
    static let caseDisplayRepresentations: [PhotoKindEnum: DisplayRepresentation] = [
        .any: "Photos and videos", .photo: "Photos", .video: "Videos", .livePhoto: "Live Photos", .screenshot: "Screenshots",
    ]

    var mediaType: SmartMediaType? {
        switch self {
        case .any: nil
        case .photo: .photo
        case .video: .video
        case .livePhoto: .livePhoto
        case .screenshot: .screenshot
        }
    }
}

// MARK: - Find and create

struct FindPhotosIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Photos"
    static let description = IntentDescription(
        "Finds photos and videos in Nextcloud Photos by words (people, places, tags, names, years), person, album, date and favorites.")

    @Parameter(title: "Search for") var text: String?
    @Parameter(title: "Person") var person: PersonEntity?
    @Parameter(title: "Album") var album: AlbumEntity?
    @Parameter(title: "Favorites only", default: false) var favoritesOnly: Bool
    @Parameter(title: "Type", default: .any) var kind: PhotoKindEnum
    @Parameter(title: "Taken after") var from: Date?
    @Parameter(title: "Taken before") var to: Date?
    @Parameter(title: "Limit", default: 50, inclusiveRange: (1, 2000)) var limit: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Find photos matching \(\.$text)") {
            \.$person
            \.$album
            \.$favoritesOnly
            \.$kind
            \.$from
            \.$to
            \.$limit
        }
    }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<[PhotoEntity]> {
        let session = try IntentSession.current()
        let albumTitle: String? = album.flatMap { IntentSession.album($0, session: session)?.title ?? $0.title }
        let items = try await session.intentFindPhotos(
            text: text, person: person?.name, album: albumTitle, favoritesOnly: favoritesOnly, mediaType: kind.mediaType, from: from,
            to: to, limit: limit)
        return .result(value: IntentSession.entities(items, session: session))
    }
}

struct CreateAlbumFromSearchIntent: AppIntent {
    static let title: LocalizedStringResource = "Create Album from Search"
    static let description = IntentDescription("Makes a new album in Nextcloud Photos with the photos a search finds.")

    @Parameter(title: "Album name") var name: String
    @Parameter(title: "Search for") var search: String

    static var parameterSummary: some ParameterSummary {
        Summary("Create album \(\.$name) from photos matching \(\.$search)")
    }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<AlbumEntity> & ProvidesDialog {
        let session = try IntentSession.current()
        let result = try await session.intentCreateAlbum(named: name, search: search)
        let id = DeepLink.album(id: result.album.id).url(for: session.account)?.absoluteString ?? result.album.id
        let dialog = IntentDialog("Added \(result.added) photos to “\(result.album.title)”.")
        return .result(value: AlbumEntity(id: id, title: result.album.title), dialog: dialog)
    }
}

// MARK: - Change photos

struct AddPhotosToAlbumIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Photos to Album"
    static let description = IntentDescription("Adds photos to an album in Nextcloud Photos. Only your own photos can be added.")

    @Parameter(title: "Photos") var photos: [PhotoEntity]
    @Parameter(title: "Album") var album: AlbumEntity

    static var parameterSummary: some ParameterSummary { Summary("Add \(\.$photos) to \(\.$album)") }

    @MainActor func perform() async throws -> some IntentResult {
        let session = try IntentSession.current()
        guard let target = IntentSession.album(album, session: session) else { throw OrganizeIntentError.albumNotFound }
        await session.add(IntentSession.items(photos, session: session), to: target)
        return .result()
    }
}

struct RatePhotosIntent: AppIntent {
    static let title: LocalizedStringResource = "Rate Photos"
    static let description = IntentDescription("Gives photos a star rating (0 removes it), shared with your other devices.")

    @Parameter(title: "Photos") var photos: [PhotoEntity]
    @Parameter(title: "Stars", default: 5, inclusiveRange: (0, 5)) var stars: Int

    static var parameterSummary: some ParameterSummary { Summary("Rate \(\.$photos) with \(\.$stars) stars") }

    @MainActor func perform() async throws -> some IntentResult {
        let session = try IntentSession.current()
        _ = try await session.applyCulling(.rate(stars), to: IntentSession.items(photos, session: session))
        return .result()
    }
}

struct FlagPhotosIntent: AppIntent {
    static let title: LocalizedStringResource = "Flag Photos"
    static let description = IntentDescription("Marks photos as picked or rejected, or removes the flag.")

    @Parameter(title: "Photos") var photos: [PhotoEntity]
    @Parameter(title: "Flag", default: .pick) var flag: PhotoFlagEnum

    static var parameterSummary: some ParameterSummary { Summary("Flag \(\.$photos) as \(\.$flag)") }

    @MainActor func perform() async throws -> some IntentResult {
        let session = try IntentSession.current()
        _ = try await session.applyCulling(.flag(flag.flag), to: IntentSession.items(photos, session: session))
        return .result()
    }
}

struct FavoritePhotosIntent: AppIntent {
    static let title: LocalizedStringResource = "Favorite Photos"
    static let description = IntentDescription("Adds photos to your favorites, or removes them.")

    @Parameter(title: "Photos") var photos: [PhotoEntity]
    @Parameter(title: "Favorite", default: true) var favorite: Bool

    static var parameterSummary: some ParameterSummary {
        When(\.$favorite, .equalTo, true) {
            Summary("Add \(\.$photos) to favorites") { \.$favorite }
        } otherwise: {
            Summary("Remove \(\.$photos) from favorites") { \.$favorite }
        }
    }

    @MainActor func perform() async throws -> some IntentResult {
        let session = try IntentSession.current()
        await session.intentSetFavorite(IntentSession.items(photos, session: session), favorite)
        return .result()
    }
}

struct ArchivePhotosIntent: AppIntent {
    static let title: LocalizedStringResource = "Archive Photos"
    static let description = IntentDescription("Moves your own photos to the archive, out of the library.")

    @Parameter(title: "Photos") var photos: [PhotoEntity]

    static var parameterSummary: some ParameterSummary { Summary("Archive \(\.$photos)") }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let session = try IntentSession.current()
        let count = await session.intentArchive(IntentSession.items(photos, session: session))
        return .result(dialog: IntentDialog("Archived \(count) items."))
    }
}

struct ExportPhotosIntent: AppIntent {
    static let title: LocalizedStringResource = "Export Photos"
    static let description = IntentDescription("Downloads the originals, to pass them on to other actions (Save to Files, Share…).")

    @Parameter(title: "Photos") var photos: [PhotoEntity]

    static var parameterSummary: some ParameterSummary { Summary("Export \(\.$photos)") }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let session = try IntentSession.current()
        let items = IntentSession.items(photos, session: session)
        guard !items.isEmpty else { throw OrganizeIntentError.nothingFound }
        let urls = try await session.intentExport(items)
        return .result(value: urls.map { IntentFile(fileURL: $0, filename: $0.lastPathComponent) })
    }
}

struct SharePhotosLinkIntent: AppIntent {
    static let title: LocalizedStringResource = "Share Photos as Link"
    static let description = IntentDescription("Puts your own photos into a new album with a public link and returns the link.")

    @Parameter(title: "Photos") var photos: [PhotoEntity]
    @Parameter(title: "Album name") var name: String?

    static var parameterSummary: some ParameterSummary { Summary("Share \(\.$photos) as a link") { \.$name } }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<URL> {
        let session = try IntentSession.current()
        let url = try await session.quickShare(IntentSession.items(photos, session: session), title: name)
        return .result(value: url)
    }
}

// MARK: - Show

struct ShowPhotoIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Photo"
    static let description = IntentDescription("Opens a photo in Nextcloud Photos.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Photo") var photo: PhotoEntity

    @MainActor func perform() async throws -> some IntentResult {
        if let url = URL(string: photo.id) { _ = AppHost.model.open(url) }
        return .result()
    }
}

struct ShowMemoryIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Memories"
    static let description = IntentDescription("Opens your memories in Nextcloud Photos (On this day for a memory of this day).")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Memory") var memory: MemoryEntity?

    @MainActor func perform() async throws -> some IntentResult {
        AppHost.model.requestedDestination = memory?.isOnThisDay == true ? "onThisDay" : "memories"
        return .result()
    }
}

struct GetMemoryPhotosIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Photos of Memory"
    static let description = IntentDescription("Returns the photos of a memory, for example to make a slideshow or wallpaper.")

    @Parameter(title: "Memory") var memory: MemoryEntity

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<[PhotoEntity]> {
        let session = try IntentSession.current()
        guard let found = await MemoryQuery.all().first(where: { $0.0.id == memory.id })?.1 else { throw OrganizeIntentError.nothingFound }
        return .result(value: IntentSession.entities(session.intentPhotos(found.items), session: session))
    }
}
