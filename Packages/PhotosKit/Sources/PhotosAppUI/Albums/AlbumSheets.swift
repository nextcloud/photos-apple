// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreImage.CIFilterBuiltins
import PhotosCore
import PhotosModel
import PhotosNetworking
import PhotosStore
import SwiftUI

/// Pick own photos from the library to add to an album (SPEC AL-4).
///
/// The library's own grid in selection mode: day headers, zoom, the date scrubber on the Mac, drag and ⇧/⌘ selection
/// (two-finger drag on iPhone and iPad), with a search field that narrows the library down. What was picked stays
/// picked while the search changes.
struct PhotoPickerSheet: View {
    let album: Album
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var feed = GridFeed()
    /// Own photos that are not in the album yet, newest first; nil while they are read.
    @State private var candidates: [GridMedia]?
    @State private var picked: Set<FileID> = []
    @State private var query = ""
    @State private var columns = GridColumns.default
    @State private var adding = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                #if os(macOS)
                    // A sheet on the Mac: title and search field share one row above the grid (a navigation title
                    // and `.searchable` take two).
                    HStack(spacing: 12) {
                        Text(title).font(.headline).lineLimit(1)
                        Spacer(minLength: 12)
                        TextField(searchPrompt, text: $query)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 260)
                            .accessibilityLabel(Text("Search", bundle: .module))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    Divider()
                #endif
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                bottomBar
            }
            .selectionHaptic(picked, isActive: true)
            #if os(iOS)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text(searchPrompt))
            #elseif os(visionOS)
                .navigationTitle(title)
                .searchable(text: $query, prompt: Text(searchPrompt))
            #endif
            #if !os(macOS)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { cancelButton }
                    ToolbarItem(placement: .confirmationAction) { addButton }
                }
            #endif
            .task { await load() }
            .task(id: query) { await applyFilter() }
            .onChange(of: columns, initial: true) { _, step in feed.setZoom(step: step) }
        }
        .frame(minWidth: 720, minHeight: 620)
    }

    var title: String { String(localized: "Add to “\(album.title)”", bundle: .module) }

    var searchPrompt: String { String(localized: "Search name, place or folder", bundle: .module) }

    @ViewBuilder var content: some View {
        if let services = session.services, !feed.items.isEmpty {
            PhotoGrid(
                update: feed.update,
                zoomStep: feed.zoomStep,
                selection: PhotoPicker.shownSelection(picked: picked, isShown: { feed.model[$0] != nil }),
                isSelecting: true,
                showsHeaders: true,
                services: services,
                callbacks: GridCallbacks(
                    // Return, Space or a double click on the Mac: the tile is selected by then, nothing to open.
                    open: { _ in },
                    menu: { _ in [] },
                    selectionChanged: { ids in
                        picked = PhotoPicker.merged(picked: picked, isShown: { feed.model[$0] != nil }, gridSelection: ids)
                    },
                    columnsChanged: { columns = $0 }
                )
            )
        } else if candidates == nil {
            ProgressView()
        } else if candidates?.isEmpty == true {
            ContentUnavailableView(
                String(localized: "No photos to add", bundle: .module), systemImage: "photo.on.rectangle.angled",
                description: Text("All your own photos are in this album already.", bundle: .module))
        } else {
            ContentUnavailableView.search(text: query)
        }
    }

    /// The count of picked photos, always visible; on the Mac also the sheet's buttons.
    var bottomBar: some View {
        HStack(spacing: 12) {
            Text(
                picked.isEmpty
                    ? String(localized: "Select photos to add", bundle: .module)
                    : String(localized: "\(picked.count) selected", bundle: .module)
            )
            .font(.callout)
            .foregroundStyle(picked.isEmpty ? .secondary : .primary)
            .monospacedDigit()
            if !picked.isEmpty {
                Button(String(localized: "Deselect all", bundle: .module)) { picked = [] }
                    .buttonStyle(.borderless)
            }
            Spacer()
            #if os(macOS)
                cancelButton.keyboardShortcut(.cancelAction)
                addButton.keyboardShortcut(.defaultAction)
            #endif
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }

    var cancelButton: some View {
        Button(String(localized: "Cancel", bundle: .module)) { dismiss() }
    }

    var addButton: some View {
        Button(String(localized: "Add \(picked.count)", bundle: .module)) { add() }
            .disabled(picked.isEmpty || adding)
    }

    func add() {
        adding = true
        Task {
            if let services = session.services, let map = try? await services.library.fetchItems(Array(picked)) {
                await session.addToAlbum(Array(map.values), album: album)
            }
            dismiss()
        }
    }

    func load() async {
        guard let services = session.services else { return }
        let existing = Set(((try? services.collections.albumItems(albumId: album.id)) ?? []).map(\.fileId))
        // Only own files can be added to albums (the server refuses others).
        // Read off the main thread: this is the whole timeline, 100 000 rows in a large library.
        let all = (try? await services.library.fetchGridItems(.all, excludedFolders: session.excludedFolders)) ?? []
        let own = Set(
            ((try? await services.library.fetchItems(all.map(\.fileId))) ?? [:]).values.filter(\.isOwnStorage).map(\.fileId))
        candidates = all.filter { own.contains($0.fileId) && !existing.contains($0.fileId) }
        await applyFilter(debounce: false)
    }

    /// Shows the candidates the search field leaves over (the library's local search: name, place, caption, folder).
    func applyFilter(debounce: Bool = true) async {
        guard let services = session.services, let candidates else { return }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            feed.apply(candidates, flat: false)
            return
        }
        if debounce { try? await Task.sleep(for: .milliseconds(250)) }
        guard !Task.isCancelled else { return }
        let matches = Set(((try? await services.library.search(LibrarySearch(texts: [text]))) ?? []).map(\.fileId))
        guard !Task.isCancelled else { return }
        feed.apply(PhotoPicker.filtered(candidates, matches: matches), flat: false)
    }
}

