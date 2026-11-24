// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosStore
import SwiftUI

/// A grid with selection, actions, sync status and viewer (shared by timeline, albums, places…).
struct MediaGridScreen<Accessory: View>: View {
    let feed: GridFeed
    let title: String
    var showsHeaders: Bool
    var emptyTitle: String
    var emptyMessage: String
    /// Zoom step (`GridColumns.options`): the target tile size; the column count follows from the width.
    @Binding var columns: Int
    /// Extra actions offered for selected items (e.g. "Remove from album").
    var extraActions: ([MediaItem]) -> [GridMenuAction] = { _ in [] }
    /// The grid shows the synced library (timeline): "empty" is only said once a first sync has finished.
    var waitsForFirstSync = false
    /// The one helpful action of the empty state (SPEC §6.3), e.g. "Try again" for a list that could not be loaded.
    var emptyAction: GridEmptyAction? = nil
    /// The title stays while items are selected; the screen shows the count itself (`GridSelectionState.Key`).
    var keepsTitleWhileSelecting = false
    /// "Show in library" requests this grid carries out (the Library's grid only).
    var reveal: TimelineRevealCenter? = nil
    /// This is the Library: "Show in library" is not offered for its photos.
    var isLibrary = false
    @ViewBuilder var accessory: () -> Accessory

    @Environment(SessionModel.self) private var session
    /// The window's undo manager: Edit › Undo and ⌘Z on the Mac and iPad, shake on iPhone.
    @Environment(\.undoManager) private var undoManager
    @State private var selection: Set<FileID> = []
    /// What the toolbar and the menus show for the selection, loaded off the main thread when the selection changes.
    @State private var selectionInfo = GridSelectionInfo()
    @State private var isSelecting = false
    @State private var viewerStart: ViewerStart?
    @State private var confirmDelete: DeleteConfirmation?
    @State private var infoItem: MediaItem?
    @State private var showingInfo = false
    @State private var actionError: String?
    @State private var albumPicker: PickedItems?
    @State private var tagEditor: PickedItems?
    @State private var sharedLink: SharedLink?
    @State private var metadataItems: PickedItems?
    @State private var editedItem: MediaItem?
    /// Nextcloud's own sharing of one photo (users, other servers, email, Talk, links with password and expiry).
    @State private var nextcloudShare: SharingTarget?
    /// Nextcloud's own sharing of several photos at once.
    @State private var nextcloudShareMany: PickedItems?
    /// Slideshow of the selection or of the whole grid (SPEC VW-5).
    @State private var slideshow: SlideshowRequest?
    /// The tile "Show in library" opened the grid at, marked for a moment (iPhone, iPad, Vision Pro).
    @State private var highlight: TileHighlight?
    /// Haptic triggers (iPhone, iPad).
    @State private var favoriteToggles = 0
    @State private var deletions = 0
    /// Export… / Save to Photos, with its progress and result.
    @State private var saver = MediaSaveModel()
    /// Image ▸ Rotate and Edit ▸ Copy, with their progress and result.
    @State private var photoTasks = PhotoTaskModel()
    /// Own albums, for the "Add to Album" submenus; the ones used last in this app (`RecentAlbumsStore`) come first.
    @State private var albums: [Album] = []
    @State private var usedAlbums: [String] = []
    /// "Add to Album ▸ New Album…": a new album with these items.
    @State private var newAlbumItems: PickedItems?
    /// The zoom transition into the viewer and back (iPhone, iPad): the tile it starts from and where that tile is.
    @Namespace private var zoomNamespace
    @State private var tileLocator = GridTileLocator()
    @State private var zoomTile: FileID?
    @State private var zoomFrame: CGRect?
    @Environment(\.showInFolder) private var showInFolder
    /// Square tiles or the aspect ratio grid (Settings, View ▸ Square Tiles).
    @AppStorage(TileStyle.squareTilesKey) private var squareTiles = true
    @Environment(\.showInTimeline) private var showInTimeline
    #if os(iOS)
        @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    struct TileHighlight: Equatable {
        let id = UUID()
        var frame: CGRect
    }

    struct PickedItems: Identifiable {
        let id = UUID()
        var items: [MediaItem]
    }

    struct SharedLink: Identifiable {
        var id: URL { url }
        var url: URL
    }

