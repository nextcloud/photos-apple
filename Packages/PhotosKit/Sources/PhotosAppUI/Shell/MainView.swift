// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosStore
import SwiftUI
import UniformTypeIdentifiers

/// Places of the app (SPEC §6.2). Mirrors the web app's navigation; `SidebarLayout` groups them.
public enum AppDestination: String, Hashable, CaseIterable, Identifiable, Sendable {
    case library, photos, videos, favorites, onThisDay, memories, map
    case albums, sharedAlbums, smartAlbums, people, places, tags
    case folders, sharedWithYou, archive, recentlyDeleted, duplicates, freeSpace
    case search, backup, settings
    /// The tab that lists the places without a tab of their own (iPhone, narrow iPad windows; SPEC §6.2).
    case collections

    public var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .library: LocalizedStringResource("Library", bundle: .module)
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
        case .freeSpace: LocalizedStringResource("Free up server space", bundle: .module)
        case .search: LocalizedStringResource("Search", bundle: .module)
        case .backup: LocalizedStringResource("Backup", bundle: .module)
        case .settings: LocalizedStringResource("Settings", bundle: .module)
        case .collections: LocalizedStringResource("Collections", bundle: .module)
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
        case .sharedWithYou: "folder.badge.person.crop"
        case .archive: "archivebox"
        case .recentlyDeleted: "trash"
        case .duplicates: "square.on.square"
        case .freeSpace: "externaldrive.badge.minus"
        case .search: "magnifyingglass"
        case .backup: "icloud.and.arrow.up"
        case .settings: "gearshape"
        case .collections: "square.stack"
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
        case .library, .photos, .videos, .favorites, .settings, .albums, .sharedAlbums, .backup, .collections: nil
        case .onThisDay, .memories, .map, .people, .places, .tags, .folders, .sharedWithYou, .smartAlbums, .archive, .search: nil
        case .recentlyDeleted, .duplicates, .freeSpace: nil
        }
    }
}

/// How the destinations are grouped in the sidebar (SPEC §6.2). "On this day" is the first section of Memories and has no
/// row of its own; it stays a destination for notifications, widgets and links.
enum SidebarLayout {
    static let primary: [AppDestination] = [.library, .photos, .videos, .favorites, .memories, .map]
    static let collections: [AppDestination] = [.albums, .sharedAlbums, .smartAlbums, .people, .places, .tags, .sharedWithYou]
    static let utilities: [AppDestination] = [.folders, .archive, .recentlyDeleted, .duplicates, .freeSpace]

    /// The row that is highlighted while `destination` is shown.
    static func row(for destination: AppDestination) -> AppDestination? {
        switch destination {
        case .onThisDay: .memories
        case .search, .settings, .collections: nil
        #if os(macOS)
            // On the Mac, backup is a tab of the Settings window.
            case .backup: nil
        #endif
        default: destination
        }
    }
}

/// Main navigation: tab bar on iPhone, sidebar on iPad, Mac and Vision Pro.
///
/// Every destination has its own navigation path, kept here and not inside the stacks: a stack that is rebuilt when the user
/// comes back to a destination starts from this state, so links keep working (they did not after leaving a screen with an
/// open album), and the selected destination and open album can be restored with the scene and set by deep links.
struct MainView: View {
    @Environment(SessionModel.self) private var session
    @Environment(AppModel.self) private var app
    @State private var selection: AppDestination = .library
    @State private var paths: [AppDestination: [AppRoute]] = [:]
    @State private var restored = false
    /// Selected destination and open album of this window (`NavigationSnapshot`), restored with the scene. Owned by `RootView`,
    /// which drops it when its account is removed.
    @Binding var storedNavigation: String
    @State private var lock = AppLock.shared
    #if !os(macOS)
        @SceneStorage("tabCustomization") private var customization: TabViewCustomization
        @Environment(\.horizontalSizeClass) private var sizeClass
        /// Where the user is inside the Collections tab while another tab is shown.
        @State private var collectionsPlace: AppDestination = .collections
    #endif
    #if os(iOS)
        @State private var linkedPhoto: ViewerStart?
    #endif
    #if os(macOS)
        @AppStorage("sidebarUtilitiesExpanded") private var utilitiesExpanded = false
        @FocusState private var searchFocused: Bool
    #endif
    @State private var searchText = ""
    @State private var searchFilters: [SearchFilter] = []
    /// Return in this window's search field (see `SearchScreen.submissions`).
    @State private var searchSubmissions = 0
    @State private var creatingAlbum = false
    @State private var importingFiles = false
    @State private var openingLink = false
    /// File › Import from Google Takeout… (Mac).
    @State private var importingTakeout = false
    /// File › Import from Camera or Card… (SPEC §15.2).
    @State private var importingCard = false
    /// "Show in library": the photo the Library timeline scrolls to and highlights.
    @State private var timelineReveal = TimelineRevealCenter()