/// Selection bookkeeping of the photo picker.
enum PhotoPicker {
    /// The part of the picked photos the grid can show as selected (the rest is hidden by the search).
    static func shownSelection(picked: Set<FileID>, isShown: (FileID) -> Bool) -> Set<FileID> {
        picked.filter(isShown)
    }

    /// The grid reports the selection among the photos it shows; photos picked earlier that the search hides now
    /// stay picked.
    static func merged(picked: Set<FileID>, isShown: (FileID) -> Bool, gridSelection: Set<FileID>) -> Set<FileID> {
        picked.filter { !isShown($0) }.union(gridSelection)
    }

    static func filtered(_ candidates: [GridMedia], matches: Set<FileID>) -> [GridMedia] {
        candidates.filter { matches.contains($0.fileId) }
    }
}

/// Choose an own album (or create one) for "Add to album".
struct AlbumPickerSheet: View {
    let items: [MediaItem]
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var albums: [Album] = []
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField(String(localized: "New album", bundle: .module), text: $newName)
                        Button(String(localized: "Create", bundle: .module)) {
                            Task {
                                if let album = try? await session.createAlbum(name: newName) { await add(to: album) }
                            }
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section {
                    ForEach(albums) { album in
                        Button {
                            Task { await add(to: album) }
                        } label: {
                            HStack {
                                Group {
                                    if let cover = album.displayCoverFileId {
                                        PreviewImage(fileId: cover, etag: "", bucket: 64)
                                    } else {
                                        Color.secondary.opacity(0.15)
                                    }
                                }
                                .frame(width: 44, height: 44)
                                .clipShape(.rect(cornerRadius: 6))
                                VStack(alignment: .leading) {
                                    Text(album.title)
                                    Text(AccessibilityText.items(album.itemCount)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(AccessibilityText.album(title: album.title, itemCount: album.itemCount))
                    }
                }
                if items.contains(where: { !$0.isOwnStorage }) {
                    Text("Photos shared with you can't be added to albums; only your own photos are added.", bundle: .module)
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(String(localized: "Add to album", bundle: .module))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", bundle: .module)) { dismiss() }
                }
            }
            .task {
                try? await session.refreshAlbums()
                albums = ((try? session.services?.collections.albums(.own)) ?? []).sorted {
                    ($0.lastModified ?? .distantPast) > ($1.lastModified ?? .distantPast)
                }
            }
        }
        .frame(minWidth: 380, minHeight: 480)
    }

    func add(to album: Album) async {
        await session.addToAlbum(items, album: album)
        dismiss()
    }
}

/// Collaborators and public link of an own album (SPEC SH-1, SH-2).
struct CollaboratorsSheet: View {
    @State var album: Album
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [Sharee] = []
    @State private var working = false
    @State private var error: String?
    @State private var confirmRemove: Collaborator?

    var people: [Collaborator] { album.collaborators.filter { $0.type != .publicLink } }

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "Share with people and groups", bundle: .module)) {
                    TextField(String(localized: "Search users or groups", bundle: .module), text: $query)
                        .autocorrectionDisabled()
                    ForEach(results) { sharee in
                        Button {
                            Task { await apply(album.collaborators + [sharee.collaborator]) }
                        } label: {
                            Label(sharee.label, systemImage: sharee.isGroup ? "person.2" : "person")
                        }
                        .disabled(album.collaborators.contains { $0.id == sharee.id })
                    }
                    ForEach(people) { collaborator in
                        HStack {
                            Label(collaborator.label, systemImage: collaborator.type == .group ? "person.2.fill" : "person.fill")
                            Spacer()
                            Button(role: .destructive) {
                                confirmRemove = collaborator
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Text("Remove \(collaborator.label)", bundle: .module))
                            .help(String(localized: "Remove \(collaborator.label)", bundle: .module))
                        }
                    }
                }
                Section {
                    Toggle(
                        String(localized: "Public link", bundle: .module),
                        isOn: Binding(
                            get: { album.publicLink != nil },
                            set: { on in
                                Task {
                                    let others = album.collaborators.filter { $0.type != .publicLink }
                                    await apply(on ? others + [Collaborator(id: "", label: "Public link", type: .publicLink)] : others)
                                }
                            }))
                    if let link = session.publicLink(of: album) {
                        Text(link.absoluteString).font(.footnote).textSelection(.enabled)
                        HStack {
                            Button(String(localized: "Copy link", bundle: .module)) { Clipboard.copy(link.absoluteString) }
                            ShareLink(item: link)
                        }
                        if let qr = QRCode.image(for: link.absoluteString) {
                            Image(decorative: qr, scale: 1).interpolation(.none).resizable().frame(width: 160, height: 160)
                        }
                    }
                } footer: {
                    Text("Anyone with the link can view the photos of this album without an account.", bundle: .module)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .disabled(working)
            .navigationTitle(String(localized: "Share “\(album.title)”", bundle: .module))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done", bundle: .module)) { dismiss() }
                }
            }
            .task(id: query) {
                guard query.count >= 2, let services = session.services else {
                    results = []
                    return
                }
                try? await Task.sleep(for: .milliseconds(300))
                results = (try? await services.api.searchSharees(query)) ?? []
            }
            .confirmationDialog(
                String(localized: "Stop sharing with \(confirmRemove?.label ?? "")?", bundle: .module),
                isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }), titleVisibility: .visible
            ) {
                Button(String(localized: "Remove", bundle: .module), role: .destructive) {
                    if let removed = confirmRemove { Task { await apply(album.collaborators.filter { $0 != removed }) } }
                }
            } message: {
                Text("Photos this person added to the album are removed from it.", bundle: .module)
            }
        }
        .frame(minWidth: 420, minHeight: 520)
    }

    func apply(_ collaborators: [Collaborator]) async {
        working = true
        defer { working = false }
        do {
            album = try await session.setCollaborators(collaborators, of: album)
            query = ""
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Comments on an album (extended servers, SPEC SH-5).
struct CommentsSheet: View {
    let album: Album
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var comments: [AlbumComment] = []
    @State private var message = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                List(comments) { comment in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(comment.actorDisplayName).font(.headline)
                            Spacer()
                            if let date = comment.createdAt {
                                Text(date, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Text(comment.message)
                    }
                    .swipeActions {
                        if comment.actorId == session.account.userId {
                            Button(String(localized: "Delete", bundle: .module), role: .destructive) { delete(comment) }
                        }
                    }
                    .contextMenu {
                        if comment.actorId == session.account.userId {
                            Button(String(localized: "Delete", bundle: .module), role: .destructive) { delete(comment) }
                        }
                    }
                }
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                HStack {
                    TextField(String(localized: "Write a comment", bundle: .module), text: $message, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                    Button(String(localized: "Send", bundle: .module)) { send() }
                        .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding()
            }
            .navigationTitle(String(localized: "Comments", bundle: .module))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done", bundle: .module)) { dismiss() }
                }
            }
            .task { await load() }
        }
        .frame(minWidth: 420, minHeight: 520)
    }

    func load() async {
        guard let id = album.serverAlbumId, let services = session.services else { return }
        do {
            comments = try await services.api.comments(albumId: id)
        } catch {
            self.error = Self.message(for: error)
            // The server's Photos app no longer has album comments (downgraded): stop offering them.
            if FeatureDetector.isMissingAPI(error) { session.featureUnavailable(.albumComments) }
        }
    }

    static func message(for error: any Error) -> String {
        FeatureDetector.isMissingAPI(error)
            ? String(localized: "Comments on albums aren't available on this server.", bundle: .module) : error.localizedDescription
    }

    func send() {
        guard let id = album.serverAlbumId, let services = session.services else { return }
        let text = message
        message = ""
        Task {
            do {
                try await services.api.postComment(albumId: id, message: text)
                await load()
            } catch {
                self.error = Self.message(for: error)
                if FeatureDetector.isMissingAPI(error) { session.featureUnavailable(.albumComments) }
            }
        }
    }

    func delete(_ comment: AlbumComment) {
        guard let id = album.serverAlbumId, let services = session.services else { return }
        Task {
            try? await services.api.deleteComment(albumId: id, commentId: comment.id)
            await load()
        }
    }
}

enum Clipboard {
    @MainActor static func copy(_ string: String) {
        #if canImport(UIKit)
            UIPasteboard.general.string = string
        #else
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(string, forType: .string)
        #endif
    }
}

enum QRCode {
    static func image(for string: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
