// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import AppIntents
import Foundation
import PhotosCore
import PhotosDomain

/// Places that Siri, Shortcuts and Spotlight can open (SPEC §7.23).
enum PhotosDestination: String, AppEnum {
    case library, favorites, onThisDay, memories, map, albums, people, places, search, backup

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Nextcloud Photos view"
    static let caseDisplayRepresentations: [PhotosDestination: DisplayRepresentation] = [
        .library: "Library", .favorites: "Favorites", .onThisDay: "On this day", .memories: "Memories", .map: "Map", .albums: "Albums",
        .people: "People", .places: "Places", .search: "Search", .backup: "Backup",
    ]
}

struct OpenPhotosViewIntent: AppIntent {
    static let title: LocalizedStringResource = "Open in Nextcloud Photos"
    static let description = IntentDescription("Opens a view of Nextcloud Photos, such as On this day or the map.")
    static let openAppWhenRun = true

    @Parameter(title: "View") var destination: PhotosDestination

    init() {}

    init(destination: PhotosDestination) {
        self.destination = destination
    }

    @MainActor func perform() async throws -> some IntentResult {
        AppHost.model.requestedDestination = destination.rawValue
        return .result()
    }
}

struct BackUpNowIntent: AppIntent {
    static let title: LocalizedStringResource = "Back up photos to Nextcloud"
    static let description = IntentDescription("Uploads new photos of this device to your Nextcloud.")

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        // The backup belongs to the app, not to the account on screen; it says itself how the pass ended. The app may have
        // been launched in the background just for this: the model does not depend on a window (`AppHost`).
        let backup = AppHost.model.backup
        guard backup.settings.isEnabled else {
            return .result(dialog: "Backup is not turned on in Nextcloud Photos.")
        }
        // With access to selected photos only, the answer says so.
        let outcome = await backup.runNow()
        let message = outcome.message(limitedAccess: backup.hasLimitedAccess)
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

// MARK: - Albums and people (SPEC §7.23)

/// An album of the account shown, for Shortcuts and Siri. Its id is the album's link with the account
/// (`DeepLink.url(for:)`), so a shortcut keeps opening the album of the account it was made with.
struct AlbumEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Album"
    static let defaultQuery = AlbumQuery()

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", image: .init(systemName: "rectangle.stack"))
    }
}

/// A named person of the account shown (Recognize), for Shortcuts and Siri. People hidden on this device are not offered.
struct PersonEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Person"
    static let defaultQuery = PersonQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: "person.crop.circle"))
    }
}

/// The albums and people Shortcuts and Siri may offer: what Spotlight has (nothing hidden, nothing while app lock is on).
enum IntentCollections {
    @MainActor static func entries(_ kind: SpotlightEntry.Kind) async -> [(id: String, title: String)] {
        guard let session = AppHost.model.session else { return [] }
        let account = session.account
        return await session.intentEntries().filter { $0.kind == kind }.compactMap { entry in
            entry.link.url(for: account).map { (id: $0.absoluteString, title: entry.title) }
        }
    }

    /// Entities for stored ids. An id the account shown doesn't know (another account's album, a renamed one) still
    /// resolves, with the name from its link: opening it asks to switch accounts or says that it is gone.
    @MainActor static func resolve(_ identifiers: [String], kind: SpotlightEntry.Kind) async -> [(id: String, title: String)] {
        let known = Dictionary(await entries(kind).map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        return identifiers.compactMap { id in
            if let title = known[id] { return (id, title) }
            guard let url = URL(string: id), url.scheme == DeepLink.scheme, let name = url.pathComponents.last else { return nil }
            return (id, name)
        }
    }

    static func matching(_ entries: [(id: String, title: String)], _ text: String) -> [(id: String, title: String)] {
        entries.filter { $0.title.localizedStandardContains(text) }
    }
}

struct AlbumQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [AlbumEntity] {
        await IntentCollections.resolve(identifiers, kind: .album).map { AlbumEntity(id: $0.id, title: $0.title) }
    }

