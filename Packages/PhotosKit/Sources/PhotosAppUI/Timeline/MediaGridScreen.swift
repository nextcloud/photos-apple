// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosStore
import SwiftUI

/// A grid with selection, actions, sync status and viewer (shared by timeline, albums, places…).
struct MediaGridScreen<Accessory: View>: View {
    // State the extensions in MediaGridScreen+*.swift use is internal rather than private (SPEC §20.7).
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
    /// Image ▸ Delete Rejected… (the Library, SPEC §15.2).
    var deleteRejected: (() -> Void)? = nil
    /// Moment titles on the day headers and what a tap on one opens (the Library, SPEC §16.1).
    var moments = MomentHeaders.none
    var openMoment: ((String) -> Void)? = nil
    /// Scrolls above the photos, in the grid (the Library's memories on iPhone, iPad and Vision Pro, SPEC §17.2).
    var gridHeader: AnyView? = nil
    /// A cover with the title above the first row (an album, a memory, a person; iPhone and iPad, SPEC §17.4).
    var hero: GridHero? = nil
    /// After Select, a glass button of its own (the Library's account button, SPEC §19.2); not while selecting.
    var trailingItem: AnyView? = nil
    @ViewBuilder var accessory: () -> Accessory

    @Environment(SessionModel.self) var session
    /// The window's undo manager: Edit › Undo and ⌘Z on the Mac and iPad, shake on iPhone. Not `@Environment`: see
    /// `UndoManagerBox`.
    @State private var undoBox = UndoManagerBox()
    var undoManager: UndoManager? { undoBox.manager }
    @State var selection: Set<FileID> = []
    /// What the toolbar and the menus show for the selection, loaded off the main thread when the selection changes.
    @State var selectionInfo = GridSelectionInfo()
    @State var isSelecting = false
    @State var viewerStart: ViewerStart?
    @State var confirmDelete: DeleteConfirmation?
    @State var infoItem: MediaItem?
    @State var showingInfo = false
    @State private var actionError: String?
    @State var albumPicker: PickedItems?
    @State var tagEditor: PickedItems?
    @State private var sharedLink: SharedLink?
    @State var metadataItems: PickedItems?
    /// Batch fixes: date and time, place, names, GPS track (SPEC §16.4).
    @State var batchFix: BatchFixRequest?
    @State var editedItem: MediaItem?
    /// Nextcloud's own sharing of one photo (users, other servers, email, Talk, links with password and expiry).
    @State var nextcloudShare: SharingTarget?
    /// Nextcloud's own sharing of several photos at once.
    @State var nextcloudShareMany: PickedItems?
    /// Slideshow of the selection or of the whole grid (SPEC VW-5).
    @State var slideshow: SlideshowRequest?
    /// A collage of the selection (SPEC §15.8.3).
    @State var collage: CollageRequest?
    /// The tile "Show in library" opened the grid at, marked for a moment (iPhone, iPad, Vision Pro).
    @State var highlight: TileHighlight?
    /// Haptic triggers (iPhone, iPad).
    @State var favoriteToggles = 0
    @State private var deletions = 0
    /// Export… / Save to Photos, with its progress and result.
    @State var saver = MediaSaveModel()
    /// Image ▸ Rotate and Edit ▸ Copy, with their progress and result.
    @State var photoTasks = PhotoTaskModel()
    /// The undo history from the selection's More menu (iPhone, iPad; SPEC §16.3.4).
    @State var showingUndoHistory = false
    /// Own albums, for the "Add to Album" submenus; the ones used last in this app (`RecentAlbumsStore`) come first.
    @State var albums: [Album] = []
    @State var usedAlbums: [String] = []
    /// "Add to Album ▸ New Album…": a new album with these items.
    @State var newAlbumItems: PickedItems?
    /// Ratings and flags given here, and the compare view (SPEC §15.2).
    @State var culling = CullingModel()
    @State var compareRequest: CompareRequest?
    /// The culling view with loupe and filmstrip (SPEC §16.5.2).
    @State var loupeRequest: LoupeRequest?
    /// The zoom transition into the viewer and back (iPhone, iPad): the tile it starts from and where that tile is.
    @Namespace var zoomNamespace
    @State var tileLocator = GridTileLocator()
    @State var zoomTile: FileID?
    @State var zoomFrame: CGRect?
    /// Heart bursts and the way removed tiles leave and come back (SPEC §17.2).
    @State var motion = GridActionMotion()
    @Environment(\.showInFolder) var showInFolder
    /// Square tiles or the aspect ratio grid (Settings, View ▸ Square Tiles).
    @AppStorage(TileStyle.squareTilesKey) private var squareTiles = true
    @Environment(\.showInTimeline) var showInTimeline
    #if os(iOS)
        @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    /// Years, months and days around this grid (the Library's zoom levels, SPEC §15.5); nil elsewhere.
    @Environment(\.libraryZoom) var libraryZoom
    @Environment(\.floatingBottomInset) var floatingBottomInset
    /// "Show Similar" for this photo (SPEC §15.5).
    @State var similarTo: MediaItem?
    /// Select ⇄ Done morphs the toolbars; a fade with Reduce Motion (SPEC §17.3).
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    /// The hero's title has gone under the navigation bar: the bar shows the title (SPEC §17.4).
    @State var heroCollapsed = false

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
            .readsUndoManager(into: undoBox)
            .navigationTitle(isSelecting && !keepsTitleWhileSelecting ? selectionTitle : title)
            .preference(key: GridSelectionState.Key.self, value: GridSelectionState(isSelecting: isSelecting, count: selection.count))
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                // The hero shows the title while it is in view; the bar takes it over when the hero has gone.
                .toolbar(removing: heroShowsTitle ? .title : nil)
                .animation(.smooth(duration: 0.25), value: heroCollapsed)
                // iPhone: the selection's actions take the place of the tab bar, as in Photos (else they are under it).
                .toolbar(isSelecting && sizeClass == .compact ? .hidden : .automatic, for: .tabBar)
            #endif
            .toolbar { toolbar }
            #if !os(macOS)
                .toolbar { selectionCountTitle }
            #endif
            // Before the selection bar: the notices ("Change undone") stand above it instead of covering its count.
            .overlay(alignment: .bottom) { statusBanner }
            #if os(iOS)
                // In place of the tab bar while selecting (SPEC §17.3).
                .safeAreaBar(edge: .bottom) { selectionActionBar }
            #endif
            .confirmationDialog(
                deleteTitle, isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button(String(localized: "Delete", bundle: .module), role: .destructive) {
                    if let items = confirmDelete?.items {
                        deletions += 1
                        motion.expectLeaving(items.map(\.fileId), style: .collapse)
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
            .collageEditor($collage)
            .sheet(item: $sharedLink) { link in LinkShareSheet(url: link.url) }
            .sheet(item: $metadataItems) { picked in BatchFixSheet(items: picked.items) }
            .sheet(item: $batchFix) { request in BatchFixSheet(items: request.items, mode: request.mode) }
            .photoEditor($editedItem)
            .similarPhotosSheet($similarTo)
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
            .selectionStartHaptic(isSelecting)
            .photosHaptic(.impact(weight: .light), trigger: favoriteToggles)
            .photosHaptic(.impact(weight: .medium), trigger: deletions)
            // Zoomed out, the timeline is cut into months and years instead of days.
            .onChange(of: columns, initial: true) { _, step in
                feed.setZoom(step: step)
            }
            .libraryZoomPlacement(libraryZoom, locator: tileLocator)
            #if DEBUG
                // Screenshots and UI checks: `PHOTOS_DEBUG_VIEWER=<index>` opens the viewer once the feed has items.
                .task(id: feed.items.isEmpty) {
                    if viewerStart == nil { viewerStart = ViewerStart.debugStart(ids: feed.items.map(\.fileId)) }
                    if compareRequest == nil { compareRequest = CompareRequest.debugStart(ids: feed.items.map(\.fileId)) }
                    if loupeRequest == nil { loupeRequest = LoupeRequest.debugStart(ids: feed.items.map(\.fileId)) }
                    #if os(macOS)
                        ExternalEditCenter.debugStart(ids: feed.items.map(\.fileId), session: session)
                    #endif
                }
            #endif
            .mediaViewer($viewerStart, zoom: zoomSource)
            .compareView($compareRequest)
            .loupeCulling($loupeRequest)
            .cullingFeedback(culling)
            .mediaSaveStatus(saver)
            .photoTaskStatus(photoTasks)
            .undoHistorySheet(isPresented: $showingUndoHistory)
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
                moments: moments,
                header: gridHeader,
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
                    copy: { ids in withItems(ids) { copy($0) } },
                    cull: cullCallback,
                    compare: { (ids: [FileID]) in compare(ids) },
                    zoomPastEnd: zoomPastEnd,
                    openMoment: momentOpener,
                    motion: motion
                ),
                hero: gridHero
            )
            #if os(macOS)
                .ignoresSafeArea(edges: .bottom)
            #else
                // Edge to edge (SPEC §17.2): the photos scroll under the bars, which blur them softly; a hero's cover
                // (SPEC §17.4) begins at the top of the screen.
                .ignoresSafeArea(edges: [.top, .bottom])
            #endif
            // The Library's zoom levels morph into the grid's tiles (SPEC §17.5).
            .libraryZoomGridFrame(libraryZoom, locator: tileLocator)
            .overlay(alignment: .topLeading) {
                ViewerZoomSourceMark(tile: zoomTile, frame: zoomFrame, namespace: zoomNamespace)
            }
            .overlay(alignment: .topLeading) {
                if let highlight { TileHighlightMark(frame: highlight.frame).id(highlight.id) }
            }
        } else if session.isSignedOut {
            SignedOutView()
        } else if emptyPhase == .loading, let gridHero {
            // The hero is there from the start (an album zooms in with its cover), the tiles' shapes below it.
            HeroSkeleton(hero: gridHero, zoomStep: columns)
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
            .livingEmptyBackground()
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
            // No photos, no results, offline: on a living wash (SPEC §17.6.1).
            .livingEmptyBackground()
        }
    }
}
