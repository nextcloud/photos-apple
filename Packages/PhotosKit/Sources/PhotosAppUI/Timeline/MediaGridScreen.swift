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
    @ViewBuilder var accessory: () -> Accessory

    @Environment(SessionModel.self) private var session
    /// The window's undo manager: Edit › Undo and ⌘Z on the Mac and iPad, shake on iPhone.
    @Environment(\.undoManager) private var undoManager
    @State private var selection: Set<FileID> = []
    @State private var isSelecting = false
    @State private var viewerStart: ViewerStart?
    @State private var confirmDelete: [MediaItem]?
    @State private var infoItem: MediaItem?
    @State private var showingInfo = false
    @State private var actionError: String?
    @State private var albumPicker: PickedItems?
    @State private var sharedLink: SharedLink?
    @State private var metadataItems: PickedItems?
    @State private var editedItem: MediaItem?
    /// Haptic triggers (iPhone, iPad).
    @State private var favoriteToggles = 0
    @State private var deletions = 0
    /// Export… / Save to Photos, with its progress and result.
    @State private var saver = MediaSaveModel()

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
            #endif
            .toolbar { toolbar }
            .overlay(alignment: .bottom) { statusBanner }
            // Changes made in this window are undone by this window's Edit › Undo.
            .onChange(of: undoManager, initial: true) { _, manager in
                if let manager { session.undoManager = manager }
            }
            .confirmationDialog(
                deleteTitle, isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button(String(localized: "Delete", bundle: .module), role: .destructive) {
                    if let items = confirmDelete {
                        deletions += 1
                        Task { await session.perform(.delete(items)) }
                    }
                    endSelection()
                }
            } message: {
                Text(
                    session.features.has(.trashbin)
                        ? String(localized: "The items are moved to the trash bin of your Nextcloud.", bundle: .module)
                        : String(localized: "The trash bin is disabled on your server: deleted items cannot be restored.", bundle: .module))
            }
            .sheet(item: $albumPicker) { picked in AlbumPickerSheet(items: picked.items) }
            .sheet(item: $sharedLink) { link in LinkShareSheet(url: link.url) }
            .sheet(item: $metadataItems) { picked in MetadataEditor(items: picked.items) }
            .sheet(item: $editedItem) { item in EditorView(item: item) }
            .infoInspector(isPresented: $showingInfo) {
                if let item = infoItem ?? selectedItems.first {
                    InfoPanel(item: item, inInspector: true)
                } else {
                    ContentUnavailableView(String(localized: "No selection", bundle: .module), systemImage: "info.circle")
                }
            }
            .onChange(of: selection) { _, ids in
                if showingInfo, let first = ids.first { infoItem = try? session.services?.library.item(first) }
            }
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
            .mediaViewer($viewerStart)
            .mediaSaveStatus(saver)
            .alert(
                String(localized: "Something went wrong", bundle: .module),
                isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
            ) {
            } message: {
                Text(actionError ?? "")
            }
    }

    @ViewBuilder var content: some View {
        if let services = session.services, !feed.items.isEmpty {
            PhotoGrid(
                update: feed.update,
                zoomStep: feed.zoomStep,
                selection: selection,
                isSelecting: isSelecting,
                showsHeaders: showsHeaders,
                services: services,
                callbacks: GridCallbacks(
                    open: { id in viewerStart = ViewerStart(ids: feed.model.ids, startId: id) },
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
                    beginSelection: { isSelecting = true }
                )
            )
            .ignoresSafeArea(edges: .bottom)
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

    /// Favourites or unfavourites; undoable.
    func setFavorite(_ items: [MediaItem], _ value: Bool) {
        favoriteToggles += 1
        Task { await session.perform(.favorite(items, value: value)) }
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
        if case .initialSync(let count) = session.syncStatus, count > 0 {
            return String(localized: "Loading library… \(count)", bundle: .module)
        }
        return String(localized: "Loading your library…", bundle: .module)
    }

    var selectionTitle: String {
        selection.isEmpty
            ? String(localized: "Select items", bundle: .module)
            : String(localized: "\(selection.count) selected", bundle: .module)
    }

    var deleteTitle: String {
        String(localized: "Delete \(confirmDelete?.count ?? 0) items?", bundle: .module)
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
                let items = selectedItems
                ShareMediaButton(items: items)
                    .help(String(localized: "Share", bundle: .module))
                Button {
                    setFavorite(items, !items.allSatisfy(\.isFavorite))
                } label: {
                    Label(
                        favoriteTitle(remove: items.allSatisfy(\.isFavorite)),
                        systemImage: items.allSatisfy(\.isFavorite) ? "heart.slash" : "heart")
                }
                .help(favoriteTitle(remove: items.allSatisfy(\.isFavorite)))
                Menu {
                    ForEach(menuActions(for: Array(selection)).filter { $0.id != "delete" }, id: \.id) { action in
                        if action.startsGroup { Divider() }
                        Button(role: action.isDestructive ? .destructive : nil) {
                            action.handler(Array(selection))
                        } label: {
                            Label(action.title, systemImage: action.systemImage)
                        }
                    }
                } label: {
                    Label(String(localized: "More", bundle: .module), systemImage: "ellipsis.circle")
                }
                .help(String(localized: "More", bundle: .module))
                Button(role: .destructive) {
                    confirmDelete = items.filter(\.permissions.canDelete)
                } label: {
                    Label(String(localized: "Delete", bundle: .module), systemImage: "trash")
                }
                .help(String(localized: "Delete", bundle: .module))
                .disabled(!items.contains { $0.permissions.canDelete })
            }
        }
    }

    var selectionPlacement: ToolbarItemPlacement {
        #if os(iOS)
            .bottomBar
        #else
            .automatic
        #endif
    }

    var selectedItems: [MediaItem] {
        guard let services = session.services, let map = try? services.library.items(Array(selection)) else { return [] }
        return selection.compactMap { map[$0] }
    }

    /// Menu bar actions for this grid (SPEC §6.2, macOS menus).
    var gridActions: GridActions {
        let items = selectedItems
        return GridActions(
            selectionCount: items.count,
            allFavorite: !items.isEmpty && items.allSatisfy(\.isFavorite),
            toggleFavorite: { setFavorite(items, !items.allSatisfy(\.isFavorite)) },
            delete: { confirmDelete = items.filter(\.permissions.canDelete) },
            toggleInfo: {
                infoItem = items.first
                showingInfo.toggle()
            },
            addToAlbum: { albumPicker = PickedItems(items: items) },
            zoomIn: { columns = GridColumns.step(columns, zoomIn: true) },
            zoomOut: { columns = GridColumns.step(columns, zoomIn: false) },
            open: items.count == 1 ? { viewerStart = ViewerStart(ids: feed.items.map(\.fileId), startId: items[0].fileId) } : nil,
            edit: items.count == 1 && items[0].kind == .image ? { editedItem = items[0] } : nil,
            editDateAndLocation: canEditMetadata(items)
                ? { metadataItems = PickedItems(items: items.filter(\.permissions.canWrite)) } : nil,
            export: items.isEmpty ? nil : { export(items) },
            shareItems: session.services.map { services in items.map { ShareableMedia(item: $0, services: services) } } ?? [],
            shareTitle: items.count == 1 ? items[0].name : String(localized: "\(items.count) items", bundle: .module)
        )
    }

    func canEditMetadata(_ items: [MediaItem]) -> Bool {
        session.features.has(.metadataEdit) && items.contains(where: \.permissions.canWrite)
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

    func menuActions(for ids: [FileID]) -> [GridMenuAction] {
        guard let services = session.services, let map = try? services.library.items(ids) else { return [] }
        let items = ids.compactMap { map[$0] }
        guard !items.isEmpty else { return [] }
        // Open, Get Info · Add to Album, Export · Favorite, Archive, Edit… · screen-specific actions · Delete.
        var actions: [GridMenuAction] = []
        if items.count == 1, let item = items.first {
            actions.append(
                GridMenuAction(
                    id: "open", title: String(localized: "Open", bundle: .module), systemImage: "arrow.up.left.and.arrow.down.right"
                ) { _ in
                    viewerStart = ViewerStart(ids: feed.items.map(\.fileId), startId: item.fileId)
                })
            let infoTitle: String = PlatformWording.title(
                mac: LocalizedStringResource("Get Info", bundle: .module), other: LocalizedStringResource("Info", bundle: .module))
            actions.append(
                GridMenuAction(id: "info", title: infoTitle, systemImage: "info.circle") { _ in
                    infoItem = item
                    showingInfo = true
                })
        }
        let albumTitle: String = PlatformWording.title(
            mac: LocalizedStringResource("Add to Album…", bundle: .module),
            other: LocalizedStringResource("Add to album…", bundle: .module))
        actions.append(
            GridMenuAction(id: "album", title: albumTitle, systemImage: "rectangle.stack.badge.plus", startsGroup: true) { _ in
                albumPicker = PickedItems(items: items)
            })
        let exportTitle: String = PlatformWording.title(
            mac: LocalizedStringResource("Export…", bundle: .module), other: LocalizedStringResource("Save to Photos", bundle: .module))
        actions.append(
            GridMenuAction(id: "save", title: exportTitle, systemImage: "square.and.arrow.down") { _ in export(items) })
        let allFavorite = items.allSatisfy(\.isFavorite)
        actions.append(
            GridMenuAction(
                id: "favorite", title: favoriteTitle(remove: allFavorite), systemImage: allFavorite ? "heart.slash" : "heart",
                startsGroup: true
            ) { _ in
                setFavorite(items, !allFavorite)
            })
        if items.contains(where: { $0.isOwnStorage && !$0.isArchived && $0.permissions.canDelete }) {
            actions.append(
                GridMenuAction(id: "archive", title: String(localized: "Archive", bundle: .module), systemImage: "archivebox") { _ in
                    Task { await session.perform(.archive(items)) }
                    endSelection()
                })
        }
        if items.contains(where: \.isArchived) {
            actions.append(
                GridMenuAction(id: "unarchive", title: String(localized: "Unarchive", bundle: .module), systemImage: "tray.and.arrow.up") {
                    _ in
                    Task { await session.perform(.unarchive(items)) }
                    endSelection()
                })
        }
        if items.count == 1, let item = items.first, item.kind == .image {
            actions.append(
                GridMenuAction(id: "edit", title: String(localized: "Edit…", bundle: .module), systemImage: "slider.horizontal.3") { _ in
                    editedItem = item
                })
        }
        if canEditMetadata(items) {
            let metadataTitle: String = PlatformWording.title(
                mac: LocalizedStringResource("Edit Date and Location…", bundle: .module),
                other: LocalizedStringResource("Edit date and location…", bundle: .module))
            actions.append(
                GridMenuAction(id: "metadata", title: metadataTitle, systemImage: "calendar.badge.clock") { _ in
                    metadataItems = PickedItems(items: items.filter(\.permissions.canWrite))
                })
        }
        var extras: [GridMenuAction] = extraActions(items)
        if !extras.isEmpty { extras[0].startsGroup = true }
        actions += extras
        if items.contains(where: { $0.permissions.canDelete }) {
            actions.append(
                GridMenuAction(
                    id: "delete", title: String(localized: "Delete…", bundle: .module), systemImage: "trash", isDestructive: true,
                    startsGroup: true
                ) { _ in
                    confirmDelete = items.filter(\.permissions.canDelete)
                })
        }
        return actions
    }

    /// The confirmation of the last change ("Archived 3 items · Undo") above the account's status.
    var statusBanner: some View {
        VStack(spacing: 0) {
            ChangeNoticeToast()
            GridStatusBanner(hasItems: !feed.items.isEmpty)
        }
        .animation(.default, value: session.lastChange?.id)
    }
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
                    Button(String(localized: "Copy link", bundle: .module)) { Clipboard.copy(url.absoluteString) }
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
            Text("Your login for \(session.account.hostDisplayName) is no longer valid. Please log in again.", bundle: .module)
        } actions: {
            Button(String(localized: "Log in again", bundle: .module)) { relogin = true }
                .buttonStyle(.borderedProminent)
        }
        .sheet(isPresented: $relogin) { AddAccountSheet() }
    }
}
