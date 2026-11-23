// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosMedia
import PhotosModel
import PhotosStore
import SwiftUI

/// Own albums or albums shared with the user (SPEC AL-1, SH-3).
struct AlbumsScreen: View {
    let kind: AlbumKind
    @Environment(SessionModel.self) private var session
    @State private var albums: [Album] = []
    @State private var loaded = false
    @State private var creating = false
    @State private var openingLink = false
    @State private var error: String?
    @AppStorage("albumsSortOrder") private var sortOrder: AlbumSortOrder = .recent

    var title: String {
        kind == .shared ? String(localized: "Shared albums", bundle: .module) : String(localized: "Albums", bundle: .module)
    }

    var sorted: [Album] {
        switch sortOrder {
        case .name: albums.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .date: albums.sorted { ($0.dateEnd ?? .distantPast) > ($1.dateEnd ?? .distantPast) }
        case .recent:
            albums.sorted { ($0.lastModified ?? $0.dateEnd ?? .distantPast) > ($1.lastModified ?? $1.dateEnd ?? .distantPast) }
        }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 16)], spacing: 20) {
                ForEach(sorted) { album in
                    // By value: the stack's path (MainView) knows which album is open.
                    NavigationLink(value: AppRoute.album(id: album.id)) {
                        AlbumCard(album: album)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        // An overlay, not scroll content: the empty state is centred like on the other screens.
        .overlay {
            if albums.isEmpty && loaded {
                ContentUnavailableView {
                    Label(
                        kind == .shared
                            ? String(localized: "No shared albums", bundle: .module) : String(localized: "No albums yet", bundle: .module),
                        systemImage: "rectangle.stack")
                } description: {
                    Text(
                        kind == .shared
                            ? String(localized: "Albums that others share with you appear here.", bundle: .module)
                            : String(localized: "Collect photos in albums and share them with others.", bundle: .module))
                } actions: {
                    if kind == .own {
                        Button(String(localized: "Create album", bundle: .module)) { creating = true }.buttonStyle(.borderedProminent)
                    }
                }
            } else if !loaded {
                ProgressView()
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Picker(String(localized: "Sort by", bundle: .module), selection: $sortOrder) {
                        Text("Recently changed", bundle: .module).tag(AlbumSortOrder.recent)
                        Text("Name", bundle: .module).tag(AlbumSortOrder.name)
                        Text("Date of photos", bundle: .module).tag(AlbumSortOrder.date)
                    }
                } label: {
                    Label(String(localized: "Sort", bundle: .module), systemImage: "arrow.up.arrow.down")
                }
                .help(String(localized: "Sort", bundle: .module))
                if kind == .shared {
                    Button {
                        openingLink = true
                    } label: {
                        Label(String(localized: "Open public link", bundle: .module), systemImage: "link")
                    }
                    .help(String(localized: "Open public link", bundle: .module))
                }
                if kind == .own {
                    Button {
                        creating = true
                    } label: {
                        Label(String(localized: "New album", bundle: .module), systemImage: "plus")
                    }
                    .help(String(localized: "New album", bundle: .module))
                }
            }
        }
        .refreshable { await refresh(force: true) }
        .task {
            guard let services = session.services else { return }
            Task { await refresh(force: false) }
            do {
                for try await value in services.collections.observeAlbums(kind) {
                    albums = value
                    loaded = true
                }
            } catch {}
        }
        .sheet(isPresented: $creating) { AlbumEditor(album: nil) }
        .sheet(isPresented: $openingLink) { OpenPublicLinkSheet() }
        .alert(
            String(localized: "Couldn't load albums", bundle: .module),
            isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
        ) {
        } message: {
            Text(error ?? "")
        }
    }

    func refresh(force: Bool) async {
        do {
            try await session.refreshAlbums(force: force)
        } catch {
            if albums.isEmpty { self.error = error.localizedDescription }
        }
        loaded = true
    }
}

/// Cover, title and count of an album.
struct AlbumCard: View {
    let album: Album

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The placeholder stays behind the cover: an album without photos, or whose cover has no preview, is not blank.
            ZStack {
                Color.secondary.opacity(0.15)
                Image(systemName: "photo.on.rectangle").font(.largeTitle).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                if let cover = album.displayCoverFileId {
                    AlbumCover(fileId: cover)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(.rect(cornerRadius: Design.coverCornerRadius))
            .overlay(alignment: .topTrailing) {
                if album.publicLink != nil || !album.collaborators.isEmpty {
                    Image(systemName: album.publicLink != nil ? "link" : "person.2.fill")
                        .font(.caption)
                        .padding(6)
                        .background(.ultraThinMaterial, in: .circle)
                        .padding(6)
                }
            }
            Text(album.title).font(.headline).lineLimit(1)
            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    var subtitle: String {
        var parts = [String(localized: "\(album.itemCount) items", bundle: .module)]
        if let owner = album.ownerDisplayName ?? album.ownerId, album.kind == .shared { parts.append(owner) }
        if !album.location.isEmpty { parts.append(album.location) }
        return parts.joined(separator: " · ")
    }
}

/// An album's cover photo; draws nothing until the preview is there, so the card's placeholder shows through.
struct AlbumCover: View {
    let fileId: FileID
    @Environment(SessionModel.self) private var session
    @State private var image: CGImage?

    var body: some View {
        GeometryReader { proxy in
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            }
        }
        .task(id: fileId) {
            guard let services = session.services else { return }
            let request = ImagePipeline.Request(
                fileId: fileId, etag: "", bucket: 256, hasPreview: true, mimeType: "image/jpeg", originalURL: nil)
            if let cached = services.images.cache.bestMemoryImage(fileId: fileId, etag: "", upTo: 256) { image = cached }
            if let loaded = await services.images.preview(request) { image = loaded }
        }
    }
}

/// Opens an album by id (list, deep link, scene restoration): the album comes from the local index, after a refresh if needed.
struct AlbumRouteScreen: View {
    let albumId: String
    @Environment(SessionModel.self) private var session
    @State private var album: Album?
    @State private var missing = false

    var body: some View {
        Group {
            if let album {
                AlbumDetailScreen(albumId: albumId, initial: album)
            } else if missing {
                ContentUnavailableView(
                    String(localized: "Album not found", bundle: .module), systemImage: "rectangle.stack.badge.minus",
                    description: Text("It may have been renamed or deleted.", bundle: .module))
            } else {
                ProgressView()
            }
        }
        .task(id: albumId) {
            guard album == nil else { return }
            if let found = try? session.services?.collections.album(id: albumId) {
                album = found
                return
            }
            try? await session.refreshAlbums(force: true)
            album = try? session.services?.collections.album(id: albumId)
            missing = album == nil
        }
    }
}