    var body: some View {
        content
            .navigationTitle(isSelecting && !keepsTitleWhileSelecting ? selectionTitle : title)
            .preference(key: GridSelectionState.Key.self, value: GridSelectionState(isSelecting: isSelecting, count: selection.count))
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                // iPhone: the selection's actions take the place of the tab bar, as in Photos (else they are under it).
                .toolbar(isSelecting && sizeClass == .compact ? .hidden : .automatic, for: .tabBar)
            #endif
            .toolbar { toolbar }
            .overlay(alignment: .bottom) { statusBanner }
            .confirmationDialog(
                deleteTitle, isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button(String(localized: "Delete", bundle: .module), role: .destructive) {
                    if let items = confirmDelete?.items {
                        deletions += 1
                        let undoManager = undoManager
                        Task { await session.perform(.delete(items), undoManager: undoManager) }
                    }
                    endSelection()
                }
            } message: {
                Text(deleteMessage)
            }
            .sheet(item: $albumPicker) { picked in AlbumPickerSheet(items: picked.items) }
            .sheet(item: $newAlbumItems) { picked in AlbumEditor(album: nil, items: picked.items) }
            .sheet(item: $tagEditor) { picked in TagEditorSheet(items: picked.items) }
            .sheet(item: $sharedLink) { link in LinkShareSheet(url: link.url) }
            .sheet(item: $metadataItems) { picked in MetadataEditor(items: picked.items) }
            .sheet(item: $editedItem) { item in EditorView(item: item) }
            .sheet(item: $nextcloudShare) { target in
                if let services = session.services { FileSharingSheet(target: target, api: services.api.sharing) }
            }
            .sheet(item: $nextcloudShareMany) { picked in
                if let services = session.services { MultiFileSharingSheet(items: picked.items, api: services.api.sharing) }
            }
            .slideshow($slideshow)
            .task(id: RevealKey(request: reveal?.pending?.id, revision: feed.update.revision)) { await carryOutReveal() }
            .infoInspector(isPresented: $showingInfo) {
                if let item = infoItem ?? selectionInfo.items?.first {
                    InfoPanel(item: item, inInspector: true)
                } else {
                    ContentUnavailableView(String(localized: "No selection", bundle: .module), systemImage: "info.circle")
                }
            }
            .onChange(of: selection) { _, ids in
                if showingInfo, let first = ids.first { infoItem = try? session.services?.library.item(first) }
            }
            // Again when the items change (a favourite toggled on the selection changes the toolbar's title).
            .task(id: SelectionKey(ids: selection, revision: feed.update.revision)) { await loadSelectionInfo(selection) }
            .focusedSceneValue(\.gridActions, gridActions)
            .selectionHaptic(selection, isActive: isSelecting)
            .photosHaptic(.impact(weight: .light), trigger: favoriteToggles)
            .photosHaptic(.impact(weight: .medium), trigger: deletions)
            // Zoomed out, the timeline is cut into months and years instead of days.
            .onChange(of: columns, initial: true) { _, step in
                feed.setZoom(step: step)
            }
            #if DEBUG
                // Screenshots and UI checks: `PHOTOS_DEBUG_VIEWER=<index>` opens the viewer once the feed has items.
                .task(id: feed.items.isEmpty) {
                    if viewerStart == nil { viewerStart = ViewerStart.debugStart(ids: feed.items.map(\.fileId)) }
                }
            #endif
            .mediaViewer($viewerStart, zoom: zoomSource)
            .mediaSaveStatus(saver)
            .photoTaskStatus(photoTasks)
            .task { await observeAlbums() }
            .task(id: isInitialSync) { if isInitialSync { await session.loadInitialSyncTotal() } }
            .alert(
                String(localized: "Something went wrong", bundle: .module),
                isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
            ) {
            } message: {
                Text(actionError ?? "")
            }
    }

    @ViewBuilder var content: some View {
        // Items, or the placeholder tiles of the first sync's skeleton (`TimelineSkeleton`).
        if let services = session.services, feed.model.hasTiles {
            PhotoGrid(
                update: feed.update,
                zoomStep: feed.zoomStep,
                selection: selection,
                isSelecting: isSelecting,
                showsHeaders: showsHeaders,
                squareTiles: squareTiles,
                services: services,
                callbacks: GridCallbacks(
                    open: { id in openViewer(at: id) },
                    menu: { ids in menuActions(for: ids) },
                    selectionChanged: { ids in
                        selection = ids
                        #if os(macOS)
                            isSelecting = !ids.isEmpty
                        #else
                            if !ids.isEmpty { isSelecting = true }
                        #endif
                    },
                    columnsChanged: { columns = $0 },
                    cancelSelection: { endSelection() },
                    beginSelection: { isSelecting = true },
                    tileLocator: tileLocator,
                    copy: { ids in withItems(ids) { copy($0) } }
                )
            )
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .topLeading) {
                ViewerZoomSourceMark(tile: zoomTile, frame: zoomFrame, namespace: zoomNamespace)
            }
            .overlay(alignment: .topLeading) {
                if let highlight { TileHighlightMark(frame: highlight.frame).id(highlight.id) }
            }
        } else if session.isSignedOut {
            SignedOutView()
        } else if emptyPhase == .loading {
            GridSkeleton(zoomStep: columns, showsHeader: showsHeaders, caption: loadingCaption)
        } else if waitsForFirstSync, case .failed(let message, _) = session.syncStatus {
            // The library could not be loaded: say why, and offer to try again.
            ContentUnavailableView {
                Label(String(localized: "Couldn't sync", bundle: .module), systemImage: "exclamationmark.arrow.triangle.2.circlepath")
            } description: {
                Text(message)
            } actions: {
                Button(String(localized: "Retry", bundle: .module)) { Task { await session.syncNow() } }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            ContentUnavailableView {
                Label(emptyTitle, systemImage: "photo.on.rectangle.angled")
            } description: {
                Text(emptyMessage)
            } actions: {
                if session.syncStatus.isWorking {
                    ProgressView()
                } else if let emptyAction {
                    Button(emptyAction.title) { emptyAction.handler() }
                } else if waitsForFirstSync {
                    Button(String(localized: "Sync now", bundle: .module)) { Task { await session.syncNow(forceReconcile: true) } }
                }
            }
        }
    }