    /// Debug builds: `PHOTOS_DEBUG_DESTINATION=albums` opens a destination at launch (screenshots, UI tests).
    static var debugDestination: AppDestination? {
        #if DEBUG
            if let raw = ProcessInfo.processInfo.environment["PHOTOS_DEBUG_DESTINATION"] { return AppDestination(rawValue: raw) }
        #endif
        return nil
    }

    /// There is no sidebar: the tab bar has a Collections tab for the places that are sidebar rows elsewhere.
    var usesCollectionsTab: Bool {
        #if os(iOS)
            CompactNavigation.usesCollectionsTab(isPhone: UIDevice.current.userInterfaceIdiom == .phone, isCompact: sizeClass == .compact)
        #else
            false
        #endif
    }

    func visible(_ destination: AppDestination) -> Bool {
        if destination == .collections { return usesCollectionsTab }
        guard let feature = destination.requiredFeature else { return true }
        return session.features.has(feature)
    }

    var body: some View {
        navigation
            .environment(\.showInFolder, ShowInFolderAction { directory in showFolder(directory) })
            .environment(\.showInTimeline, ShowInTimelineAction { item in showInTimeline(item) })
            .environment(\.timelineReveal, timelineReveal)
            .onChange(of: app.requestedDestination, initial: true) { _, _ in
                restoreOnce()
                openRequested()
            }
            // A link that came in while the app was locked is opened once it is unlocked.
            .onChange(of: lock.isLocked) { _, _ in openRequested() }
            .onChange(of: selection) { _, _ in remember() }
            .onChange(of: paths) { _, _ in remember() }
            .focusedSceneValue(
                \.mainActions,
                MainActions(
                    available: AppDestination.allCases.filter(visible),
                    go: { go($0) },
                    focusSearch: { focusSearch() },
                    newAlbum: {
                        go(.albums)
                        creatingAlbum = true
                    },
                    upload: { importingFiles = true },
                    openPublicLink: { openingLink = true },
                    syncNow: { Task { await session.syncNow(forceReconcile: true) } },
                    importTakeout: { importingTakeout = true },
                    importCard: CardImportAvailability.isAvailable ? { importingCard = true } : nil
                )
            )
            .sheet(isPresented: $creatingAlbum) { AlbumEditor(album: nil) }
            .sheet(isPresented: $openingLink) { OpenPublicLinkSheet() }
            #if os(macOS)
                .sheet(isPresented: $importingTakeout) { TakeoutImportSheet() }
            #endif
            .sheet(isPresented: $importingCard) { CardImportSheet() }
            #if DEBUG
                // Screenshots and UI checks: `PHOTOS_DEBUG_CARD_IMPORT=1` opens the import sheet at launch.
                .task { if ProcessInfo.processInfo.environment["PHOTOS_DEBUG_CARD_IMPORT"] != nil { importingCard = true } }
            #endif
            // A link for another account, an unknown account or a public album asks first (not while locked).
            .linkPrompts(isLocked: lock.requiresUnlock)
            .fileImporter(isPresented: $importingFiles, allowedContentTypes: [.image, .movie], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                session.transfers.upload(UploadSources.copies(of: urls))
            }
    }

