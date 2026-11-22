// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosModel
import PhotosStore
import SwiftUI

/// Places of the app (SPEC §6.2). Mirrors the web app's navigation incl. the "Advanced" group.
public enum AppDestination: String, Hashable, CaseIterable, Identifiable, Sendable {
    case library, photos, videos, favorites, onThisDay, memories, map
    case albums, sharedAlbums, smartAlbums, people, places, tags
    case folders, sharedWithYou, archive, recentlyDeleted, duplicates, freeSpace
    case search, backup, settings

    public var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .library: LocalizedStringResource("All media", bundle: .module)
        case .photos: LocalizedStringResource("Photos", bundle: .module)
        case .videos: LocalizedStringResource("Videos", bundle: .module)
        case .favorites: LocalizedStringResource("Favorites", bundle: .module)
        case .onThisDay: LocalizedStringResource("On this day", bundle: .module)
        case .memories: LocalizedStringResource("Memories", bundle: .module)
        case .map: LocalizedStringResource("Map", bundle: .module)
        case .albums: LocalizedStringResource("Albums", bundle: .module)
        case .sharedAlbums: LocalizedStringResource("Shared albums", bundle: .module)
        case .smartAlbums: LocalizedStringResource("Smart albums", bundle: .module)
        case .people: LocalizedStringResource("People", bundle: .module)
        case .places: LocalizedStringResource("Places", bundle: .module)
        case .tags: LocalizedStringResource("Tags", bundle: .module)
        case .folders: LocalizedStringResource("Folders", bundle: .module)
        case .sharedWithYou: LocalizedStringResource("Shared with you", bundle: .module)
        case .archive: LocalizedStringResource("Archive", bundle: .module)
        case .recentlyDeleted: LocalizedStringResource("Recently deleted", bundle: .module)
        case .duplicates: LocalizedStringResource("Duplicates", bundle: .module)
        case .freeSpace: LocalizedStringResource("Free up space", bundle: .module)
        case .search: LocalizedStringResource("Search", bundle: .module)
        case .backup: LocalizedStringResource("Backup", bundle: .module)
        case .settings: LocalizedStringResource("Settings", bundle: .module)
        }
    }

    var systemImage: String {
        switch self {
        case .library: "photo.on.rectangle"
        case .photos: "photo"
        case .videos: "video"
        case .favorites: "heart"
        case .onThisDay: "calendar"
        case .memories: "sparkles.rectangle.stack"
        case .map: "map"
        case .albums: "rectangle.stack"
        case .sharedAlbums: "rectangle.stack.badge.person.crop"
        case .smartAlbums: "line.3.horizontal.decrease.circle"
        case .people: "person.2"
        case .places: "mappin.and.ellipse"
        case .tags: "tag"
        case .folders: "folder"
        case .sharedWithYou: "person.2.badge.plus"
        case .archive: "archivebox"
        case .recentlyDeleted: "trash"
        case .duplicates: "square.on.square"
        case .freeSpace: "externaldrive.badge.minus"
        case .search: "magnifyingglass"
        case .backup: "icloud.and.arrow.up"
        case .settings: "gearshape"
        }
    }

    /// Server feature needed to show this place, if any.
    var requiredFeature: ServerFeature? {
        switch self {
        case .places: .places
        case .people: .recognize
        case .tags: .systemtags
        case .recentlyDeleted: .trashbin
        case .albums, .sharedAlbums: .photosDAV
        default: nil
        }
    }

    /// Milestone that delivers the screen (placeholders until then).
    var milestone: String? {
        switch self {
        case .library, .photos, .videos, .favorites, .settings: nil
        case .albums, .sharedAlbums: "M2"
        case .backup: "M3"
        case .onThisDay, .memories, .map, .people, .places, .tags, .folders, .sharedWithYou, .smartAlbums, .archive, .search: "M4"
        case .recentlyDeleted, .duplicates, .freeSpace: "M5"
        }
    }
}

/// Main navigation: tab bar on iPhone, sidebar on iPad, Mac and Vision Pro (`sidebarAdaptable`).
struct MainView: View {
    @Environment(SessionModel.self) private var session
    @State private var selection: AppDestination = .library
    @SceneStorage("tabCustomization") private var customization: TabViewCustomization

    func visible(_ destination: AppDestination) -> Bool {
        guard let feature = destination.requiredFeature else { return true }
        return session.features.has(feature)
    }