    /// Opens the viewer from a tile, which it zooms out of (iPhone, iPad).
    func openViewer(at id: FileID) {
        zoomTile = id
        zoomFrame = tileLocator.frame(id)
        viewerStart = viewerStart(at: id)
    }

    /// The zoom transition follows the photo the viewer shows: its tile is scrolled on screen, so closing the viewer
    /// zooms back into it.
    var zoomSource: ViewerZoomSource? {
        guard let tile = zoomTile ?? viewerStart?.startId else { return nil }
        return ViewerZoomSource(namespace: zoomNamespace, tile: tile) { id in
            tileLocator.reveal(id)
            zoomTile = id
            zoomFrame = tileLocator.frame(id)
        }
    }

    /// The viewer over this grid's photos, at `id`; stacked copies can be opened in it.
    func viewerStart(at id: FileID) -> ViewerStart {
        ViewerStart(ids: feed.model.ids, startId: id, stacks: TimelineStacking.stacks(in: feed.items), fromLibrary: isLibrary)
    }

    struct RevealKey: Equatable {
        var request: UUID?
        var revision: Int
    }

    /// "Show in library": once the grid has its photos, scrolls to the photo (or, when the Library does not show it, to
    /// the photo closest in time) and marks it — selected on the Mac, a short ring elsewhere.
    func carryOutReveal() async {
        guard let center = reveal, let request = center.pending, feed.loaded, !feed.items.isEmpty else { return }
        // The grid lays out the model it was just given first; a newer one starts this again.
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled, center.pending == request,
            let target = TimelineRevealCenter.target(of: request, in: feed.items)
        else { return }
        center.pending = nil
        endSelection()
        tileLocator.reveal(target.id)
        guard case .tile(let id) = target else { return }
        #if os(macOS)
            selection = [id]
            isSelecting = true
        #else
            if let frame = tileLocator.frame(id) { highlight = TileHighlight(frame: frame) }
        #endif
    }

    /// A slideshow of the selected items in the grid's order, or of the whole grid from `start` on.
    func playSlideshow(_ ids: [FileID]) {
        let all: [FileID] = feed.model.ids
        if ids.count > 1 {
            let chosen = Set(ids)
            slideshow = SlideshowRequest(title: title, ids: all.filter { chosen.contains($0) })
        } else if !all.isEmpty {
            slideshow = SlideshowRequest(title: title, ids: all, startId: ids.first)
        }
    }

    /// Favourites or unfavourites; undoable.
    func setFavorite(_ items: [MediaItem], _ value: Bool) {
        favoriteToggles += 1
        let undoManager = undoManager
        Task { await session.perform(.favorite(items, value: value), undoManager: undoManager) }
    }

    /// Skeleton or empty state (SPEC §6.3): the timeline is only called empty after a first sync has finished.
    var emptyPhase: GridEmptyPhase {
        var firstSyncRunning = false
        var hasSyncedBefore = false
        var syncStopped = false
        switch session.syncStatus {
        case .initialSync: firstSyncRunning = true
        case .idle(let lastSync): hasSyncedBefore = lastSync != nil
        // Incremental sync and reconciliation only run after the first sync.
        case .syncing, .reconciling: hasSyncedBefore = true
        case .offline, .failed: syncStopped = true
        }
        return GridEmptyPhase.phase(
            feedLoaded: feed.loaded, waitsForFirstSync: waitsForFirstSync, firstSyncRunning: firstSyncRunning,
            hasSyncedBefore: hasSyncedBefore, syncStopped: syncStopped)
    }

    var loadingCaption: String? {
        guard waitsForFirstSync else { return nil }
        if case .initialSync(let count) = session.syncStatus {
            return InitialSyncProgress.text(count: count, total: session.initialSyncTotal)
        }
        return String(localized: "Loading your library…", bundle: .module)
    }

    /// The first sync is running: its total is asked for once ("N of M").
    var isInitialSync: Bool {
        if case .initialSync = session.syncStatus { return true }
        return false
    }

    var selectionTitle: String {
        selection.isEmpty
            ? String(localized: "Select items", bundle: .module)
            : String(localized: "\(selection.count) selected", bundle: .module)
    }

    var deleteTitle: String {
        String(localized: "Delete \(confirmDelete?.items.count ?? 0) items?", bundle: .module)
    }

    /// Where deleted items go, and how many of them are stacked behind the selected tiles (SPEC TL-6).
    var deleteMessage: String {
        let trash: String =
            session.features.has(.trashbin)
            ? String(localized: "The items are moved to the trash bin of your Nextcloud.", bundle: .module)
            : String(localized: "The trash bin is disabled on your server: deleted items cannot be restored.", bundle: .module)
        guard let stacked = confirmDelete?.stacked, stacked > 0 else { return trash }
        let copies: String = String(localized: "This also deletes \(stacked) photos stacked behind the selected ones.", bundle: .module)
        return copies + " " + trash
    }

