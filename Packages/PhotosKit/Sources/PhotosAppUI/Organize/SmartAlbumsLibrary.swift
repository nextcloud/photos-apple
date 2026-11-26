// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosModel
import SwiftUI

/// Smart albums: the ones made with the rule builder (shared by the user's devices) and the ones the web app saved on an
/// extended server (SPEC SR-5, §16.4).
struct SmartAlbumsLibraryScreen: View {
    @Environment(SessionModel.self) private var session
    @State private var editing: EditRequest?
    @State private var deleting: SmartAlbumDefinition?
    @State private var webAlbums: [SmartAlbum] = []
    /// A smart album zooms out of its card (SPEC §17.4).
    @Namespace private var zoom

    struct EditRequest: Identifiable {
        let id = UUID()
        var album: SmartAlbumDefinition?
    }

    var albums: [SmartAlbumDefinition] {
        (session.organize?.smartAlbums ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let error = session.organize?.syncError, !albums.isEmpty {
                    Label(
                        String(
                            localized: "Showing this device's copy. Changes are shared when your Nextcloud can be reached.", bundle: .module
                        ),
                        systemImage: "icloud.slash"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .help(error)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 16)], spacing: 20) {
                    ForEach(albums) { album in
                        NavigationLink {
                            SmartAlbumScreen(albumId: album.id)
                                .cardTransitionDestination(id: album.id, in: zoom)
                        } label: {
                            SmartAlbumCard(album: album)
                                .cardTransitionSource(id: album.id, in: zoom)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(String(localized: "Edit…", bundle: .module), systemImage: "slider.horizontal.3") {
                                editing = EditRequest(album: album)
                            }
                            Button(String(localized: "Duplicate", bundle: .module), systemImage: "plus.square.on.square") {
                                let copy = SmartAlbumDefinition(
                                    name: String(localized: "\(album.name) Copy", bundle: .module), rule: album.rule, sort: album.sort,
                                    limit: album.limit)
                                Task { await session.organize?.save(copy) }
                            }
                            Divider()
                            Button(String(localized: "Delete…", bundle: .module), systemImage: "trash", role: .destructive) {
                                deleting = album
                            }
                        }
                    }
                }
                if !webAlbums.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Saved on the web", bundle: .module).font(.title3.weight(.semibold))
                        ForEach(webAlbums) { album in
                            NavigationLink {
                                ItemsScreen(title: album.name) { _ in try await SearchEvaluator.items(of: album, session: session) }
                            } label: {
                                Label(album.name, systemImage: "line.3.horizontal.decrease.circle")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding()
        }
        .overlay {
            if albums.isEmpty && webAlbums.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "No smart albums", bundle: .module), systemImage: "wand.and.stars")
                } description: {
                    Text(
                        "Describe the photos you want — people, places, ratings, cameras, dates — and the album fills itself.",
                        bundle: .module)
                } actions: {
                    Button(String(localized: "New Smart Album", bundle: .module)) { editing = EditRequest() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle(String(localized: "Smart albums", bundle: .module))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editing = EditRequest()
                } label: {
                    Label(String(localized: "New Smart Album", bundle: .module), systemImage: "plus")
                }
                .help(String(localized: "New Smart Album", bundle: .module))
            }
        }
        .sheet(item: $editing) { request in SmartAlbumBuilder(album: request.album) }
        .confirmationDialog(
            String(localized: "Delete the smart album “\(deleting?.name ?? "")”?", bundle: .module),
            isPresented: Binding(get: { deleting != nil }, set: { shown in if !shown { deleting = nil } }), titleVisibility: .visible,
            presenting: deleting
        ) { (album: SmartAlbumDefinition) in
            Button(String(localized: "Delete smart album", bundle: .module), role: .destructive) {
                Task { await session.organize?.delete(album) }
            }
            Button(String(localized: "Cancel", bundle: .module), role: .cancel) {}
        } message: { _ in
            Text("It is deleted on all your devices. Your photos are not affected.", bundle: .module)
        }
        .task {
            webAlbums = session.features.userConfig.smartAlbums ?? []
            await session.organize?.sync()
        }
        .refreshable { await session.organize?.sync(force: true) }
    }
}

