// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreImage.CIFilterBuiltins
import PhotosCore
import PhotosModel
import PhotosNetworking
import PhotosStore
import SwiftUI

/// Pick own photos from the library to add to an album (SPEC AL-4).
struct PhotoPickerSheet: View {
    let album: Album
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var items: [GridMedia] = []
    @State private var selection: Set<FileID> = []
    @State private var existing: Set<FileID> = []

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 2)], spacing: 2) {
                    ForEach(items) { item in
                        Button {
                            if selection.contains(item.fileId) { selection.remove(item.fileId) } else { selection.insert(item.fileId) }
                        } label: {
                            PreviewImage(fileId: item.fileId, etag: item.etag, bucket: 256, blurhash: item.blurhash)
                                .aspectRatio(1, contentMode: .fill)
                                .overlay(alignment: .bottomTrailing) {
                                    Image(systemName: selection.contains(item.fileId) ? "checkmark.circle.fill" : "circle")
                                        .font(.title3)
                                        .foregroundStyle(selection.contains(item.fileId) ? AnyShapeStyle(.tint) : AnyShapeStyle(.white))
                                        .shadow(radius: 2)
                                        .padding(4)
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(GridTile.accessibilityLabel(for: item))
                        .accessibilityAddTraits(selection.contains(item.fileId) ? .isSelected : [])
                    }
                }
            }
            .selectionHaptic(selection, isActive: true)
            .navigationTitle(String(localized: "Add to “\(album.title)”", bundle: .module))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", bundle: .module)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Add \(selection.count)", bundle: .module)) {
                        Task {
                            if let services = session.services, let map = try? services.library.items(Array(selection)) {
                                await session.addToAlbum(Array(map.values), album: album)
                            }
                            dismiss()
                        }
                    }
                    .disabled(selection.isEmpty)
                }
            }
            .task {
                guard let services = session.services else { return }
                existing = Set(((try? services.collections.albumItems(albumId: album.id)) ?? []).map(\.fileId))
                // Only own files can be added to albums (the server refuses others).
                // Read off the main thread: this is the whole timeline, 100 000 rows in a large library.
                let all = (try? await services.library.fetchGridItems(.all, excludedFolders: session.excludedFolders)) ?? []
                let own = Set(
                    ((try? await services.library.fetchItems(all.map(\.fileId))) ?? [:]).values.filter(\.isOwnStorage).map(\.fileId))
                items = all.filter { own.contains($0.fileId) && !existing.contains($0.fileId) }
            }
        }
        .frame(minWidth: 600, minHeight: 600)
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
