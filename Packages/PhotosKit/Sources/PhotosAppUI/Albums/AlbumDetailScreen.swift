// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
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
        VStack(spacing: 0) {
            AlbumHeader(album: album, isOffline: isOffline)
            MediaGridScreen(
                feed: feed,
                title: album.title,
                showsHeaders: false,
                emptyTitle: String(localized: "This album is empty", bundle: .module),
                emptyMessage: isOwn ? String(localized: "Add photos from your library.", bundle: .module) : "",
                columns: $columns,
                extraActions: extraActions
            ) {
                albumMenu
            }
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

    @ViewBuilder var albumMenu: some View {
        if isOwn {
            Button {
                sheet = .addPhotos
            } label: {
                Label(String(localized: "Add photos", bundle: .module), systemImage: "plus")
            }
            Button {
                sheet = .share
            } label: {
                Label(String(localized: "Share", bundle: .module), systemImage: "person.crop.circle.badge.plus")
            }
        }
        Menu {
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
        } label: {
            Label(String(localized: "Album", bundle: .module), systemImage: "ellipsis.circle")
        }
    }

    func extraActions(_ items: [MediaItem]) -> [GridMenuAction] {
        var actions: [GridMenuAction] = []
        let removable = (try? session.services?.collections.albumItems(albumId: albumId))?.filter(\.isRemovable).map(\.fileId) ?? []
        if items.contains(where: { removable.contains($0.fileId) }) {
            actions.append(
                GridMenuAction(
                    id: "removeFromAlbum", title: String(localized: "Remove from album", bundle: .module),
                    systemImage: "rectangle.stack.badge.minus"
                ) { _ in
                    Task { await session.removeFromAlbum(items, album: album) }
                })
        }
        if isOwn, items.count == 1, session.features.has(.albumCover), let item = items.first {
            actions.append(
                GridMenuAction(id: "cover", title: String(localized: "Make album cover", bundle: .module), systemImage: "photo.artframe") {
                    _ in
                    Task {
                        do { try await session.updateAlbum(album, cover: item.fileId) } catch { self.error = error.localizedDescription }
                    }
                })
        }
        return actions
    }
}

/// Title, place, dates, description and sharing state above the album grid.
struct AlbumHeader: View {
    let album: Album
    let isOffline: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(album.title).font(.largeTitle.bold()).lineLimit(2)
                if isOffline {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.secondary)
                        .accessibilityLabel(Text("Available offline", bundle: .module))
                }
            }
            let details = [
                album.location.isEmpty ? nil : album.location,
                dateText,
                String(localized: "\(album.itemCount) items", bundle: .module),
                album.kind == .shared
                    ? (album.ownerDisplayName ?? album.ownerId).map { String(localized: "Shared by \($0)", bundle: .module) } : nil,
            ].compactMap { $0 }
            Text(details.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary)
            if !album.albumDescription.isEmpty {
                Text(album.albumDescription).font(.body).padding(.top, 4)
            }
            if !album.collaborators.isEmpty {
                Label(album.collaborators.map(\.label).joined(separator: ", "), systemImage: "person.2")
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    var dateText: String? {
        guard let start = album.dateStart else { return nil }
        let end = album.dateEnd ?? start
        return (start..<max(end, start.addingTimeInterval(1))).formatted(.interval.day().month().year())
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