    // MARK: State

    func path(_ destination: AppDestination) -> Binding<[AppRoute]> {
        Binding(get: { paths[destination] ?? [] }, set: { paths[destination] = $0.isEmpty ? nil : $0 })
    }

    /// Shows a destination from its root, like choosing it in the sidebar.
    func go(_ destination: AppDestination) {
        guard visible(destination) else { return }
        paths[destination] = nil
        selection = destination
        #if os(macOS)
            if SidebarLayout.utilities.contains(destination) { utilitiesExpanded = true }
        #endif
    }

    /// Opens what was requested from outside (a link, a notification, a widget), unless the app is locked: then it waits.
    func openRequested() {
        guard let raw = app.requestedDestination, !lock.requiresUnlock else { return }
        app.requestedDestination = nil
        if let link = DeepLink(request: raw) { open(link) }
    }

    /// The folder browser at `directory`, with a screen for every folder above it, so Back walks up the tree.
    func showFolder(_ directory: String) {
        guard visible(.folders) else { return }
        let trail: [AppRoute] = FolderTrail.folders(to: directory).map { AppRoute.folder(path: $0) }
        #if os(macOS)
            utilitiesExpanded = true
        #endif
        selection = .folders
        paths[.folders] = trail.isEmpty ? nil : trail
    }

    /// The Library from its root, scrolled to the photo's day with the photo highlighted.
    func showInTimeline(_ item: MediaItem) {
        go(.library)
        timelineReveal.request(item)
    }

    func open(_ link: DeepLink) {
        switch link {
        case .destination(let raw):
            if let destination = AppDestination(rawValue: raw) { go(destination) }
        case .album(let id):
            let destination: AppDestination = id.hasPrefix("\(AlbumKind.shared.rawValue):") ? .sharedAlbums : .albums
            guard visible(destination) else { return }
            selection = destination
            paths[destination] = [.album(id: id)]
        case .photo(let fileId):
            // Only what the library shows: not archived photos (they need the Archive's unlock) or unknown ids.
            guard DeepLink.mayOpen(try? session.services?.library.item(fileId)) else { return }
            #if os(iOS)
                linkedPhoto = ViewerStart(ids: [fileId], startId: fileId)
            #else
                // The viewer is pushed in the window; "Back" returns to where the user was.
                let below: [AppRoute] = (paths[selection] ?? []).filter { if case .photo = $0 { false } else { true } }
                paths[selection] = below + [.photo(fileId: fileId)]
            #endif
        case .place(let name): show(.place(name: name), in: .places)
        case .person(let name): show(.person(name: name), in: .people)
        case .tag(let name): show(.tag(name: name), in: .tags)
        case .folder(let path): showFolder(path)
        case .search(let text):
            #if os(macOS)
                searchText = text
                searchFilters = []
                selection = .search
            #else
                // The search tab owns its field; it takes the text from here.
                app.requestedSearch = text
                go(.search)
            #endif
        }
    }

    /// A collection's screen on top of its list, as if it had been chosen there.
    func show(_ route: AppRoute, in destination: AppDestination) {
        guard visible(destination) else { return }
        selection = destination
        paths[destination] = [route]
    }

    func restoreOnce() {
        guard !restored else { return }
        restored = true
        if let destination = Self.debugDestination {
            selection = destination
        } else if let snapshot = NavigationSnapshot(stored: storedNavigation), snapshot.belongs(to: session.account.id.rawValue),
            let destination = AppDestination(rawValue: snapshot.destination),
            visible(destination)
        {
            selection = destination
            paths[destination] = snapshot.routes.isEmpty ? nil : snapshot.routes
        }
        #if os(macOS)
            if selection == .backup || selection == .settings { selection = .library }
            if SidebarLayout.utilities.contains(selection) { utilitiesExpanded = true }
        #endif
    }