    /// The items of the tiles `ids` with everything stacked behind them: an action on a stack is an action on all of
    /// it (SPEC TL-6).
    func withStacks(_ ids: [FileID]) -> [FileID] {
        let model = feed.model
        return StackedSelection.members(of: ids) { model[$0]?.stack ?? [] }
    }

    /// Asks before deleting the tiles `ids` and the photos stacked behind them.
    func requestDelete(_ ids: [FileID]) {
        withItems(withStacks(ids)) { items in
            let deletable = items.filter(\.permissions.canDelete)
            guard !deletable.isEmpty else { return }
            confirmDelete = DeleteConfirmation(
                items: deletable, stacked: StackedSelection.hiddenCount(deletable.map(\.fileId), tiles: ids))
        }
    }

    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        // A group, not one item holding a stack: every control is a toolbar item of its own, with its own accessibility
        // label and tooltip, and the toolbar can move single items to the overflow menu instead of clipping at the window edge.
        ToolbarItemGroup(placement: .primaryAction) {
            accessory()
            #if !os(macOS)
                Button(isSelecting ? String(localized: "Done", bundle: .module) : String(localized: "Select", bundle: .module)) {
                    if isSelecting { endSelection() } else { isSelecting = true }
                }
                .disabled(feed.items.isEmpty)
            #endif
        }
        if isSelecting && !selection.isEmpty {
            ToolbarItemGroup(placement: selectionPlacement) {
                let info: GridSelectionInfo = selectionInfo
                let allFavorite: Bool = info.summary.allFavorite
                if let items = info.items {
                    ShareMediaButton(items: items)
                        .help(String(localized: "Share", bundle: .module))
                }
                Button {
                    withItems(withStacks(Array(selection))) { setFavorite($0, !allFavorite) }
                } label: {
                    Label(favoriteTitle(remove: allFavorite), systemImage: allFavorite ? "heart.slash" : "heart")
                }
                .help(favoriteTitle(remove: allFavorite))
                Menu {
                    // Without Delete and Share: both are buttons of their own in the toolbar.
                    ForEach(menuActions(info).filter { $0.id != "delete" && $0.share == nil }, id: \.id) { action in
                        if action.startsGroup { Divider() }
                        if action.children.isEmpty {
                            menuButton(action)
                        } else {
                            Menu {
                                ForEach(action.children, id: \.id) { child in
                                    if child.startsGroup { Divider() }
                                    menuButton(child)
                                }
                            } label: {
                                Label(action.title, systemImage: action.systemImage)
                            }
                        }
                    }
                } label: {
                    Label(String(localized: "More", bundle: .module), systemImage: "ellipsis.circle")
                }
                .help(String(localized: "More", bundle: .module))
                Button(role: .destructive) {
                    requestDelete(Array(selection))
                } label: {
                    Label(String(localized: "Delete", bundle: .module), systemImage: "trash")
                }
                .help(String(localized: "Delete", bundle: .module))
                .disabled(info.summary.deletable == 0)
            }
        }
    }

    func menuButton(_ action: GridMenuAction) -> some View {
        Button(role: action.isDestructive ? .destructive : nil) {
            action.handler(Array(selection))
        } label: {
            Label(action.title, systemImage: action.systemImage)
        }
    }

    var selectionPlacement: ToolbarItemPlacement {
        #if os(iOS)
            .bottomBar
        #else
            .automatic
        #endif
    }

    struct SelectionKey: Equatable {
        var ids: Set<FileID>
        var revision: Int
    }

    /// Selections up to this size are loaded as items (sharing, the screen's own actions); larger ones are only counted.
    static var eagerSelectionLimit: Int { 2000 }

    /// Loads what the toolbar and menus need for `ids`, off the main thread.
    func loadSelectionInfo(_ ids: Set<FileID>) async {
        guard !ids.isEmpty, let services = session.services else {
            selectionInfo = GridSelectionInfo()
            return
        }
        let list = Array(ids)
        if ids.count <= Self.eagerSelectionLimit {
            guard let map = try? await services.library.fetchItems(list), !Task.isCancelled else { return }
            let items = list.compactMap { map[$0] }
            selectionInfo = GridSelectionInfo(
                ids: ids, items: items, summary: SelectionSummary(items),
                shareItems: items.map { ShareableMedia(item: $0, services: services) })
        } else {
            guard let summary = try? await services.library.selectionSummary(list), !Task.isCancelled else { return }
            selectionInfo = GridSelectionInfo(ids: ids, items: nil, summary: summary)
        }
    }

    /// Runs `body` with the items of `ids`: at once when they are loaded already or few, else once they are read off the
    /// main thread (a selection of a whole library).
    func withItems(_ ids: [FileID], _ body: @escaping @MainActor ([MediaItem]) -> Void) {
        guard let library = session.services?.library, !ids.isEmpty else { return }
        if let items = selectionInfo.items, selectionInfo.ids.count == ids.count, selectionInfo.ids == Set(ids) {
            body(items)
        } else if ids.count <= 200, let map = try? library.items(ids) {
            body(ids.compactMap { map[$0] })
        } else {
            Task {
                guard let map = try? await library.fetchItems(ids) else { return }
                body(ids.compactMap { map[$0] })
            }
        }
    }

    /// Menu bar actions for this grid (SPEC §6.2, macOS menus).
    var gridActions: GridActions {
        let info = selectionInfo
        let summary = info.summary
        // Turned into a list only when an action runs: building it on every update costs as much as the selection is large.
        let selected = selection
        let single: MediaItem? = summary.count == 1 ? info.items?.first : nil
        let allFavorite = summary.allFavorite
        return GridActions(
            selectionCount: summary.count,
            allFavorite: allFavorite,
            toggleFavorite: { withItems(withStacks(Array(selected))) { setFavorite($0, !allFavorite) } },
            delete: { requestDelete(Array(selected)) },
            toggleInfo: {
                infoItem = info.items?.first
                showingInfo.toggle()
            },
            addToAlbum: { withItems(withStacks(Array(selected))) { albumPicker = PickedItems(items: $0) } },
            zoomIn: { columns = GridColumns.step(columns, zoomIn: true) },
            zoomOut: { columns = GridColumns.step(columns, zoomIn: false) },
            open: single.map { item in { openViewer(at: item.fileId) } },
            edit: single.flatMap { item in item.kind == .image ? { editedItem = item } : nil },
            editDateAndLocation: canEditMetadata(summary)
                ? { withItems(withStacks(Array(selected))) { metadataItems = PickedItems(items: $0.filter(\.permissions.canWrite)) } }
                : nil,
            export: summary.count == 0 ? nil : { withItems(Array(selected)) { export($0) } },
            shareItems: info.shareItems,
            shareTitle: single?.name ?? String(localized: "\(summary.count) items", bundle: .module),
            slideshow: feed.items.isEmpty ? nil : { playSlideshow(Array(selected)) },
            rotate: info.items.map(PhotoRotation.canRotate) == true ? { clockwise in rotate(Array(selected), clockwise: clockwise) } : nil,
            recentAlbums: summary.count == 0 ? [] : recentAlbums,
            addToRecentAlbum: { album in add(withStacks(Array(selected)), to: album) },
            addToNewAlbum: { withItems(withStacks(Array(selected))) { newAlbumItems = PickedItems(items: $0) } },
            useAsDesktopPicture: desktopPictureAction(single)
        )
    }

    /// Image ▸ Use as Desktop Picture for one still photo (Mac, SPEC §15.4).
    func desktopPictureAction(_ item: MediaItem?) -> (() -> Void)? {
        #if os(macOS)
            guard let item, DesktopPictureAction.isOffered(item) else { return nil }
            return { DesktopPictureAction.use(item, session: session) }
        #else
            return nil
        #endif
    }

    /// The albums the "Add to Album" submenus list.
    var recentAlbums: [Album] { RecentAlbums.pick(albums, used: usedAlbums) }

    func observeAlbums() async {
        guard let services = session.services else { return }
        usedAlbums = RecentAlbumsStore.used(session.account.id)
        do {
            for try await value in services.collections.observeAlbums(.own) { albums = value }
        } catch {}
    }

    /// "Add to Album ▸ <album>": remembered as used, so it stays at the top of the submenu.
    func add(_ ids: [FileID], to album: Album) {
        RecentAlbumsStore.note(album, account: session.account.id)
        usedAlbums = RecentAlbums.noting(album.id, in: usedAlbums)
        withItems(ids) { items in Task { await session.addToAlbum(items, album: album) } }
    }

    /// Image ▸ Rotate Left/Right: saved as a new version of each photo that may be changed (SPEC §6.2).
    func rotate(_ ids: [FileID], clockwise: Bool) {
        withItems(ids) { photoTasks.rotate($0, clockwise: clockwise, session: session) }
    }

    /// Edit ▸ Copy: the originals on the pasteboard.
    func copy(_ items: [MediaItem]) {
        guard let services = session.services else { return }
        photoTasks.copy(items, services: services)
    }

    /// "Add to Album" as a submenu: the recent albums, "New Album…", and "All Albums…" for the full list.
    func albumMenuAction(title: String) -> GridMenuAction {
        var children: [GridMenuAction] = [
            GridMenuAction(
                id: "album.new",
                title: PlatformWording.title(
                    mac: LocalizedStringResource("New Album…", bundle: .module),
                    other: LocalizedStringResource("New album…", bundle: .module)),
                systemImage: "plus.rectangle.on.rectangle"
            ) { ids in
                withItems(withStacks(ids)) { newAlbumItems = PickedItems(items: $0) }
            }
        ]
        let recent: [Album] = recentAlbums
        for (index, album) in recent.enumerated() {
            children.append(
                GridMenuAction(id: "album.\(album.id)", title: album.title, systemImage: "rectangle.stack", startsGroup: index == 0) {
                    ids in
                    add(withStacks(ids), to: album)
                })
        }
        if albums.count > recent.count {
            children.append(
                GridMenuAction(
                    id: "album.all",
                    title: PlatformWording.title(
                        mac: LocalizedStringResource(
                            "All Albums…", bundle: .module, comment: "Add to Album submenu: choose from every album."),
                        other: LocalizedStringResource(
                            "All albums…", bundle: .module, comment: "Add to Album submenu: choose from every album.")),
                    systemImage: "rectangle.stack", startsGroup: true
                ) { ids in
                    withItems(ids) { albumPicker = PickedItems(items: $0) }
                })
        }
        return GridMenuAction(
            id: "album", title: title, systemImage: "rectangle.stack.badge.plus", startsGroup: true,
            handler: { ids in
                withItems(ids) { albumPicker = PickedItems(items: $0) }
            }, children: children)
    }

    func canEditMetadata(_ summary: SelectionSummary) -> Bool {
        session.features.has(.metadataEdit) && summary.writable > 0
    }

    func favoriteTitle(remove: Bool) -> String {
        remove
            ? PlatformWording.title(
                mac: LocalizedStringResource("Remove from Favorites", bundle: .module),
                other: LocalizedStringResource("Remove from favorites", bundle: .module))
            : PlatformWording.title(
                mac: LocalizedStringResource("Add to Favorites", bundle: .module),
                other: LocalizedStringResource("Add to favorites", bundle: .module))
    }

    /// Saves the originals: to a folder the user picks on the Mac, to the photo library on the other platforms.
    func export(_ items: [MediaItem]) {
        guard let services = session.services else { return }
        saver.save(items, services: services)
    }

    func endSelection() {
        isSelecting = false
        selection = []
    }

    /// The context menu of the grid for `ids` (the selection, or the item that was clicked).
    func menuActions(for ids: [FileID]) -> [GridMenuAction] {
        if selectionInfo.ids.count == ids.count, selectionInfo.ids == Set(ids) { return menuActions(selectionInfo) }
        guard let library = session.services?.library else { return [] }
        // Not loaded yet (the selection has just changed): read it now. A context menu is opened once, not on every update.
        if ids.count <= Self.eagerSelectionLimit {
            guard let map = try? library.items(ids) else { return [] }
            let items = ids.compactMap { map[$0] }
            return menuActions(GridSelectionInfo(ids: Set(ids), items: items, summary: SelectionSummary(items)))
        }
        let summary = (try? library.selectionSummaryNow(ids)) ?? SelectionSummary()
        return menuActions(GridSelectionInfo(ids: Set(ids), items: nil, summary: summary))
    }

    /// The actions for a selection; they read the selected items only when they run.
    func menuActions(_ info: GridSelectionInfo) -> [GridMenuAction] {
        let summary = info.summary
        guard summary.count > 0 else { return [] }
        let single: MediaItem? = summary.count == 1 ? info.items?.first : nil
        // Open, Get Info · Add to Album, Export · Favorite, Archive, Edit… · screen-specific actions · Delete.
        var actions: [GridMenuAction] = []
        if let item = single {
            actions.append(
                GridMenuAction(
                    id: "open", title: String(localized: "Open", bundle: .module), systemImage: "arrow.up.left.and.arrow.down.right"
                ) { _ in
                    openViewer(at: item.fileId)
                })
            let infoTitle: String = PlatformWording.title(
                mac: LocalizedStringResource("Get Info", bundle: .module), other: LocalizedStringResource("Info", bundle: .module))
            actions.append(
                GridMenuAction(id: "info", title: infoTitle, systemImage: "info.circle") { _ in
                    infoItem = item
                    showingInfo = true
                })
            if let showInFolder {
                actions.append(
                    GridMenuAction(id: "folder", title: ShowInFolderAction.title, systemImage: ShowInFolderAction.systemImage) { _ in
                        showInFolder(item)
                    })
            }
            if let showInTimeline, !isLibrary, ShowInTimelineAction.isOffered(for: item) {
                actions.append(
                    GridMenuAction(id: "timeline", title: ShowInTimelineAction.title, systemImage: ShowInTimelineAction.systemImage) { _ in
                        showInTimeline(item)
                    })
            }
        }
        actions.append(
            GridMenuAction(id: "slideshow", title: SlideshowRequest.menuTitle, systemImage: SlideshowRequest.systemImage) { ids in
                playSlideshow(ids)
            })
        let albumTitle: String = PlatformWording.title(
            mac: LocalizedStringResource("Add to Album", bundle: .module, comment: "Submenu with the recent albums and New Album…."),
            other: LocalizedStringResource("Add to album", bundle: .module, comment: "Submenu with the recent albums and New album…."))
        actions.append(albumMenuAction(title: albumTitle))
        if session.features.has(.systemtags) {
            actions.append(
                GridMenuAction(id: "tags", title: TagWording.menuTitle, systemImage: "tag") { ids in
                    withItems(withStacks(ids)) { tagEditor = PickedItems(items: $0) }
                })
        }
        let exportTitle: String = PlatformWording.title(
            mac: LocalizedStringResource("Export…", bundle: .module), other: LocalizedStringResource("Save to Photos", bundle: .module))
        actions.append(
            GridMenuAction(id: "save", title: exportTitle, systemImage: "square.and.arrow.down") { ids in withItems(ids) { export($0) } })
        // Edit ▸ Copy is only in the Mac's menu bar and on a hardware keyboard: here too, as in Photos.
        if let items = info.items, !items.isEmpty {
            actions.append(
                GridMenuAction(id: "copy", title: String(localized: "Copy", bundle: .module), systemImage: "doc.on.doc") { _ in
                    copy(items)
                })
        }
        // The system's Share menu with the originals (downloaded when a service asks for them); a loaded selection only.
        if let items = info.items, !items.isEmpty, let services = session.services {
            actions.append(
                GridMenuAction(
                    id: "share", title: String(localized: "Share…", bundle: .module), systemImage: "square.and.arrow.up",
                    handler: { _ in },
                    share: { MediaItemProviders.make(items, services: services) }))
        }
        if let item = single, item.permissions.canShare {
            actions.append(
                GridMenuAction(
                    id: "ncshare", title: String(localized: "Share via Nextcloud…", bundle: .module), systemImage: "person.badge.plus"
                ) { _ in
                    nextcloudShare = SharingTarget(item: item)
                })
        } else if single == nil, let items = info.items, items.contains(where: \.permissions.canShare) {
            // Several photos: one share per photo and recipient (`MultiFileSharingSheet`).
            actions.append(
                GridMenuAction(
                    id: "ncshare", title: String(localized: "Share via Nextcloud…", bundle: .module), systemImage: "person.badge.plus"
                ) { _ in
                    nextcloudShareMany = PickedItems(items: items.filter(\.permissions.canShare))
                })
        }
        let allFavorite = summary.allFavorite
        actions.append(
            GridMenuAction(
                id: "favorite", title: favoriteTitle(remove: allFavorite), systemImage: allFavorite ? "heart.slash" : "heart",
                startsGroup: true
            ) { ids in
                withItems(withStacks(ids)) { setFavorite($0, !allFavorite) }
            })
        if summary.archivable > 0 {
            actions.append(
                GridMenuAction(id: "archive", title: String(localized: "Archive", bundle: .module), systemImage: "archivebox") { ids in
                    let undoManager = undoManager
                    withItems(withStacks(ids)) { items in Task { await session.perform(.archive(items), undoManager: undoManager) } }
                    endSelection()
                })
        }
        if summary.archived > 0 {
            actions.append(
                GridMenuAction(id: "unarchive", title: String(localized: "Unarchive", bundle: .module), systemImage: "tray.and.arrow.up") {
                    ids in
                    let undoManager = undoManager
                    withItems(withStacks(ids)) { items in Task { await session.perform(.unarchive(items), undoManager: undoManager) } }
                    endSelection()
                })
        }
        if let item = single, item.kind == .image {
            actions.append(
                GridMenuAction(id: "edit", title: String(localized: "Edit…", bundle: .module), systemImage: "slider.horizontal.3") { _ in
                    editedItem = item
                })
        }
        #if os(macOS)
            if let use = desktopPictureAction(single) {
                actions.append(
                    GridMenuAction(id: "desktop", title: DesktopPictureAction.title, systemImage: DesktopPictureAction.systemImage) { _ in
                        use()
                    })
            }
        #endif
        // Image ▸ Rotate in the context menu as well (iPhone and iPad have no menu bar); only for photos that may be changed.
        if let items = info.items, PhotoRotation.canRotate(items) {
            actions.append(
                GridMenuAction(id: "rotate.left", title: String(localized: "Rotate Left", bundle: .module), systemImage: "rotate.left") {
                    ids in
                    rotate(ids, clockwise: false)
                })
            actions.append(
                GridMenuAction(id: "rotate.right", title: String(localized: "Rotate Right", bundle: .module), systemImage: "rotate.right") {
                    ids in
                    rotate(ids, clockwise: true)
                })
        }
        if canEditMetadata(summary) {
            let metadataTitle: String = PlatformWording.title(
                mac: LocalizedStringResource("Edit Date and Location…", bundle: .module),
                other: LocalizedStringResource("Edit date and location…", bundle: .module))
            actions.append(
                GridMenuAction(id: "metadata", title: metadataTitle, systemImage: "calendar.badge.clock") { ids in
                    withItems(withStacks(ids)) { metadataItems = PickedItems(items: $0.filter(\.permissions.canWrite)) }
                })
        }
        // The screen's own actions (remove from album…) work on the items; a selection too large to load has none.
        var extras: [GridMenuAction] = info.items.map(extraActions) ?? []
        if !extras.isEmpty { extras[0].startsGroup = true }
        actions += extras
        if summary.deletable > 0 {
            actions.append(
                GridMenuAction(
                    id: "delete", title: String(localized: "Delete…", bundle: .module), systemImage: "trash", isDestructive: true,
                    startsGroup: true
                ) { ids in
                    requestDelete(ids)
                })
        }
        return actions
    }

    /// The confirmation of the last change ("Archived 3 items · Undo") above the account's status.
    var statusBanner: some View {
        VStack(spacing: 0) {
            ChangeNoticeToast()
            GridStatusBanner(hasItems: feed.model.hasTiles)
        }
        .animation(.default, value: session.lastChange?.id)
    }
}

