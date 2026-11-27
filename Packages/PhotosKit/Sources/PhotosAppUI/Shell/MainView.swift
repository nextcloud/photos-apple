// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosMedia
import PhotosModel
import PhotosStore
import SwiftUI
import UniformTypeIdentifiers

/// Places of the app (SPEC §6.2). Mirrors the web app's navigation; `SidebarLayout` groups them.
public enum AppDestination: String, Hashable, CaseIterable, Identifiable, Sendable {
    case library, photos, videos, favorites, onThisDay, memories, map
    case albums, sharedAlbums, smartAlbums, people, places, tags
    case folders, sharedWithYou, archive, recentlyDeleted, duplicates, freeSpace
    /// One screen to get space back: duplicates, similar shots, large videos, free space (SPEC §19.3).
    case cleanUp
    case search, backup, settings
    /// The sticker book (SPEC §15.8.2).
    case stickers
    /// Photographer's statistics: cameras, lenses, exposure, keepers (SPEC §16.5.1).
    case insights
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
        case .cleanUp:
            LocalizedStringResource(
                "Clean up", bundle: .module, comment: "Sidebar: duplicates, similar shots, large videos and free space in one screen.")
        case .search: LocalizedStringResource("Search", bundle: .module)
        case .backup: LocalizedStringResource("Backup", bundle: .module)
        case .settings: LocalizedStringResource("Settings", bundle: .module)
        case .collections: LocalizedStringResource("Collections", bundle: .module)
        case .stickers: LocalizedStringResource("Stickers", bundle: .module, comment: "The sticker book in the sidebar.")
        case .insights:
            LocalizedStringResource(
                "Insights", bundle: .module, comment: "Sidebar: statistics of the photographer's cameras, lenses and settings.")
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
        case .cleanUp: "sparkles"
        case .search: "magnifyingglass"
        case .backup: "icloud.and.arrow.up"
        case .settings: "gearshape"
        case .collections: "square.stack"
        case .stickers: "face.smiling"
        case .insights: "chart.bar.xaxis"
        }
    }

    /// Server feature needed to show this place, if any. Places needs none: without the server's places it is the map,
    /// which is made from the photos' GPS data (SPEC §19.1).
    var requiredFeature: ServerFeature? {
        switch self {
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
        case .recentlyDeleted, .duplicates, .freeSpace, .cleanUp, .stickers, .insights: nil
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
    /// The Library's filter and the mode of Places that Photos, Videos and Map ask for (SPEC §19.1).
    @State private var request = DestinationRequest()
    @State private var restored = false
    /// Selected destination and open album of this window (`NavigationSnapshot`), restored with the scene. Owned by `RootView`,
    /// which drops it when its account is removed.
    @Binding var storedNavigation: String
    @State private var lock = AppLock.shared
    #if !os(macOS)
        /// The sidebar's rows as the user arranged them (iPad, Vision Pro), on this device for every window. A new key for
        /// the slimmer sidebar of SPEC §19.1: the arrangement of the earlier rows does not apply to it.
        @AppStorage("sidebarTabCustomization") private var customization: TabViewCustomization
        @Environment(\.horizontalSizeClass) private var sizeClass
        /// Where the user is inside the Collections tab while another tab is shown.
        @State private var collectionsPlace: AppDestination = .collections
        /// Settings, from the account button (SPEC §19.2).
        @State private var showingSettings = false
    #endif
    #if os(iOS)
        @State private var linkedPhoto: ViewerStart?
        /// The uploads list, opened from the tab bar's accessory (SPEC §17.3).
        @State private var showingTransfers = false
    #endif
    #if os(macOS)
        @AppStorage("sidebarUtilitiesExpanded") private var utilitiesExpanded = false
        @AppStorage("sidebarAlbumsExpanded") private var albumsExpanded = true
        /// Pinned, hidden and reordered rows (SPEC §19.1), on this device.
        @AppStorage(SidebarCustomization.storageKey) private var sidebarStored = ""
        /// The albums listed under Albums, for the highlight.
        @State private var sidebarAlbumIds: [String] = []
        @State private var editingSidebar = false
        @FocusState private var searchFocused: Bool
    #endif
    /// Settings › Advanced › "Advanced features": niche places have no row while it is off (SPEC §20.4).
    @AppStorage(AdvancedFeatures.storageKey) private var advancedFeatures = AdvancedFeatures.defaultValue
    @State private var searchText = ""
    @State private var searchFilters: [SearchFilter] = []
    /// Return in this window's search field (see `SearchScreen.submissions`).
    @State private var searchSubmissions = 0
    @State private var creatingAlbum = false
    @State private var importingFiles = false
    @State private var openingLink = false
    /// A link led to a screen this server cannot fill (`unavailableLinkAlert`).
    @State private var unavailableLink: AppDestination?
    /// File › Import Library… (SPEC §15.7).
    @State private var importingLibrary = false
    /// File › Import from Camera or Card… (SPEC §15.2).
    @State private var importingCard = false
    /// Edit ▸ Undo History… (SPEC §16.3.4).
    @State private var showingUndoHistory = false
    /// "Show in library": the photo the Library timeline scrolls to and highlights.
    @State private var timelineReveal = TimelineRevealCenter()
    /// The command palette of this window (SPEC §16.2).
    @State private var palette = CommandPaletteCenter()
    /// The zoom transitions from cards into the screens pushed by value (SPEC §17.4).
    @Namespace private var routeTransitions
    #if os(macOS)
        /// The grid or viewer with the focus, whose selection the palette's commands act on.
    #endif

    /// Debug builds: `PHOTOS_DEBUG_DESTINATION=albums` opens a destination at launch (screenshots, UI tests).
    static var debugDestination: AppDestination? {
        #if DEBUG
            if let raw = ProcessInfo.processInfo.environment["PHOTOS_DEBUG_DESTINATION"] { return AppDestination(rawValue: raw) }
        #endif
        return nil
    }

    /// Debug builds signed in by `PHOTOS_DEBUG_LOGIN` (UI tests) start in the Library instead of the place the last run
    /// left: a tour must not depend on which tour ran before it. `PHOTOS_DEBUG_DESTINATION` still wins.
    static var skipsRestoredNavigation: Bool {
        #if DEBUG
            return ProcessInfo.processInfo.environment["PHOTOS_DEBUG_LOGIN"] != nil
        #else
            return false
        #endif
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

    /// Has a row in the sidebar: offered by the server and, for a niche place, with Advanced features on (SPEC §20.4).
    /// A place without a row still opens (links, Shortcuts, the command palette, the Go menu): `go` asks `visible`.
    func listed(_ destination: AppDestination) -> Bool {
        visible(destination) && AdvancedFeatures.lists(destination, isOn: advancedFeatures)
    }

    var body: some View {
        navigation
            .environment(\.showInFolder, ShowInFolderAction { directory in showFolder(directory) })
            .environment(\.showInTimeline, ShowInTimelineAction { item in showInTimeline(item) })
            .environment(\.timelineReveal, timelineReveal)
            .environment(\.destinationRequest, request)
            .onChange(of: app.requestedDestination, initial: true) { _, _ in
                restoreOnce()
                openRequested()
            }
            .onAppear { LaunchMetrics.shared.reached(.mainView) }
            // A link that came in while the app was locked is opened once it is unlocked.
            .onChange(of: lock.isLocked) { _, _ in openRequested() }
            .onChange(of: selection) { _, _ in remember() }
            .onChange(of: paths) { _, _ in remember() }
            .focusedSceneValue(\.mainActions, mainActions)
            // ⌘K and the toolbar button (SPEC §16.2).
            .commandPaletteHost(palette, actions: mainActions)
            .sheet(isPresented: $creatingAlbum) { AlbumEditor(album: nil) }
            .sheet(isPresented: $openingLink) { OpenPublicLinkSheet() }
            .sheet(isPresented: $importingLibrary) { ImportLibrarySheet() }
            .sheet(isPresented: $importingCard) { CardImportSheet() }
            .undoHistorySheet(isPresented: $showingUndoHistory)
            #if DEBUG
                // Screenshots and UI checks: `PHOTOS_DEBUG_CARD_IMPORT=1` opens the import sheet at launch.
                .task { if ProcessInfo.processInfo.environment["PHOTOS_DEBUG_CARD_IMPORT"] != nil { importingCard = true } }
                    #if os(macOS)
                        // `PHOTOS_DEBUG_EDIT_SIDEBAR=1` opens Edit Sidebar at launch.
                        .task { if ProcessInfo.processInfo.environment["PHOTOS_DEBUG_EDIT_SIDEBAR"] != nil { editingSidebar = true } }
                    #endif
            #endif
            // A link for another account, an unknown account or a public album asks first (not while locked).
            .linkPrompts(isLocked: lock.requiresUnlock)
            .unavailableLinkAlert($unavailableLink)
            .fileImporter(isPresented: $importingFiles, allowedContentTypes: [.image, .movie], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                session.transfers.upload(UploadSources.copies(of: urls))
            }
    }

    /// What the menus, the keyboard and the command palette can do in this window.
    var mainActions: MainActions {
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
            importLibrary: { importingLibrary = true },
            importCard: CardImportAvailability.isAvailable ? { importingCard = true } : nil,
            showUndoHistory: { showingUndoHistory = true },
            openPalette: { grid in palette.open(grid: grid) },
            openLink: { open($0) },
            search: { filters in showSearch(filters) },
            editSidebar: editSidebarAction
        )
    }

    /// The search with these chips (from the command palette).
    func showSearch(_ filters: [SearchFilter]) {
        #if os(macOS)
            searchText = ""
            searchFilters = filters
            selection = .search
        #else
            palette.pendingSearch = filters
            go(.search)
        #endif
    }

    // MARK: State

    func path(_ destination: AppDestination) -> Binding<[AppRoute]> {
        Binding(get: { paths[destination] ?? [] }, set: { paths[destination] = $0.isEmpty ? nil : $0 })
    }

    /// View ▸ Edit Sidebar… (Mac).
    var editSidebarAction: (() -> Void)? {
        #if os(macOS)
            { editingSidebar = true }
        #else
            nil
        #endif
    }

    /// Shows a destination from its root, like choosing it in the sidebar. A destination without a row of its own opens
    /// its row with the filter, mode or screen it stands for (`SidebarLayout.entry`).
    func go(_ destination: AppDestination) {
        guard visible(destination) else { return }
        let entry = SidebarLayout.entry(for: destination, visible: visible)
        guard visible(entry.destination) else { return }
        show(entry)
    }

    func show(_ entry: SidebarLayout.Entry) {
        request.apply(entry)
        paths[entry.destination] = entry.routes.isEmpty ? nil : entry.routes
        selection = entry.destination
        #if os(macOS)
            revealRow(of: entry.destination)
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
            revealRow(of: .folders)
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
        if let screen = AppDestination.unavailableScreen(of: link, has: session.features.has) {
            unavailableLink = screen
            return
        }
        switch link {
        case .destination(let raw):
            if let destination = AppDestination(rawValue: raw) { go(destination) }
        case .album(let id):
            let destination: AppDestination = id.hasPrefix("\(AlbumKind.shared.rawValue):") ? .sharedAlbums : .albums
            guard visible(destination) else { return }
            selection = destination
            paths[destination] = [.album(id: id)]
            #if os(macOS)
                revealRow(of: destination)
            #endif
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
        case .place(let name):
            // A place's photos come from the server's places; without them Places is only the map.
            guard session.features.has(.places) else { return }
            show(.place(name: name), in: .places)
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
        #if os(macOS)
            revealRow(of: destination)
        #endif
    }

    func restoreOnce() {
        guard !restored else { return }
        restored = true
        if ImportLibrarySheet.debugExport != nil { importingLibrary = true }
        if let destination = Self.debugDestination {
            // Before the server's features are known.
            show(SidebarLayout.entry(for: destination, visible: { _ in true }))
        } else if !Self.skipsRestoredNavigation, let snapshot = NavigationSnapshot(stored: storedNavigation),
            snapshot.belongs(to: session.account.id.rawValue),
            let destination = AppDestination(rawValue: snapshot.destination),
            visible(destination)
        {
            // A window of an earlier version may have shown a place that is now a filter or a mode of a row.
            go(destination)
            if !snapshot.routes.isEmpty { paths[selection] = snapshot.routes }
        }
        #if !os(macOS)
            // Settings was a tab before it became a sheet (SPEC §19.2): a window left on it opens in the Library.
            if selection == .settings { selection = .library }
        #endif
        #if os(macOS)
            if selection == .backup || selection == .settings { selection = .library }
            revealRow(of: selection)
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
        .environment(\.routeTransitionNamespace, routeTransitions)
    }

    // MARK: Layout

    #if os(macOS)
        /// Sidebar and content. A split view and not `TabView(.sidebarAdaptable)`: the sidebar needs a width, a collapsible
        /// section that remembers its state, and the window toolbar a search field.
        var navigation: some View {
            NavigationSplitView {
                sidebar
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
            // No command palette button in the toolbar: Go ▸ Quick Actions… and ⌘K open it (SPEC §19.2).
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

        /// The slim sidebar (SPEC §19.1): the pinned rows, the albums with the top albums listed, Utilities (collapsed),
        /// and the account at the bottom.
        var sidebar: some View {
            List(selection: sidebarSelection) {
                Section {
                    ForEach(customization.wrappedValue.shownPinned(visible: listed)) { row in
                        sidebarRow(row)
                    }
                    .onMove { source, destination in movePinned(source, to: destination) }
                }
                let albumRows: [AppDestination] = customization.wrappedValue.shownAlbumRows(visible: visible)
                if !albumRows.isEmpty {
                    Section(isExpanded: $albumsExpanded) {
                        if albumRows.contains(.albums) {
                            SidebarAlbumRows(listed: $sidebarAlbumIds, account: session.account.id.rawValue)
                        }
                        ForEach(albumRows.filter { $0 != .albums }) { row in
                            sidebarRow(row)
                        }
                    } header: {
                        Text("Albums", bundle: .module)
                    }
                }
                let utilities: [AppDestination] = customization.wrappedValue.shownUtilities(visible: listed)
                if !utilities.isEmpty {
                    Section(isExpanded: $utilitiesExpanded) {
                        ForEach(utilities) { row in
                            sidebarRow(row)
                        }
                    } header: {
                        Text("Utilities", bundle: .module)
                    }
                }
            }
            .listStyle(.sidebar)
            // One menu for the list (a `contextMenu` on each row's label dropped the rows' icons in the sidebar).
            .contextMenu(forSelectionType: SidebarItem.self) { items in
                if let item = items.first { rowMenu(item) }
            }
            // Compact, at the bottom, like the account of Mail or Music: switch account, Settings (SPEC §19.1).
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    SidebarAccountButton()
                }
            }
            .sheet(isPresented: $editingSidebar) {
                EditSidebarSheet(customization: customization, visible: listed)
            }
        }

        var customization: Binding<SidebarCustomization> {
            Binding(
                get: { SidebarCustomization(stored: sidebarStored) },
                set: { value in sidebarStored = value.isStandard ? "" : value.stored })
        }

        func movePinned(_ source: IndexSet, to destination: Int) {
            let current = customization.wrappedValue
            var shown = current.shownPinned(visible: listed)
            shown.move(fromOffsets: source, toOffset: destination)
            // Hidden rows and rows the server does not offer keep their place after the shown ones.
            let rest = current.pinned.filter { !shown.contains($0) }
            customization.wrappedValue = SidebarCustomization(pinned: shown + rest, hidden: current.hidden)
        }

        func sidebarRow(_ row: AppDestination) -> some View {
            Label(String(localized: row.rowTitle), systemImage: row.systemImage)
                .tag(SidebarItem.destination(row))
        }

        @ViewBuilder func rowMenu(_ item: SidebarItem) -> some View {
            switch item {
            case .destination(let row): rowMenu(row)
            case .album(let id): SidebarAlbumMenu(albumId: id, account: session.account.id.rawValue)
            }
        }

        /// Pin, unpin, hide; and Edit Sidebar… for everything else.
        @ViewBuilder func rowMenu(_ row: AppDestination) -> some View {
            let value = customization.wrappedValue
            if value.canUnpin(row) {
                Button(SidebarWording.unpin) { customization.wrappedValue.unpin(row) }
            } else if value.canPin(row) {
                Button(SidebarWording.pin) { customization.wrappedValue.pin(row) }
            }
            // "Shared with you" stands for the Shared row where the server has no shared albums.
            let hiddenRow: AppDestination = row == .sharedWithYou ? .sharedAlbums : row
            if value.canHide(hiddenRow) {
                Button(SidebarWording.hide) { customization.wrappedValue.setHidden(hiddenRow, true) }
            }
            Divider()
            Button(SidebarWording.editTitle) { editingSidebar = true }
            if !value.isStandard {
                Button(SidebarWording.restore) { customization.wrappedValue = .standard }
            }
        }

        /// The highlighted row: an album listed under Albums while it is open, else the row of the destination.
        var sidebarSelection: Binding<SidebarItem?> {
            Binding(
                get: {
                    if selection == .albums, case .album(let id) = paths[.albums]?.first, sidebarAlbumIds.contains(id) {
                        return .album(id)
                    }
                    return SidebarLayout.row(for: selection, visible: visible).map(SidebarItem.destination)
                },
                set: { item in
                    switch item {
                    case .destination(let destination): go(destination)
                    case .album(let id):
                        selection = .albums
                        paths[.albums] = [.album(id: id)]
                    case nil: break
                    }
                })
        }

        /// Opens the collapsed group that holds `destination`'s row, so the highlight can be seen.
        func revealRow(of destination: AppDestination) {
            guard let row = SidebarLayout.row(for: destination, visible: visible) else { return }
            if customization.wrappedValue.utilities.contains(row) { utilitiesExpanded = true }
            if SidebarLayout.albums.contains(row) || row == .sharedWithYou { albumsExpanded = true }
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
                // The slim sidebar (SPEC §19.1); the user hides and reorders its rows with the sidebar's Edit
                // (`TabViewCustomization`), and "Restore Default Sidebar" in the account header's menu undoes that.
                if !usesCollectionsTab {
                    TabSection {
                        ForEach(SidebarLayout.pinnedByDefault.filter { $0 != .library && sidebarTab($0) }) { destination in
                            tab(destination)
                        }
                    } header: {
                        Text("Browse", bundle: .module)
                    }
                    .customizationID("section.browse")
                    .defaultVisibility(.hidden, for: .tabBar)

                    TabSection {
                        // Under the "Albums" header, as on the Mac: All Albums, Shared.
                        ForEach(SidebarLayout.albumRows(visible: visible)) { destination in
                            tab(destination, title: destination == .albums ? SidebarWording.allAlbums : nil)
                        }
                    } header: {
                        Text("Albums", bundle: .module)
                    }
                    .customizationID("section.albums")
                    .defaultVisibility(.hidden, for: .tabBar)

                    TabSection {
                        ForEach(SidebarLayout.utilities.filter(sidebarTab) + [.backup]) { destination in
                            tab(destination)
                        }
                    } header: {
                        Text("Utilities", bundle: .module)
                    }
                    .customizationID("section.utilities")
                    .defaultVisibility(.hidden, for: .tabBar)
                }

                // No Settings tab: the account button in the Library's and Collections' top bars opens Settings as a
                // sheet (SPEC §19.2).
            }
            .tabViewStyle(.sidebarAdaptable)
            .tabViewCustomization($customization)
            // The models are handed over explicitly: when the sidebar first appears during a rotation (portrait → landscape),
            // UIKit sizes the header before SwiftUI has given it the environment, and the app crashed ("No Observable object
            // of type AppModel found").
            // The account pinned to the bottom of the sidebar, as on the Mac (and in Mail or Music); a footer would follow
            // the rows and sit high up in a short sidebar (Vision Pro).
            .tabViewSidebarBottomBar {
                SidebarAccountFooter(restoreSidebar: { customization = TabViewCustomization() }).environment(app).environment(session)
            }
            .onChange(of: selection, initial: true) { _, destination in
                if CompactNavigation.isInCollectionsTab(destination) { collectionsPlace = destination }
            }
            .onChange(of: usesCollectionsTab, initial: true) { _, uses in
                // The Collections list only exists as a tab; with a sidebar its rows are there.
                if !uses, selection == .collections { selection = .library }
            }
            // Settings is a sheet, not a place: a link or the command palette that asks for it shows the sheet over the
            // screen the user is on (SPEC §19.2).
            .onChange(of: selection, initial: true) { old, destination in
                guard destination == .settings else { return }
                selection = old == .settings ? .library : old
                showingSettings = true
            }
            .environment(\.showSettings, ShowSettingsAction { showingSettings = true })
            .sheet(isPresented: $showingSettings) { SettingsSheet() }
            #if os(iOS)
                .mediaViewer($linkedPhoto)
                // iPhone: the tab bar steps back while the content scrolls down, and the accessory above it shows what
                // uploads, backs up or imports (SPEC §17.3).
                .tabBarMinimizeBehavior(.onScrollDown)
                .activityAccessory(isAvailable: usesCollectionsTab) { kind in openActivity(kind) }
                .sheet(isPresented: $showingTransfers) { TransfersList() }
            #endif
        }

        /// A tab of the iPad's sidebar: a place with a row, or a niche one while it is shown (opened by a link), so the
        /// tab view has a tab to select (SPEC §20.4).
        func sidebarTab(_ destination: AppDestination) -> Bool {
            listed(destination) || (selection == destination && visible(destination))
        }

        #if os(iOS)
            /// A tap on the tab bar's accessory: the screen of what it shows.
            func openActivity(_ kind: ChromeActivity.Kind) {
                switch kind {
                case .upload: showingTransfers = true
                case .backup: go(.backup)
                case .libraryImport: importingLibrary = true
                case .cardImport: importingCard = true
                }
            }
        #endif

        func tab(_ destination: AppDestination, title: String? = nil) -> some TabContent<AppDestination> {
            Tab(value: destination) {
                stack(destination)
            } label: {
                Label(title ?? String(localized: destination.rowTitle), systemImage: destination.systemImage)
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
                        // A tap on the tab that is already shown goes back to its overview.
                        paths[selection] = nil
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
                    // An album or person opened from a shelf of the overview is on the overview's own path (SPEC §20.4).
                    paths[place.destination] = place.routes.isEmpty ? nil : place.routes
                    if shown { selection = place.destination } else { collectionsPlace = place.destination }
                })
        }

        var collectionsStack: some View {
            NavigationStack(path: collectionsPath) {
                CollectionsList()
                    .navigationDestination(for: AppRoute.self) { route in RouteView(route: route) }
            }
            .environment(\.routeTransitionNamespace, routeTransitions)
        }
    #endif
}