    func remember() {
        storedNavigation =
            NavigationSnapshot(destination: selection.rawValue, routes: paths[selection] ?? [], account: session.account.id.rawValue).stored
    }

    func focusSearch() {
        #if os(macOS)
            searchFocused = true
        #else
            selection = .search
        #endif
    }

    /// A destination's screen in its own stack, bound to its path.
    func stack(_ destination: AppDestination) -> some View {
        NavigationStack(path: path(destination)) {
            DestinationView(
                destination: destination, searchText: $searchText, searchFilters: $searchFilters, searchSubmissions: searchSubmissions
            )
            .navigationDestination(for: AppRoute.self) { route in RouteView(route: route) }
        }
    }

    // MARK: Layout

    #if os(macOS)
        /// Sidebar and content. A split view and not `TabView(.sidebarAdaptable)`: the sidebar needs a width, a collapsible
        /// section that remembers its state, and the window toolbar a search field.
        var navigation: some View {
            NavigationSplitView {
                List(selection: sidebarSelection) {
                    Section {
                        rows(SidebarLayout.primary)
                    }
                    Section {
                        rows(SidebarLayout.collections)
                    } header: {
                        Text("Collections", bundle: .module)
                    }
                    Section(isExpanded: $utilitiesExpanded) {
                        rows(SidebarLayout.utilities)
                    } header: {
                        Text("Utilities", bundle: .module)
                    }
                }
                .listStyle(.sidebar)
                .safeAreaInset(edge: .top, spacing: 0) {
                    AccountHeader().padding(.horizontal, 16).padding(.vertical, 8)
                }
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 320)
            } detail: {
                // A new stack per destination; what is open in it comes from `paths`.
                stack(selection).id(selection)
            }
            // The chosen filters are tokens in the field, as in Finder and Mail.
            .searchable(text: $searchText, tokens: $searchFilters, placement: .toolbar, prompt: Text("Search", bundle: .module)) {
                (filter: SearchFilter) in
                Label(filter.label, systemImage: filter.systemImage)
            }
            .searchFocused($searchFocused)
            .onSubmit(of: .search) {
                showSearch()
                searchSubmissions += 1
            }
            .onChange(of: searchText) { _, text in
                if !text.isEmpty { showSearch() }
            }
            .onChange(of: selection) { _, destination in
                // Leaving the search ends it; the field is empty on the other screens.
                if destination != .search {
                    searchText = ""
                    searchFilters = []
                }
            }
        }

        var sidebarSelection: Binding<AppDestination?> {
            Binding(
                get: { SidebarLayout.row(for: selection) },
                set: { destination in
                    if let destination { go(destination) }
                })
        }

        func rows(_ destinations: [AppDestination]) -> some View {
            ForEach(destinations.filter(visible)) { destination in
                Label(String(localized: destination.title), systemImage: destination.systemImage)
                    .tag(destination)
            }
        }

        func showSearch() {
            if selection != .search { selection = .search }
        }
    #else
        var navigation: some View {
            TabView(selection: tabSelection) {
                Tab(value: AppDestination.library) {
                    stack(.library)
                } label: {
                    Label(String(localized: AppDestination.library.title), systemImage: AppDestination.library.systemImage)
                }
                .customizationID(AppDestination.library.rawValue)

                if usesCollectionsTab {
                    Tab(value: AppDestination.collections) {
                        collectionsStack
                    } label: {
                        Label(String(localized: AppDestination.collections.title), systemImage: AppDestination.collections.systemImage)
                    }
                    .customizationID(AppDestination.collections.rawValue)
                }

                Tab(value: AppDestination.search, role: .search) {
                    stack(.search)
                } label: {
                    Label(String(localized: AppDestination.search.title), systemImage: AppDestination.search.systemImage)
                }

                // The sidebar's rows (iPad at regular width, Vision Pro). They have no place in a tab bar; where
                // there is only a tab bar, the Collections tab lists them instead.
                if !usesCollectionsTab {
                    TabSection {
                        ForEach(SidebarLayout.primary.filter { $0 != .library }) { destination in
                            tab(destination)
                        }
                    } header: {
                        Text("Browse", bundle: .module)
                    }
                    .defaultVisibility(.hidden, for: .tabBar)

                    TabSection {
                        ForEach(SidebarLayout.collections.filter(visible)) { destination in
                            tab(destination)
                        }
                    } header: {
                        Text("Collections", bundle: .module)
                    }
                    .defaultVisibility(.hidden, for: .tabBar)

                    TabSection {
                        ForEach(SidebarLayout.utilities.filter(visible)) { destination in
                            tab(destination)
                        }
                    } header: {
                        Text("Utilities", bundle: .module)
                    }
                    .defaultVisibility(.hidden, for: .tabBar)

                    Tab(value: AppDestination.backup) {
                        stack(.backup)
                    } label: {
                        Label(String(localized: AppDestination.backup.title), systemImage: AppDestination.backup.systemImage)
                    }
                    .defaultVisibility(.hidden, for: .tabBar)
                }

                Tab(value: AppDestination.settings) {
                    stack(.settings)
                } label: {
                    Label(String(localized: AppDestination.settings.title), systemImage: AppDestination.settings.systemImage)
                }
            }
            .tabViewStyle(.sidebarAdaptable)
            .tabViewCustomization($customization)
            .tabViewSidebarHeader { AccountHeader() }
            .onChange(of: selection, initial: true) { _, destination in
                if CompactNavigation.isInCollectionsTab(destination) { collectionsPlace = destination }
            }
            .onChange(of: usesCollectionsTab, initial: true) { _, uses in
                // The Collections list only exists as a tab; with a sidebar its rows are there.
                if !uses, selection == .collections { selection = .library }
            }
            #if os(iOS)
                .mediaViewer($linkedPhoto)
            #endif
        }

        func tab(_ destination: AppDestination) -> some TabContent<AppDestination> {
            Tab(value: destination) {
                stack(destination)
            } label: {
                Label(String(localized: destination.title), systemImage: destination.systemImage)
            }
            .customizationID(destination.rawValue)
        }

        /// The tab that is selected while `selection` is shown: with a Collections tab, every place without a tab of
        /// its own is inside that one.
        var tabSelection: Binding<AppDestination> {
            Binding(
                get: {
                    if usesCollectionsTab { return CompactNavigation.tab(for: selection) }
                    return selection == .collections ? .library : selection
                },
                set: { tab in
                    guard usesCollectionsTab, tab == .collections else {
                        selection = tab
                        return
                    }
                    if CompactNavigation.isInCollectionsTab(selection) {
                        // A tap on the tab that is already shown goes back to its list.
                        if selection != .collections { paths[selection] = nil }
                        selection = .collections
                    } else {
                        // Coming from another tab: back to where the user was.
                        selection = collectionsPlace
                    }
                })
        }

        /// The path of the Collections tab's stack, made from `selection` and `paths` and written back to them — so
        /// deep links, state restoration and a change between tab bar and sidebar (iPad) all keep working with the
        /// one navigation state.
        var collectionsPath: Binding<[AppRoute]> {
            Binding(
                get: {
                    let place: AppDestination = CompactNavigation.isInCollectionsTab(selection) ? selection : collectionsPlace
                    return CompactNavigation.path(to: place, routes: paths[place] ?? [])
                },
                set: { path in
                    guard let place = CompactNavigation.place(of: path) else { return }
                    let shown: Bool = CompactNavigation.isInCollectionsTab(selection)
                    let previous: AppDestination = shown ? selection : collectionsPlace
                    // Back in the list: the place that was left starts from its root next time.
                    if previous != place.destination { paths[previous] = nil }
                    if place.destination != .collections { paths[place.destination] = place.routes.isEmpty ? nil : place.routes }
                    if shown { selection = place.destination } else { collectionsPlace = place.destination }
                })
        }

        var collectionsStack: some View {
            NavigationStack(path: collectionsPath) {
                CollectionsList()
                    .navigationDestination(for: AppRoute.self) { route in RouteView(route: route) }
            }
        }
    #endif
}

