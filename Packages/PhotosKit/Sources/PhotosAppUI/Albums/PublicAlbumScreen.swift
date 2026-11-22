// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosMedia
import PhotosModel
import PhotosNetworking
import SwiftUI

/// Asks for a public album link and opens it (SPEC SH-6).
struct OpenPublicLinkSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var opened: PublicLink?

    struct PublicLink: Hashable, Identifiable {
        var id: String { token }
        var serverURL: URL
        var token: String
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(String(localized: "https://cloud.example.com/apps/photos/public/…", bundle: .module), text: $link)
                    .autocorrectionDisabled()
                Text("Public album links can be opened without an account.", bundle: .module).font(.footnote).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .navigationTitle(String(localized: "Open public link", bundle: .module))
            .navigationDestination(item: $opened) { link in PublicAlbumScreen(serverURL: link.serverURL, token: link.token) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", bundle: .module)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Open", bundle: .module)) {
                        if let parsed = PublicAlbumAPI.parse(link: link) {
                            opened = PublicLink(serverURL: parsed.serverURL, token: parsed.token)
                        }
                    }
                    .disabled(PublicAlbumAPI.parse(link: link) == nil)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 600)
    }
}

/// Read-only view of a public album, without account credentials.
struct PublicAlbumScreen: View {
    let serverURL: URL
    let token: String
    @Environment(AppModel.self) private var app
    @State private var album: Album?
    @State private var children: [MediaParser.CollectionChild] = []
    @State private var error: String?
    @State private var viewing: Viewing?

    struct Viewing: Identifiable {
        var id: FileID
    }

    var api: PublicAlbumAPI { PublicAlbumAPI(http: app.http, serverURL: serverURL, token: token, userAgent: app.userAgent) }

    var body: some View {
        ScrollView {
            if let album {
                VStack(alignment: .leading, spacing: 4) {
                    Text(album.title).font(.largeTitle.bold())
                    if !album.albumDescription.isEmpty { Text(album.albumDescription) }
                    Text("\(children.count) items", bundle: .module).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 2)], spacing: 2) {
                ForEach(children, id: \.item.fileId) { child in
                    PublicPreview(api: api, fileId: child.item.fileId, size: 256, blurhash: child.item.blurhash)
                        .aspectRatio(1, contentMode: .fill)
                        .clipped()
                        .contentShape(.rect)
                        .onTapGesture { viewing = Viewing(id: child.item.fileId) }
                }
            }
            if let error {
                ContentUnavailableView(
                    String(localized: "Link not available", bundle: .module), systemImage: "link", description: Text(error))
            }
        }
        .navigationTitle(album?.title ?? "")
        .task {
            do {
                album = try await api.album()
                children = try await api.content()
            } catch {
                self.error = error.localizedDescription
            }
        }
        .sheet(item: $viewing) { viewing in
            PublicViewer(api: api, ids: children.map(\.item.fileId), start: viewing.id)
        }
    }
}

/// Preview through `publicPreview`.
struct PublicPreview: View {
    let api: PublicAlbumAPI
    let fileId: FileID
    let size: Int
    var blurhash: String?
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.12)
            if let shown = image ?? BlurHashCache.image(blurhash) {
                Image(decorative: shown, scale: 1).resizable().scaledToFill()
            }
        }
        .task(id: fileId) {
            if let data = try? await api.preview(fileId: fileId, size: size) {
                image = ImageDecoding.decode(data: data, maxPixelSize: size)
            }
        }
    }
}

/// Simple pager and slideshow-free viewer for public albums.
struct PublicViewer: View {
    let api: PublicAlbumAPI
    let ids: [FileID]
    let start: FileID
    @Environment(\.dismiss) private var dismiss
    @State private var current: FileID?

    var body: some View {
        NavigationStack {
            TabView(selection: $current) {
                ForEach(ids, id: \.self) { id in
                    PublicFullImage(api: api, fileId: id).tag(Optional(id))
                }
            }
            #if os(iOS)
                .tabViewStyle(.page(indexDisplayMode: .never))
            #endif
            .background(Color.black)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done", bundle: .module)) { dismiss() }
                }
            }
        }
        .onAppear { current = start }
        .frame(minWidth: 700, minHeight: 500)
    }
}

struct PublicFullImage: View {
    let api: PublicAlbumAPI
    let fileId: FileID
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            if let data = try? await api.preview(fileId: fileId, size: 1024) {
                image = ImageDecoding.decode(data: data, maxPixelSize: 1024)
            }
            if let data = try? await api.preview(fileId: fileId, size: 4096) {
                image = ImageDecoding.decode(data: data, maxPixelSize: 4096)
            }
        }
    }
}
