// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import AppIntents
import PhotosCore

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
        AppIntentRouter.app?.requestedDestination = destination.rawValue
        return .result()
    }
}

struct BackUpNowIntent: AppIntent {
    static let title: LocalizedStringResource = "Back up photos to Nextcloud"
    static let description = IntentDescription("Uploads new photos of this device to your Nextcloud.")

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        // The backup belongs to the app, not to the account on screen; it says itself how the pass ended.
        guard let backup = AppIntentRouter.app?.backup, backup.settings.isEnabled else {
            return .result(dialog: "Backup is not turned on in Nextcloud Photos.")
        }
        let message = await backup.runNow().message
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

struct PhotosShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
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
    }
}

/// The running app model for intents.
@MainActor enum AppIntentRouter {
    static var app: AppModel?
}