/// The selection of a grid as its toolbar and menus need it.
struct GridSelectionInfo {
    var ids: Set<FileID> = []
    /// The items, for selections up to `MediaGridScreen.eagerSelectionLimit`; `nil` for larger ones.
    var items: [MediaItem]? = []
    var summary = SelectionSummary()
    /// The originals for the share sheet (loaded selections only).
    var shareItems: [ShareableMedia] = []
}

/// A delete that waits for its confirmation.
struct DeleteConfirmation {
    var items: [MediaItem]
    /// Items among them that are stacked behind the selected tiles (copies, burst frames), not tiles of their own.
    var stacked = 0
}

/// The action button of a grid's empty state.
struct GridEmptyAction {
    var title: String
    var handler: @MainActor () -> Void
}

/// Placeholder tiles in the grid's own geometry while nothing is known yet (first load, first sync).
struct GridSkeleton: View {
    let zoomStep: Int
    var showsHeader = true
    var caption: String?
    @State private var dimmed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let geometry: GridGeometry = GridColumns.geometry(width: Double(proxy.size.width), step: zoomStep)
            let side: CGFloat = CGFloat(geometry.side)
            let spacing: CGFloat = CGFloat(geometry.spacing)
            let rows: Int = max(1, Int((proxy.size.height / (side + spacing)).rounded(.up)))
            VStack(alignment: .leading, spacing: spacing) {
                if showsHeader {
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 5).frame(width: 150, height: 20)
                        RoundedRectangle(cornerRadius: 4).frame(width: 90, height: 11)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                }
                ForEach(0..<rows, id: \.self) { _ in
                    HStack(spacing: spacing) {
                        ForEach(0..<geometry.columns, id: \.self) { _ in
                            Rectangle().frame(width: side, height: side)
                        }
                    }
                }
            }
            .foregroundStyle(.quaternary)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .clipped()
        }
        .opacity(dimmed ? 0.45 : 1)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dimmed)
        .onAppear { dimmed = true }
        .overlay(alignment: .bottom) {
            if let caption {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(caption)
                }
                .font(.footnote)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: .capsule)
                .padding(.bottom, 12)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption ?? String(localized: "Loading…", bundle: .module))
    }
}