/// A screen opened by value: from a link in a list, a deep link or scene restoration.
struct RouteView: View {
    let route: AppRoute
    @Environment(\.routeTransitionNamespace) private var transitions
    /// The search field's text and chips a destination pushed by value is given (only the Mac's search screen uses
    /// them). Real bindings, never `.constant`: SwiftUI counts a constant binding as changed at every update, so the
    /// screen was rebuilt each time its navigation host handed the environment down again, and a grid rebuilt that way
    /// laid out the stack again, which handed the environment down again — a loop at full CPU (STATUS §20.1).
    @State private var searchText = ""
    @State private var searchFilters: [SearchFilter] = []

    var body: some View {
        // An album zooms out of its card (SPEC §17.4). Only routes that cards open: a list row has no card to zoom from.
        screen.cardTransitionDestination(id: route, in: route.opensFromCard ? transitions : nil)
    }

    @ViewBuilder var screen: some View {
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
                DestinationView(destination: destination, searchText: $searchText, searchFilters: $searchFilters)
            }
        }
    }
}

extension AppRoute {
    /// Opened from a card (an album's cover), so it zooms out of that card.
    var opensFromCard: Bool {
        if case .album = self { return true }
        return false
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
    /// The filter or mode Photos, Videos and Map asked for (SPEC §19.1).
    @Environment(\.destinationRequest) private var request

    var body: some View {
        switch destination {
        // Photos and Videos are filters of the Library; `MainView.go` opens them there. Kept for links pushed by value.
        case .library, .photos, .videos:
            TimelineScreen(initialKind: destination == .library ? request.libraryKind : destination == .photos ? .photos : .videos)
                .id(request.librarySerial)
        case .favorites: TimelineScreen(filter: .favorites)
        case .settings: SettingsView()
        case .albums: AlbumsScreen(kind: .own)
        case .backup: BackupScreen()
        case .onThisDay: MemoriesScreen(onlyOnThisDay: true)
        case .memories: MemoriesScreen()
        // The map is a mode of Places.
        case .map: PlacesHome(initialMode: .map)
        case .people: PeopleScreen()
        case .places: PlacesHome(initialMode: request.placesMode).id(request.placesSerial)
        case .tags: TagsScreen()
        case .folders: FoldersScreen()
        case .sharedWithYou: FoldersScreen(sharedWithYou: true)
        case .smartAlbums: SmartAlbumsLibraryScreen()
        case .archive: ArchiveScreen()
        case .search:
            #if os(macOS)
                SearchScreen(query: $searchText, filters: $searchFilters, submissions: searchSubmissions)
            #else
                SearchTab()
            #endif
        case .recentlyDeleted: RecentlyDeletedScreen()
        // Both live in Clean up now (SPEC §19.3); their links and commands open it at their section.
        case .duplicates, .freeSpace: CleanUpScreen(initialSection: CleanUpSection.opened(by: destination))
        // The sidebar's row; Duplicates and Free up space requests come here with their section (SPEC §19.1).
        case .cleanUp:
            CleanUpScreen(initialSection: request.cleanUpSource.flatMap { CleanUpSection.opened(by: $0) })
                .id(request.cleanUpSerial)
        case .sharedAlbums: AlbumsScreen(kind: .shared)
        case .stickers: StickerBookScreen()
        case .insights: InsightsScreen()
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

extension EnvironmentValues {
    /// What Photos, Videos and Map asked the Library and Places to show (`MainView`).
    @Entry var destinationRequest = DestinationRequest()
}

/// The account at the bottom of the sidebar (iPad, Vision Pro), like the Mac's `SidebarAccountButton`: the account's
/// initials, name and server; its menu switches or adds an account and restores the default sidebar.
struct SidebarAccountFooter: View {
    /// "Restore Default Sidebar": the header's menu is the sidebar's (iPad, Vision Pro).
    var restoreSidebar: (() -> Void)? = nil
    @Environment(SessionModel.self) private var session
    @State private var addingAccount = false

    var body: some View {
        Menu {
            AccountSwitchItems(addingAccount: $addingAccount)
            if let restoreSidebar {
                Divider()
                Button(SidebarWording.restore, systemImage: "arrow.counterclockwise") { restoreSidebar() }
            }
        } label: {
            HStack(spacing: 13) {
                AccountBadge(name: session.account.displayName, size: 24)
                VStack(alignment: .leading, spacing: 0) {
                    Text(session.account.displayName).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(session.account.hostDisplayName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(.rect)
            // One control, not one per logo and line of text.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                Text("Account \(session.account.displayName) on \(session.account.hostDisplayName)", bundle: .module))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        // In line with the sidebar's rows: the badge under their icons, name and server under their titles, the chevron
        // under the sections' chevrons.
        .padding(.leading, 38)
        .padding(.trailing, 22)
        .padding(.vertical, 10)
        .accessibilityHint(Text("Switch or add an account", bundle: .module))
        .sheet(isPresented: $addingAccount) { AddAccountSheet() }
    }
}
