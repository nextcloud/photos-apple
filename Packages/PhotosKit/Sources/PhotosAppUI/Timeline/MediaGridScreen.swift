// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
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
    @Binding var columns: Int
    /// Extra actions offered for selected items (e.g. "Remove from album").
    var extraActions: ([MediaItem]) -> [GridMenuAction] = { _ in [] }
    @ViewBuilder var accessory: () -> Accessory

    @Environment(SessionModel.self) private var session
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
            .navigationTitle(isSelecting ? selectionTitle : title)
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbar }
            .overlay(alignment: .bottom) { statusBanner }
            .confirmationDialog(
                deleteTitle, isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button(String(localized: "Delete", bundle: .module), role: .destructive) {
                    if let items = confirmDelete { Task { await session.delete(items) } }
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
            #if DEBUG
                // Screenshots and UI checks: `PHOTOS_DEBUG_VIEWER=<index>` opens the viewer once the feed has items.
                .task(id: feed.items.isEmpty) {
                    if viewerStart == nil { viewerStart = ViewerStart.debugStart(ids: feed.items.map(\.fileId)) }
                }
            #endif
            #if os(iOS)
                .fullScreenCover(item: $viewerStart) { start in
                    MediaViewer(ids: start.ids, startId: start.startId).environment(session)
                }
            #else
                .navigationDestination(item: $viewerStart) { start in
                    MediaViewer(ids: start.ids, startId: start.startId)
                }
            #endif
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
                sections: feed.sections,
                items: feed.byId,
                columns: columns,
                selection: selection,
                isSelecting: isSelecting,
                showsHeaders: showsHeaders,
                services: services,
                callbacks: GridCallbacks(
                    open: { id in viewerStart = ViewerStart(ids: feed.items.map(\.fileId), startId: id) },
                    menu: { ids in menuActions(for: ids) },
                    selectionChanged: { ids in
                        selection = ids
                        #if os(macOS)
                            isSelecting = !ids.isEmpty
                        #else
                            if !ids.isEmpty { isSelecting = true }
                        #endif
                    },
                    columnsChanged: { columns = $0 }
                )
            )
            .ignoresSafeArea(edges: .bottom)
        } else if session.isSignedOut {
            SignedOutView()
        } else {
            ContentUnavailableView {
                Label(emptyTitle, systemImage: "photo.on.rectangle.angled")
            } description: {
                Text(emptyMessage)
            } actions: {
                if session.syncStatus.isWorking { ProgressView() }
            }
        }
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
        ToolbarItem(placement: .primaryAction) {
            HStack {
                accessory()
                #if !os(macOS)
                    Button(isSelecting ? String(localized: "Done", bundle: .module) : String(localized: "Select", bundle: .module)) {
                        if isSelecting { endSelection() } else { isSelecting = true }
                    }
                    .disabled(feed.items.isEmpty)
                #endif
            }
        }
        if isSelecting && !selection.isEmpty {
            ToolbarItemGroup(placement: selectionPlacement) {
                let items = selectedItems
                ShareMediaButton(items: items)
                Button {
                    Task { await session.setFavorite(items, !items.allSatisfy(\.isFavorite)) }
                } label: {
                    Label(
                        String(localized: "Favorite", bundle: .module),
                        systemImage: items.allSatisfy(\.isFavorite) ? "heart.slash" : "heart")
                }
                Menu {
                    ForEach(menuActions(for: Array(selection)), id: \.id) { action in
                        Button(role: action.isDestructive ? .destructive : nil) {
                            action.handler(Array(selection))
                        } label: {
                            Label(action.title, systemImage: action.systemImage)
                        }
                    }
                } label: {
                    Label(String(localized: "More", bundle: .module), systemImage: "ellipsis.circle")
                }
                Button(role: .destructive) {
                    confirmDelete = items.filter(\.permissions.canDelete)
                } label: {
                    Label(String(localized: "Delete", bundle: .module), systemImage: "trash")
                }
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
            toggleFavorite: { Task { await session.setFavorite(items, !items.allSatisfy(\.isFavorite)) } },
            delete: { confirmDelete = items.filter(\.permissions.canDelete) },
            toggleInfo: {
                infoItem = items.first
                showingInfo.toggle()
            },
            addToAlbum: { albumPicker = PickedItems(items: items) },
            zoomIn: { columns = GridColumns.step(columns, zoomIn: true) },
            zoomOut: { columns = GridColumns.step(columns, zoomIn: false) }
        )
    }

    func endSelection() {
        isSelecting = false
        selection = []
    }

    func menuActions(for ids: [FileID]) -> [GridMenuAction] {
        guard let services = session.services, let map = try? services.library.items(ids) else { return [] }
        let items = ids.compactMap { map[$0] }
        guard !items.isEmpty else { return [] }
        var actions: [GridMenuAction] = []
        let allFavorite = items.allSatisfy(\.isFavorite)
        actions.append(
            GridMenuAction(
                id: "favorite",
                title: allFavorite
                    ? String(localized: "Remove from favorites", bundle: .module) : String(localized: "Add to favorites", bundle: .module),
                systemImage: allFavorite ? "heart.slash" : "heart"
            ) { _ in Task { await session.setFavorite(items, !allFavorite) } })
        if items.count == 1 {
            actions.append(
                GridMenuAction(id: "info", title: String(localized: "Info", bundle: .module), systemImage: "info.circle") { _ in
                    infoItem = items.first
                    showingInfo = true
                })
        }
        actions.append(
            GridMenuAction(id: "save", title: String(localized: "Save to device", bundle: .module), systemImage: "square.and.arrow.down") {
                _ in
                Task {
                    do { try await MediaExport.saveToPhotoLibrary(items, services: services) } catch {
                        actionError = error.localizedDescription
                    }
                }
            })
        if items.contains(where: { $0.isOwnStorage && !$0.isArchived && $0.permissions.canDelete }) {
            actions.append(
                GridMenuAction(id: "archive", title: String(localized: "Archive", bundle: .module), systemImage: "archivebox") { _ in
                    Task { await session.archive(items) }
                    endSelection()
                })
        }
        if items.contains(where: \.isArchived) {
            actions.append(
                GridMenuAction(id: "unarchive", title: String(localized: "Unarchive", bundle: .module), systemImage: "tray.and.arrow.up") {
                    _ in
                    Task { await session.unarchive(items) }
                    endSelection()
                })
        }
        if session.features.has(.metadataEdit), items.contains(where: \.permissions.canWrite) {
            actions.append(
                GridMenuAction(
                    id: "metadata", title: String(localized: "Edit date and location…", bundle: .module),
                    systemImage: "calendar.badge.clock"
                ) { _ in
                    metadataItems = PickedItems(items: items.filter(\.permissions.canWrite))
                })
        }
        actions += extraActions(items)
        if items.contains(where: { $0.permissions.canDelete }) {
            actions.append(
                GridMenuAction(id: "delete", title: String(localized: "Delete", bundle: .module), systemImage: "trash", isDestructive: true)
                { _ in
                    confirmDelete = items.filter(\.permissions.canDelete)
                })
        }
        return actions
    }

    @ViewBuilder var statusBanner: some View {
        if !session.failedOperations.isEmpty {
            HStack {
                Label(
                    String(localized: "\(session.failedOperations.count) changes couldn't be saved on the server.", bundle: .module),
                    systemImage: "exclamationmark.icloud")
                Spacer()
                Button(String(localized: "Retry", bundle: .module)) { Task { await session.retryFailedOperations() } }
                Button(String(localized: "Discard", bundle: .module), role: .destructive) {
                    Task { await session.discardFailedOperations() }
                }
            }
            .font(.callout)
            .padding(12)
            .background(.regularMaterial, in: .rect(cornerRadius: 12))
            .padding()
        } else if case .offline = session.syncStatus {
            Label(String(localized: "Offline – showing saved photos", bundle: .module), systemImage: "wifi.slash")
                .font(.footnote)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: .capsule)
                .padding(.bottom, 12)
        } else if case .initialSync(let count) = session.syncStatus, !feed.items.isEmpty {
            Label(String(localized: "Loading library… \(count)", bundle: .module), systemImage: "arrow.triangle.2.circlepath")
                .font(.footnote)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: .capsule)
                .padding(.bottom, 12)
        }
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
        .sheet(isPresented: $relogin) {
            LoginView(isAddingAccount: true)
        }
    }
}