/// Shows a freshly created public link.
struct LinkShareSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Anyone with this link can see the selected photos.", bundle: .module).multilineTextAlignment(.center)
                Text(url.absoluteString).font(.footnote).textSelection(.enabled)
                if let qr = QRCode.image(for: url.absoluteString) {
                    Image(decorative: qr, scale: 1).interpolation(.none).resizable().frame(width: 180, height: 180)
                }
                HStack {
                    Button(String(localized: "Copy link", bundle: .module)) { Clipboard.copyLink(url.absoluteString) }
                    ShareLink(item: url)
                }
            }
            .padding()
            .navigationTitle(String(localized: "Link created", bundle: .module))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done", bundle: .module)) { dismiss() }
                }
            }
        }
        .frame(minWidth: 380, minHeight: 420)
    }
}

struct ViewerStart: Identifiable, Hashable {
    var id: FileID { startId }
    var ids: [FileID]
    var startId: FileID
    /// Copies of one shot behind a tile (`TimelineStacking`), by the tile's id: the viewer can open them.
    var stacks: [FileID: [FileID]] = [:]
    /// Opened from the Library: the viewer does not offer "Show in library".
    var fromLibrary = false
}

/// Shown when the account's login is no longer valid.
struct SignedOutView: View {
    @Environment(AppModel.self) private var app
    @Environment(SessionModel.self) private var session
    @State private var relogin = false

    var body: some View {
        ContentUnavailableView {
            Label(String(localized: "Signed out", bundle: .module), systemImage: "person.crop.circle.badge.exclamationmark")
        } description: {
            Self.reason(session)
        } actions: {
            Button(String(localized: "Log in again", bundle: .module)) { relogin = true }
                .buttonStyle(.borderedProminent)
        }
        .sheet(isPresented: $relogin) { AddAccountSheet() }
    }

    /// Why the account is signed out: the server no longer accepts the login, or the keychain has none (it could not
    /// be stored or read) — the latter is not the server's doing and must not be reported as such.
    static func reason(_ session: SessionModel) -> Text {
        let host = session.account.hostDisplayName
        if session.isLoginMissing {
            return Text(
                "Your login for \(host) is missing from the keychain. Please log in again.", bundle: .module,
                comment: """
                    Signed-out screen and Settings when the app password of the account is not in the system keychain (it could \
                    not be saved or read). The placeholder is the server's host name.
                    """)
        }
        return Text("Your login for \(host) is no longer valid. Please log in again.", bundle: .module)
    }
}
