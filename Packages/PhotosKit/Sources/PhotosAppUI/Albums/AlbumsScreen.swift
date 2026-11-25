// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosMedia
import PhotosModel
import PhotosNetworking
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
    /// "Customize Cover…" or "Show to a Guest…" of an album (SPEC §16.8.2, §16.8.3).
    @State private var cardSheet: AlbumCardSheet?
    /// The album zooms out of its card (SPEC §17.4).
    @Environment(\.routeTransitionNamespace) private var transitions

    var title: String {
        kind == .shared ? String(localized: "Shared albums", bundle: .module) : String(localized: "Albums", bundle: .module)
    }

    /// "Recently changed" needs real album modification times, which only newer Photos versions report; without them
    /// the albums are sorted by the date of their photos.
    var effectiveSortOrder: AlbumSortOrder {
        sortOrder == .recent && !session.features.has(.albumLastModified) ? .date : sortOrder
    }

    var sorted: [Album] {
        switch effectiveSortOrder {
        case .name: albums.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .date: albums.sorted { ($0.dateEnd ?? .distantPast) > ($1.dateEnd ?? .distantPast) }
        case .recent:
            albums.sorted { ($0.lastModified ?? $0.dateEnd ?? .distantPast) > ($1.lastModified ?? $1.dateEnd ?? .distantPast) }
        }
    }

    var body: some View {
        ScrollView {
            AlbumActivityBanner()
            // Smart albums appear with the other albums (SPEC §16.4).
            if kind == .own { SmartAlbumsStrip() }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 16)], spacing: 20) {
                ForEach(sorted) { album in
                    // By value: the stack's path (MainView) knows which album is open.
                    NavigationLink(value: AppRoute.album(id: album.id)) {
                        AlbumCard(album: album)
                            .cardTransitionSource(id: AppRoute.album(id: album.id), in: transitions)
                    }
                    .buttonStyle(.plain)
                    .opensAlbumInWindow(album.id) {
                        // Cover and Guest Mode (SPEC §16.8.2, §16.8.3).
                        AlbumLookMenuItems(album: album, sheet: $cardSheet)
                    }
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
                // On a living wash (SPEC §17.6.1).
                .livingEmptyBackground()
            } else if !loaded {
                // The covers' shape while the albums load (SPEC §15.5: no spinners).
                SkeletonCovers().frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Picker(
                        String(localized: "Sort by", bundle: .module),
                        selection: Binding<AlbumSortOrder>(get: { effectiveSortOrder }, set: { sortOrder = $0 })
                    ) {
                        if session.features.has(.albumLastModified) {
                            Text("Recently changed", bundle: .module).tag(AlbumSortOrder.recent)
                        }
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
            // The covers chosen on the user's other devices.
            Task { await AlbumLookStore.store(for: services).refresh() }
            do {
                for try await value in services.collections.observeAlbums(kind) {
                    albums = value
                    loaded = true
                }
            } catch {}
        }
        .sheet(isPresented: $creating) { AlbumEditor(album: nil) }
        .sheet(isPresented: $openingLink) { OpenPublicLinkSheet() }
        .albumCardSheets($cardSheet)
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

/// Cover, title and count of an album: the title and count on a glass plate over the cover (SPEC §17.4), below it at
/// the accessibility text sizes. An album without a cover photo shows a gradient made from its name.
struct AlbumCard: View {
    let album: Album
    @Environment(SessionModel.self) private var session
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// A depth cover draws the title on the photo itself: the plate then only says the count.
    var showsTitleOnPlate: Bool {
        guard let services = session.services else { return true }
        let looks = AlbumLookStore.store(for: services)
        return !(looks.effect(for: album) == .depth && looks.coverFileId(for: album) != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The gradient stays behind the cover: an album without photos, or whose cover has no preview, is not blank.
            ZStack {
                AlbumGradientView(name: album.title)
                // The chosen cover and effect: still, Live Photo motion or depth (SPEC §16.8.2).
                LivingAlbumCover(album: album)
            }
            .scrollParallax()
            .aspectRatio(1, contentMode: .fit)
            .clipShape(.rect(cornerRadius: Design.coverCornerRadius))
            .overlay(alignment: .bottom) {
                if !dynamicTypeSize.isAccessibilitySize {
                    CaptionPlate(cornerRadius: Design.coverCornerRadius - 3) {
                        VStack(alignment: .leading, spacing: 1) {
                            if showsTitleOnPlate { Text(album.title).font(Typography.cardTitle).lineLimit(1) }
                            Text(subtitle).font(Typography.cardSubtitle).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .padding(6)
                }
            }
            .overlay(alignment: .topTrailing) {
                if album.publicLink != nil || !album.collaborators.isEmpty {
                    Image(systemName: album.publicLink != nil ? "link" : "person.2.fill")
                        .font(.caption)
                        .frame(width: 26, height: 26)
                        .modifier(GlassCircle())
                        .padding(6)
                }
            }
            if dynamicTypeSize.isAccessibilitySize {
                // Large text does not fit on the cover: below it, wrapped instead of cut off (SPEC §17.4, §17.5).
                Text(album.title).cardTitleStyle()
                Text(subtitle).font(Typography.cardSubtitle).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    var subtitle: String {
        var parts = [AccessibilityText.items(album.itemCount)]
        if let owner, album.kind == .shared { parts.append(owner) }
        if !album.location.isEmpty { parts.append(album.location) }
        return parts.joined(separator: " · ")
    }

    var owner: String? { album.ownerDisplayName ?? album.ownerId }

    /// "Lisbon 2025, album, 28 items, shared with a link".
    var accessibilityLabel: String {
        let sharing: AccessibilityText.Sharing =
            album.publicLink != nil ? .link : album.collaborators.isEmpty ? .none : .people
        return AccessibilityText.album(
            title: album.title, itemCount: album.itemCount, owner: album.kind == .shared ? owner : nil, location: album.location,
            sharing: sharing)
    }
}

/// An album's cover photo; draws nothing until the preview is there, so the card's placeholder shows through.
///
/// The preview is requested for the cover's size in pixels, like the grid's tiles (a 170 pt cover on a 2× screen gets the
/// 1024 preview, not the soft 256 one).
struct AlbumCover: View {
    let fileId: FileID
    @Environment(SessionModel.self) private var session
    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?
    @State private var side: Double = 0

    var bucket: Int {
        PreviewSizing.coverBucket(side: side, scale: Double(displayScale), buckets: PhotosAPI.previewBuckets)
    }

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
        .onGeometryChange(for: Double.self) { proxy in
            Double(max(proxy.size.width, proxy.size.height))
        } action: { value in
            side = value
        }
        .task(id: CoverRequest(fileId: fileId, bucket: bucket, ready: side > 0)) {
            guard side > 0, let services = session.services else { return }
            let bucket = bucket
            let pixels = PreviewSizing.neededPixels(tileSide: side, scale: Double(displayScale), aspectRatio: 4.0 / 3.0)
            let request = ImagePipeline.Request(
                fileId: fileId, etag: "", bucket: bucket, hasPreview: true, mimeType: "image/jpeg", originalURL: nil,
                maxPixelSize: PreviewSizing.decodePixels(forPixels: pixels, bucket: bucket))
            if image == nil, let cached = services.images.cache.bestMemoryImage(fileId: fileId, etag: "", upTo: bucket) { image = cached }
            if let loaded = await services.images.preview(request) { image = loaded }
        }
    }

    struct CoverRequest: Hashable {
        var fileId: FileID
        var bucket: Int
        var ready: Bool
    }
}

/// Opens an album by id (list, deep link, scene restoration): the album comes from the local index, after a refresh if needed.
struct AlbumRouteScreen: View {
    let albumId: String
    @Environment(SessionModel.self) private var session
    @State private var album: Album?
    @State private var missing = false

    var body: some View {
        // From the local index at once when it has the album: an album opened from its card zooms in with its own
        // screen, not with the placeholder of a lookup (SPEC §17.4).
        let album: Album? = album ?? (try? session.services?.collections.album(id: albumId))
        Group {
            if let album {
                AlbumDetailScreen(albumId: albumId, initial: album)
            } else if missing {
                ContentUnavailableView(
                    String(localized: "Album not found", bundle: .module), systemImage: "rectangle.stack.badge.minus",
                    description: Text("It may have been renamed or deleted.", bundle: .module))
            } else {
                GridSkeleton(zoomStep: GridColumns.default, showsHeader: false)
            }
        }
        // File ▸ Open in New Window.
        .focusedSceneValue(\.shownAlbum, album == nil ? nil : AlbumWindowValue(account: session.account.id.rawValue, albumId: albumId))
        .task(id: albumId) {
            guard self.album == nil else { return }
            if let found = try? session.services?.collections.album(id: albumId) {
                self.album = found
                return
            }
            try? await session.refreshAlbums(force: true)
            self.album = try? session.services?.collections.album(id: albumId)
            missing = self.album == nil
        }
    }
}