    func entities(matching string: String) async throws -> [AlbumEntity] {
        IntentCollections.matching(await IntentCollections.entries(.album), string).map { AlbumEntity(id: $0.id, title: $0.title) }
    }

    func suggestedEntities() async throws -> [AlbumEntity] {
        await IntentCollections.entries(.album).map { AlbumEntity(id: $0.id, title: $0.title) }
    }
}

struct PersonQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [PersonEntity] {
        await IntentCollections.resolve(identifiers, kind: .person).map { PersonEntity(id: $0.id, name: $0.title) }
    }

    func entities(matching string: String) async throws -> [PersonEntity] {
        IntentCollections.matching(await IntentCollections.entries(.person), string).map { PersonEntity(id: $0.id, name: $0.title) }
    }

    func suggestedEntities() async throws -> [PersonEntity] {
        await IntentCollections.entries(.person).map { PersonEntity(id: $0.id, name: $0.title) }
    }
}

struct OpenAlbumIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open album"
    static let description = IntentDescription("Shows an album in Nextcloud Photos.")

    @Parameter(title: "Album") var target: AlbumEntity

    init() {}

    @MainActor func perform() async throws -> some IntentResult {
        // A link with its account: another account's album asks before it switches (`AppModel.open`).
        if let url = URL(string: target.id) { AppHost.model.open(url) }
        return .result()
    }
}

struct OpenPersonIntent: OpenIntent {
    static let title: LocalizedStringResource = "Show photos of a person"
    static let description = IntentDescription("Shows the photos of a person in Nextcloud Photos.")

    @Parameter(title: "Person") var target: PersonEntity

    init() {}

    @MainActor func perform() async throws -> some IntentResult {
        if let url = URL(string: target.id) { AppHost.model.open(url) }
        return .result()
    }
}

/// "Search photos for …": opens the search with the text (SPEC §7.23).
struct SearchPhotosIntent: ShowInAppSearchResultsIntent {
    static let title: LocalizedStringResource = "Search photos"
    static let description = IntentDescription("Searches your photos in Nextcloud Photos for places, people, dates and more.")
    static let searchScopes: [StringSearchScope] = [.general]

    @Parameter(title: "Search for") var criteria: StringSearchCriteria

    init() {}

    @MainActor func perform() async throws -> some IntentResult {
        AppHost.model.requestSearch(criteria.term)
        return .result()
    }
}

struct PhotosShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SearchPhotosIntent(), phrases: ["Search photos in \(.applicationName)", "Search \(.applicationName)"],
            shortTitle: "Search photos", systemImageName: "magnifyingglass")
        AppShortcut(
            intent: OpenAlbumIntent(),
            phrases: ["Open \(\.$target) in \(.applicationName)", "Show the album \(\.$target) in \(.applicationName)"],
            shortTitle: "Open album", systemImageName: "rectangle.stack")
        AppShortcut(
            intent: OpenPersonIntent(), phrases: ["Show photos of \(\.$target) in \(.applicationName)"],
            shortTitle: "Photos of a person", systemImageName: "person.crop.circle")
        AppShortcut(
            intent: OpenPhotosViewIntent(destination: .onThisDay),
            phrases: ["On this day in \(.applicationName)", "Show my memories in \(.applicationName)"],
            shortTitle: "On this day", systemImageName: "calendar")
        AppShortcut(
            intent: OpenPhotosViewIntent(destination: .map), phrases: ["Show the photo map in \(.applicationName)"],
            shortTitle: "Photo map",
            systemImageName: "map")
        AppShortcut(
            intent: BackUpNowIntent(), phrases: ["Back up my photos with \(.applicationName)"], shortTitle: "Back up now",
            systemImageName: "icloud.and.arrow.up")
        // SPEC §16.4: the other organising actions are in Shortcuts without a phrase of their own (`OrganizeIntents`).
        AppShortcut(
            intent: CreateAlbumFromSearchIntent(), phrases: ["Make an album from a search in \(.applicationName)"],
            shortTitle: "Album from search", systemImageName: "rectangle.stack.badge.plus")
    }
}