    var body: some View {
        TabView(selection: $selection) {
            Tab(value: AppDestination.library) {
                NavigationStack { TimelineScreen(filter: .all) }
            } label: {
                Label(String(localized: "Library", bundle: .module), systemImage: "photo.on.rectangle")
            }
            .customizationID(AppDestination.library.rawValue)

            Tab(value: AppDestination.search, role: .search) {
                NavigationStack { DestinationView(destination: .search) }
            } label: {
                Label(String(localized: AppDestination.search.title), systemImage: AppDestination.search.systemImage)
            }

            TabSection {
                ForEach([AppDestination.photos, .videos, .favorites, .onThisDay, .memories, .map]) { destination in
                    tab(destination)
                }
            } header: {
                Text("Library", bundle: .module)
            }
            .defaultVisibility(.hidden, for: .tabBar)

            TabSection {
                ForEach([AppDestination.albums, .sharedAlbums, .smartAlbums, .people, .places, .tags].filter(visible)) { destination in
                    tab(destination)
                }
            } header: {
                Text("Collections", bundle: .module)
            }
            .defaultVisibility(.hidden, for: .tabBar)

            TabSection {
                ForEach([AppDestination.folders, .sharedWithYou, .archive, .recentlyDeleted, .duplicates, .freeSpace].filter(visible)) {
                    destination in
                    tab(destination)
                }
            } header: {
                Text("Advanced", bundle: .module)
            }
            .defaultVisibility(.hidden, for: .tabBar)

            Tab(value: AppDestination.backup) {
                NavigationStack { DestinationView(destination: .backup) }
            } label: {
                Label(String(localized: AppDestination.backup.title), systemImage: AppDestination.backup.systemImage)
            }
            .defaultVisibility(.hidden, for: .tabBar)

            #if !os(macOS)
                Tab(value: AppDestination.settings) {
                    NavigationStack { SettingsView() }
                } label: {
                    Label(String(localized: AppDestination.settings.title), systemImage: AppDestination.settings.systemImage)
                }
            #endif
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabViewCustomization($customization)
        .tabViewSidebarHeader { AccountHeader() }
    }

    func tab(_ destination: AppDestination) -> some TabContent<AppDestination> {
        Tab(value: destination) {
            NavigationStack { DestinationView(destination: destination) }
        } label: {
            Label(String(localized: destination.title), systemImage: destination.systemImage)
        }
        .customizationID(destination.rawValue)
    }
}

/// Content of a navigation destination.
struct DestinationView: View {
    let destination: AppDestination

    var body: some View {
        switch destination {
        case .library: TimelineScreen(filter: .all)
        case .photos: TimelineScreen(filter: .photos)
        case .videos: TimelineScreen(filter: .videos)
        case .favorites: TimelineScreen(filter: .favorites)
        case .settings: SettingsView()
        default: MilestonePlaceholder(destination: destination)
        }
    }
}

/// Placeholder for screens of later milestones.
struct MilestonePlaceholder: View {
    let destination: AppDestination

    var body: some View {
        ContentUnavailableView {
            Label(String(localized: destination.title), systemImage: destination.systemImage)
        } description: {
            Text("This part of Nextcloud Photos is not available yet.", bundle: .module)
        }
        .navigationTitle(String(localized: destination.title))
    }
}

/// Account name and server in the sidebar header, with the account switcher.
struct AccountHeader: View {
    @Environment(AppModel.self) private var app
    @Environment(SessionModel.self) private var session
    @State private var addingAccount = false

    var body: some View {
        Menu {
            ForEach(app.accounts) { account in
                Button {
                    app.switchTo(account.id)
                } label: {
                    if account.id == session.account.id {
                        Label("\(account.displayName) – \(account.hostDisplayName)", systemImage: "checkmark")
                    } else {
                        Text("\(account.displayName) – \(account.hostDisplayName)")
                    }
                }
            }
            Divider()
            Button(String(localized: "Add account…", bundle: .module)) { addingAccount = true }
        } label: {
            HStack(spacing: 10) {
                NextcloudLogo().frame(width: 36, height: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text(session.account.displayName).font(.headline)
                    Text(session.account.hostDisplayName).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .sheet(isPresented: $addingAccount) {
            NavigationStack {
                LoginView(isAddingAccount: true)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(String(localized: "Cancel", bundle: .module)) { addingAccount = false }
                        }
                    }
            }
            .frame(minWidth: 420, minHeight: 560)
        }
    }
}