/// A screen opened by value: from a link in a list, a deep link or scene restoration.
struct RouteView: View {
    let route: AppRoute

    var body: some View {
        switch route {
        case .album(let id): AlbumRouteScreen(albumId: id)
        case .photo(let fileId): MediaViewer(ids: [fileId], startId: fileId)
        case .folder(let path): FoldersScreen(path: path)
        case .place(let name): PlaceRouteScreen(name: name)
        case .person(let name): PersonRouteScreen(name: name)
        case .tag(let name): TagRouteScreen(name: name)
        case .destination(let raw):
            // Pushed from the Collections list (the search tab has its own stack and field).
            if let destination = AppDestination(rawValue: raw) {
                DestinationView(destination: destination, searchText: .constant(""), searchFilters: .constant([]))
            }
        }
    }
}

/// Content of a navigation destination.
struct DestinationView: View {
    let destination: AppDestination
    /// Text of the window's search field (macOS); the search tab has its own field elsewhere.
    @Binding var searchText: String
    @Binding var searchFilters: [SearchFilter]
    /// Return in the window's search field (macOS).
    var searchSubmissions = 0

    var body: some View {
        switch destination {
        case .library: TimelineScreen(filter: .all)
        case .photos: TimelineScreen(filter: .photos)
        case .videos: TimelineScreen(filter: .videos)
        case .favorites: TimelineScreen(filter: .favorites)
        case .settings: SettingsView()
        case .albums: AlbumsScreen(kind: .own)
        case .backup: BackupScreen()
        case .onThisDay: MemoriesScreen(onlyOnThisDay: true)
        case .memories: MemoriesScreen()
        case .map: MapScreen()
        case .people: PeopleScreen()
        case .places: PlacesScreen()
        case .tags: TagsScreen()
        case .folders: FoldersScreen()
        case .sharedWithYou: FoldersScreen(sharedWithYou: true)
        case .smartAlbums: SmartAlbumsScreen()
        case .archive: ArchiveScreen()
        case .search:
            #if os(macOS)
                SearchScreen(query: $searchText, filters: $searchFilters, submissions: searchSubmissions)
            #else
                SearchTab()
            #endif
        case .recentlyDeleted: RecentlyDeletedScreen()
        case .duplicates: DuplicatesScreen()
        case .freeSpace: FreeSpaceScreen()
        case .sharedAlbums: AlbumsScreen(kind: .shared)
        case .collections:
            #if os(macOS)
                // The Mac has the sidebar; nothing leads here.
                EmptyView()
            #else
                CollectionsList()
            #endif
        }
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
                    // A name and a server: nothing to translate.
                    let title = "\(account.displayName) – \(account.hostDisplayName)"
                    if account.id == session.account.id {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Text(verbatim: title)
                    }
                }
            }
            if app.canAddAccount {
                Divider()
                Button(String(localized: "Add account…", bundle: .module)) { addingAccount = true }
            }
        } label: {
            HStack(spacing: 10) {
                NextcloudLogo().frame(width: 36, height: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text(session.account.displayName).font(.headline)
                    Text(session.account.hostDisplayName).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            // One control, not one per logo and line of text.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                Text("Account \(session.account.displayName) on \(session.account.hostDisplayName)", bundle: .module))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityHint(Text("Switch or add an account", bundle: .module))
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