/// A smart album's cover (its first photo), name and count.
struct SmartAlbumCard: View {
    let album: SmartAlbumDefinition
    var compact = false
    @Environment(SessionModel.self) private var session
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var cover: FileID?
    @State private var count: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                // A gradient from the name until the first photo is there (SPEC §17.4).
                AlbumGradientView(name: album.name)
                if let cover { AlbumCover(fileId: cover) }
            }
            .scrollParallax(compact ? .horizontal : .vertical)
            .aspectRatio(1, contentMode: .fit)
            .clipShape(.rect(cornerRadius: Design.coverCornerRadius))
            .overlay(alignment: .topLeading) {
                Image(systemName: "wand.and.stars")
                    .font(.caption.weight(.semibold))
                    .frame(width: 26, height: 26)
                    .modifier(GlassCircle())
                    .padding(6)
                    .accessibilityHidden(true)
            }
            .overlay(alignment: .bottom) {
                if !dynamicTypeSize.isAccessibilitySize {
                    CaptionPlate(cornerRadius: Design.coverCornerRadius - 3) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(album.name).font(compact ? .footnote.weight(.semibold) : .subheadline.weight(.semibold)).lineLimit(1)
                            // The text colour: the glass draws the secondary one too faint over light photos (SPEC §20.3).
                            Text(count.map(AccessibilityText.items) ?? " ").font(compact ? .caption2 : .caption).lineLimit(1)
                        }
                    }
                    .padding(compact ? 4 : 6)
                    // A narrow card in the strip: the plate keeps to the size its text fits at.
                    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                }
            }
            if dynamicTypeSize.isAccessibilitySize {
                Text(album.name).font(.headline).lineLimit(3)
                Text(count.map(AccessibilityText.items) ?? " ").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            String(localized: "\(album.name), smart album, \(count.map(AccessibilityText.items) ?? "")", bundle: .module)
        )
        .task(id: album) {
            guard let organize = session.organize, let items = try? await organize.items(of: album) else { return }
            count = items.count
            cover = items.first?.fileId
        }
    }
}

/// The photos of a smart album, with Edit in the toolbar.
struct SmartAlbumScreen: View {
    let albumId: String
    @Environment(SessionModel.self) private var session
    @State private var editing = false
    @State private var revision = 0

    var album: SmartAlbumDefinition? { session.organize?.smartAlbum(id: albumId) }

    var body: some View {
        if let album {
            ItemsScreen(title: album.name) { _ in try await session.organize?.items(of: album) ?? [] }
                .id(album)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            editing = true
                        } label: {
                            Label(String(localized: "Edit Rules", bundle: .module), systemImage: "slider.horizontal.3")
                        }
                        .help(String(localized: "Edit Rules", bundle: .module))
                    }
                }
                .sheet(isPresented: $editing) { SmartAlbumBuilder(album: album) }
        } else {
            ContentUnavailableView(
                String(localized: "This smart album was deleted", bundle: .module), systemImage: "wand.and.stars")
        }
    }
}

/// Smart albums above the albums (SPEC §16.4: they appear with the other albums).
struct SmartAlbumsStrip: View {
    @Environment(SessionModel.self) private var session
    @State private var creating = false
    /// A smart album zooms out of its card (SPEC §17.4).
    @Namespace private var zoom

    var body: some View {
        let albums: [SmartAlbumDefinition] = (session.organize?.smartAlbums ?? []).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Smart Albums", bundle: .module).font(.title3.weight(.semibold))
                    Spacer()
                    NavigationLink {
                        SmartAlbumsLibraryScreen()
                    } label: {
                        Text("See All", bundle: .module)
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(albums) { album in
                            NavigationLink {
                                SmartAlbumScreen(albumId: album.id)
                                    .cardTransitionDestination(id: album.id, in: zoom)
                            } label: {
                                SmartAlbumCard(album: album, compact: true).frame(width: 128)
                                    .cardTransitionSource(id: album.id, in: zoom)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
    }
}
