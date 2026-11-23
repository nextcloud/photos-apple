// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosStore
import SwiftUI

/// Content of one album with its actions (SPEC AL-2…AL-8, SH-1…SH-5).
struct AlbumDetailScreen: View {
    let albumId: String
    @State var album: Album
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var feed = GridFeed()
    @AppStorage("albumColumns") private var columns = GridColumns.default
    @AppStorage("albumPhotosSortOrder") private var photoOrder: AlbumPhotosSortOrder = .oldest
    @State private var sheet: Sheet?
    @State private var confirmDelete = false
    @State private var isOffline = false
    @State private var error: String?
    @State private var newName = ""
    @State private var renaming = false
    @State private var showingNotes = false
    /// Selection in the grid (reported by `MediaGridScreen`).
    @State private var gridSelection = GridSelectionState()
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(albumId: String, initial: Album) {
        self.albumId = albumId
        _album = State(initialValue: initial)
    }

    enum Sheet: String, Identifiable {
        case addPhotos, share, edit, comments
        var id: String { rawValue }
    }

    var isOwn: Bool { album.kind == .own }

    var body: some View {
        // The title is the window's (or navigation bar's) title and nothing else; place, dates and count are its subtitle.
        // The grid starts right under the toolbar like in the library: a header above it left the grid's scroll-edge blur
        // lying over the first row.
        MediaGridScreen(
            feed: feed,
            title: album.title,
            showsHeaders: false,
            emptyTitle: String(localized: "This album is empty", bundle: .module),
            emptyMessage: isOwn ? String(localized: "Add photos from your library.", bundle: .module) : "",
            columns: $columns,
            extraActions: extraActions,
            keepsTitleWhileSelecting: AlbumToolbar.keepsTitleWhileSelecting
        ) {
            albumMenu
        }
        // While selecting, the album keeps its name and the count takes the subtitle's place. visionOS has no
        // subtitle: there the count replaces the title, as on the other grid screens.
        #if !os(visionOS)
            .navigationSubtitle(gridSelection.isSelecting ? gridSelection.title : AlbumDetails.summary(of: album))
        #endif
        .onPreferenceChange(GridSelectionState.Key.self) { state in
            gridSelection = state
        }
        .task {
            guard let services = session.services else { return }
            isOffline = await session.offline?.isPinned(OfflineManager.pinId(album: album)) ?? false
            Task {
                do { try await session.refreshAlbumContent(album) } catch { self.error = error.localizedDescription }
            }
            Task {
                for try await value in services.collections.observeAlbum(id: albumId) {
                    if let value { album = value }
                }
            }
            let order = photoOrder
            feed.observe(
                {
                    let stream = services.collections.observeAlbumGrid(albumId: albumId)
                    return AsyncThrowingStream { continuation in
                        let task = Task {
                            do {
                                for try await items in stream {
                                    continuation.yield(
                                        items.sorted { order == .oldest ? $0.timestamp < $1.timestamp : $0.timestamp > $1.timestamp })
                                }
                                continuation.finish()
                            } catch { continuation.finish(throwing: error) }
                        }
                        continuation.onTermination = { _ in task.cancel() }
                    }
                }, flat: true)
        }
        .refreshable { try? await session.refreshAlbumContent(album, force: true) }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .addPhotos: PhotoPickerSheet(album: album)
            case .share: CollaboratorsSheet(album: album)
            case .edit: AlbumEditor(album: album)
            case .comments: CommentsSheet(album: album)
            }
        }
        .confirmationDialog(deleteTitle, isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(
                isOwn ? String(localized: "Delete album", bundle: .module) : String(localized: "Leave album", bundle: .module),
                role: .destructive
            ) {
                Task {
                    do {
                        try await session.deleteAlbum(album)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
            }
        } message: {
            Text(
                isOwn
                    ? String(localized: "The photos stay in your library.", bundle: .module)
                    : String(localized: "The photos you added to this album are removed from it.", bundle: .module))
        }
        .alert(String(localized: "Rename album", bundle: .module), isPresented: $renaming) {
            TextField(String(localized: "Name", bundle: .module), text: $newName)
            Button(String(localized: "Rename", bundle: .module)) {
                Task {
                    do {
                        try await session.renameAlbum(album, to: newName)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
            }
            Button(String(localized: "Cancel", bundle: .module), role: .cancel) {}
        }
        .alert(
            String(localized: "Something went wrong", bundle: .module),
            isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
        ) {
        } message: {
            Text(error ?? "")
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard isOwn else { return false }
            session.transfers.upload(urls.map { UploadSource(file: $0, isTemporary: false) }, album: album)
            return true
        }
    }

    var deleteTitle: String {
        isOwn
            ? String(localized: "Delete “\(album.title)”?", bundle: .module) : String(localized: "Leave “\(album.title)”?", bundle: .module)
    }

    var toolbarLayout: AlbumToolbar.Layout {
        AlbumToolbar.layout(isCompact: sizeClass == .compact, isSelecting: gridSelection.isSelecting)
    }

    /// The album's toolbar items. Regular width: buttons and the options menu. Compact width (iPhone, a narrow iPad
    /// window): one menu, so the bar does not truncate. While selecting, the options menu makes way for the
    /// selection's own "More" menu (on the Mac it stays and has its own symbol).
    @ViewBuilder var albumMenu: some View {
        switch toolbarLayout {
        case .hidden:
            EmptyView()
        case .singleMenu:
            Menu {
                if AlbumDetails.hasNotes(album, isOffline: isOffline) { aboutButton }
                if isOwn {
                    addPhotosButton
                    shareAlbumButton
                }
                Divider()
                optionsItems
            } label: {
                Label(String(localized: "Album options", bundle: .module), systemImage: AlbumToolbar.optionsSymbol)
            }
            .popover(isPresented: $showingNotes) {
                AlbumNotes(album: album, isOffline: isOffline)
            }
        case .buttons(let showsOptions):
            if AlbumDetails.hasNotes(album, isOffline: isOffline) {
                // Description, collaborators and offline state: in a popover, so nothing sits between the toolbar and the grid.
                aboutButton
                    .help(String(localized: "About this album", bundle: .module))
                    .popover(isPresented: $showingNotes) {
                        AlbumNotes(album: album, isOffline: isOffline)
                    }
            }
            if isOwn {
                addPhotosButton
                    .help(String(localized: "Add photos", bundle: .module))
                shareAlbumButton
                    .help(String(localized: "Share album", bundle: .module))
            }
            if showsOptions {
                Menu {
                    optionsItems
                } label: {
                    Label(String(localized: "Album options", bundle: .module), systemImage: AlbumToolbar.optionsSymbol)
                }
                .help(String(localized: "Album options", bundle: .module))
            }
        }
    }

    var aboutButton: some View {
        Button {
            showingNotes = true
        } label: {
            Label(String(localized: "About this album", bundle: .module), systemImage: "info.circle")
        }
    }

    var addPhotosButton: some View {
        Button {
            sheet = .addPhotos
        } label: {
            Label(String(localized: "Add photos", bundle: .module), systemImage: "plus")
        }
    }

    var shareAlbumButton: some View {
        Button {
            sheet = .share
        } label: {
            Label(String(localized: "Share album", bundle: .module), systemImage: "person.crop.circle.badge.plus")
        }
    }

    @ViewBuilder var optionsItems: some View {
        if let link = session.publicLink(of: album) {
            ShareLink(item: link) { Label(String(localized: "Share link", bundle: .module), systemImage: "link") }
        }
        if session.features.has(.albumComments) && album.serverAlbumId != nil {
            Button {
                sheet = .comments
            } label: {
                Label(String(localized: "Comments", bundle: .module), systemImage: "bubble.left.and.bubble.right")
            }
        }
        Picker(String(localized: "Order", bundle: .module), selection: $photoOrder) {
            Text("Oldest first", bundle: .module).tag(AlbumPhotosSortOrder.oldest)
            Text("Newest first", bundle: .module).tag(AlbumPhotosSortOrder.newest)
        }
        Button {
            Task {
                if isOffline {
                    try? await session.offline?.unpin(album: album)
                } else {
                    try? await session.offline?.pin(album: album)
                }
                isOffline = await session.offline?.isPinned(OfflineManager.pinId(album: album)) ?? false
            }
        } label: {
            Label(
                isOffline
                    ? String(localized: "Remove offline copy", bundle: .module)
                    : String(localized: "Make available offline", bundle: .module),
                systemImage: isOffline ? "icloud.slash" : "arrow.down.circle")
        }
        if isOwn {
            Divider()
            Button {
                sheet = .edit
            } label: {
                Label(String(localized: "Edit details", bundle: .module), systemImage: "pencil")
            }
            Button {
                newName = album.name
                renaming = true
            } label: {
                Label(String(localized: "Rename", bundle: .module), systemImage: "character.cursor.ibeam")
            }
        }
        Divider()
        Button(role: .destructive) {
            confirmDelete = true
        } label: {
            Label(
                isOwn ? String(localized: "Delete album", bundle: .module) : String(localized: "Leave album", bundle: .module),
                systemImage: isOwn ? "trash" : "rectangle.portrait.and.arrow.right")
        }
    }

    func extraActions(_ items: [MediaItem]) -> [GridMenuAction] {
        var actions: [GridMenuAction] = []
        let removable = (try? session.services?.collections.albumItems(albumId: albumId))?.filter(\.isRemovable).map(\.fileId) ?? []
        if items.contains(where: { removable.contains($0.fileId) }) {
            actions.append(
                GridMenuAction(
                    id: "removeFromAlbum",
                    title: PlatformWording.title(
                        mac: LocalizedStringResource("Remove from Album", bundle: .module),
                        other: LocalizedStringResource("Remove from album", bundle: .module)),
                    systemImage: "rectangle.stack.badge.minus"
                ) { _ in
                    Task { await session.removeFromAlbum(items, album: album) }
                })
        }
        if isOwn, items.count == 1, session.features.has(.albumCover), let item = items.first {
            actions.append(
                GridMenuAction(
                    id: "cover",
                    title: PlatformWording.title(
                        mac: LocalizedStringResource("Make Album Cover", bundle: .module),
                        other: LocalizedStringResource("Make album cover", bundle: .module)),
                    systemImage: "photo.artframe"
                ) { _ in
                    Task {
                        do { try await session.updateAlbum(album, cover: item.fileId) } catch { self.error = error.localizedDescription }
                    }
                })
        }
        return actions
    }
}

/// How the album's actions share the toolbar with the grid's selection actions.
enum AlbumToolbar {
    enum Layout: Equatable {
        /// About, Add photos and Share album as buttons, the rest in the options menu (if shown).
        case buttons(showsOptions: Bool)
        /// Everything in one menu.
        case singleMenu
        /// No album actions.
        case hidden
    }

    /// The Mac selects with a plain click and its toolbar has room: the album's actions stay, and the options menu
    /// differs from the selection's "More" menu by its symbol. Elsewhere selecting is a mode: the options menu goes
    /// (at compact width that is the one menu holding everything), and "More" is the only "…".
    static func layout(isCompact: Bool, isSelecting: Bool, isMac: Bool = AlbumToolbar.isMac) -> Layout {
        if isMac { return .buttons(showsOptions: true) }
        if isCompact { return isSelecting ? .hidden : .singleMenu }
        return .buttons(showsOptions: !isSelecting)
    }

    static var isMac: Bool {
        #if os(macOS)
            true
        #else
            false
        #endif
    }

    /// The selection's "More" menu is `ellipsis.circle`; on the Mac both menus can be in the toolbar at once.
    static var optionsSymbol: String { isMac ? "rectangle.stack" : "ellipsis.circle" }

    /// Whether the album's title stays while selecting (the count is the subtitle then); visionOS has no subtitle.
    static var keepsTitleWhileSelecting: Bool {
        #if os(visionOS)
            false
        #else
            true
        #endif
    }
}

/// Texts about an album shown around its grid.
enum AlbumDetails {
    /// Place, dates, count and owner in one line (the subtitle under the album's title).
    static func summary(of album: Album) -> String {
        let details: [String?] = [
            album.location.isEmpty ? nil : album.location,
            album.dateStart.map { DateRangeLabel.string(from: $0, to: album.dateEnd ?? $0) },
            String(localized: "\(album.itemCount) items", bundle: .module),
            album.kind == .shared
                ? (album.ownerDisplayName ?? album.ownerId).map { String(localized: "Shared by \($0)", bundle: .module) } : nil,
        ]
        return details.compactMap { $0 }.joined(separator: " · ")
    }

    static func hasNotes(_ album: Album, isOffline: Bool) -> Bool {
        !album.albumDescription.isEmpty || !album.collaborators.isEmpty || isOffline
    }
}

/// Description, collaborators and offline state of an album (the "About this album" popover).
struct AlbumNotes: View {
    let album: Album
    let isOffline: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !album.albumDescription.isEmpty {
                Text(album.albumDescription).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                if !album.collaborators.isEmpty {
                    Label(album.collaborators.map(\.label).joined(separator: ", "), systemImage: "person.2")
                }
                if isOffline {
                    Label(String(localized: "Available offline", bundle: .module), systemImage: "arrow.down.circle.fill")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .frame(minWidth: 240, maxWidth: 360, alignment: .leading)
        .padding()
        .presentationCompactAdaptation(.popover)
    }
}

/// Create or edit an album (name, location, description).
struct AlbumEditor: View {
    let album: Album?
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var location = ""
    @State private var description = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if album == nil {
                    TextField(String(localized: "Name", bundle: .module), text: $name)
                }
                TextField(String(localized: "Location", bundle: .module), text: $location)
                if session.features.has(.albumDescription) {
                    TextField(String(localized: "Description", bundle: .module), text: $description, axis: .vertical)
                        .lineLimit(3...8)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .navigationTitle(
                album == nil ? String(localized: "New album", bundle: .module) : String(localized: "Edit album", bundle: .module)
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", bundle: .module)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(album == nil ? String(localized: "Create", bundle: .module) : String(localized: "Save", bundle: .module)) {
                        save()
                    }
                    .disabled((album == nil && name.trimmingCharacters(in: .whitespaces).isEmpty) || saving)
                }
            }
        }
        .frame(minWidth: 380, minHeight: 300)
        .onAppear {
            location = album?.location ?? ""
            description = album?.albumDescription ?? ""
        }
    }

    func save() {
        saving = true
        Task {
            defer { saving = false }
            do {
                if let album {
                    try await session.updateAlbum(album, location: location, description: description)
                } else {
                    try await session.createAlbum(name: name, location: location, description: description)
                }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
