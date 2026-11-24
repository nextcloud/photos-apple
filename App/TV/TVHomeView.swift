// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosStore
import SwiftUI

/// Places the TV app navigates to.
enum TVDestination: Hashable {
    case memory(Memory)
    case album(Album)
    case items(title: String, filter: MediaFilter)
}

/// The TV's settings, kept in the app's own defaults.
enum TVSettings {
    /// The album of the family slideshow (`Album.id`).
    static let familyAlbumKey = "tvFamilyAlbum"
    /// Seconds per photo in slideshows (`SlideshowPlan.intervals`).
    static let intervalKey = "tvSlideshowInterval"
    /// The family slideshow shows the time and date.
    static let clockKey = "tvFamilyClock"
    /// Where the family slideshow was, and the order it follows (`FamilySlideshow`): it goes on where it stopped.
    static let familyPositionKey = "tvFamilyPosition"
    static let familySeedKey = "tvFamilySeed"

    static var interval: Int {
        let stored = UserDefaults.standard.integer(forKey: intervalKey)
        return SlideshowPlan.interval(seconds: stored == 0 ? 5 : stored)
    }
}

/// Home: tabs for the shelves, the albums and the settings.
struct TVHomeView: View {
    @State private var library: TVLibrary
    @State private var tab = Tab.home
    @State private var homePath: [TVDestination] = []
    @State private var albumsPath: [TVDestination] = []
    @State private var presenter = TVPresenter()
    @Environment(SessionModel.self) private var session
    @Environment(TVRouter.self) private var router

    enum Tab: Hashable {
        case home, albums, settings
    }

    init(session: SessionModel) {
        _library = State(initialValue: TVLibrary(session: session))
    }

    var body: some View {
        TabView(selection: $tab) {
            SwiftUI.Tab(value: Tab.home) {
                NavigationStack(path: $homePath) {
                    TVShelvesView()
                        .navigationDestination(for: TVDestination.self) { TVDestinationView(destination: $0) }
                }
            } label: {
                Text("Home", comment: "TV: tab with the memories, favourites and albums shelves.")
            }
            SwiftUI.Tab(value: Tab.albums) {
                NavigationStack(path: $albumsPath) {
                    TVAlbumsView()
                        .navigationDestination(for: TVDestination.self) { TVDestinationView(destination: $0) }
                }
            } label: {
                Text("Albums", comment: "TV: tab with all albums.")
            }
            SwiftUI.Tab(value: Tab.settings) {
                NavigationStack {
                    TVSettingsView()
                }
            } label: {
                Text("Settings", comment: "TV: tab with the account and slideshow settings.")
            }
        }
        .environment(library)
        .environment(presenter)
        .task(id: syncKey) { await library.load() }
        .onChange(of: router.pending, initial: true) { _, route in
            if route != nil { open() }
        }
        .onChange(of: library.hasLoaded) { _, loaded in
            if loaded, router.pending != nil { open() }
        }
        .fullScreenCover(item: $presenter.slideshow) { request in
            TVSlideshowView(request: request)
                .environment(session)
                .environment(library)
        }
        .fullScreenCover(item: $presenter.viewer) { request in
            TVViewer(request: request)
                .environment(session)
                .environment(library)
        }
    }

    /// Loaded again after each sync.
    var syncKey: Date? {
        if case .idle(let date) = session.syncStatus { return date }
        return nil
    }

    /// Opens the link from the Top Shelf once the library knows its memories.
    func open() {
        guard let route = router.pending, library.hasLoaded else { return }
        router.pending = nil
        switch route {
        case .memory(let id, let play):
            guard let memory = library.memories.first(where: { $0.id == id }) else { return }
            tab = .home
            if play {
                presenter.slideshow = .memory(memory)
            } else {
                homePath = [.memory(memory)]
            }
        case .album(let id, let play):
            guard let album = library.album(id: id) else { return }
            tab = .albums
            if play {
                presenter.slideshow = .album(album)
            } else {
                albumsPath = [.album(album)]
            }
        case .familySlideshow:
            if let album = UserDefaults.standard.string(forKey: TVSettings.familyAlbumKey).flatMap(library.album(id:)) {
                presenter.slideshow = .family(album)
            }
        }
    }
}

/// The full-screen pages over the tabs: the viewer and slideshows.
@MainActor
@Observable
final class TVPresenter {
    var viewer: TVViewerRequest?
    var slideshow: TVSlideshowRequest?
}

/// The home tab: the family slideshow, memories, favourites, recent photos and albums, each a row of large cards.
struct TVShelvesView: View {
    @Environment(TVPresenter.self) private var presenter
    @Environment(TVLibrary.self) private var library
    @Environment(SessionModel.self) private var session
    @AppStorage(TVSettings.familyAlbumKey) private var familyAlbumId = ""

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 56) {
                if !library.hasLoaded || isEmpty {
                    emptyState
                }
                if let family = library.album(id: familyAlbumId), !familyAlbumId.isEmpty {
                    TVFamilyBanner(album: family) { presenter.slideshow = .family(family) }
                }
                if !library.memories.isEmpty {
                    TVShelf(title: Text("Memories", comment: "TV: title of the memories shelf.")) {
                        ForEach(library.memories) { memory in
                            NavigationLink(value: TVDestination.memory(memory)) {
                                TVMemoryCard(memory: memory)
                            }
                            .buttonStyle(.card)
                            .contextMenu {
                                Button {
                                    presenter.slideshow = .memory(memory)
                                } label: {
                                    Label {
                                        Text("Play Slideshow", comment: "TV: context menu item of a memory.")
                                    } icon: {
                                        Image(systemName: "play.fill")
                                    }
                                }
                            }
                        }
                    }
                }
                if !library.favorites.isEmpty {
                    TVShelf(
                        title: Text("Favorites", comment: "TV: title of the favourites shelf."),
                        destination: .items(
                            title: String(localized: "Favorites", comment: "TV: title of the favourites screen."), filter: .favorites)
                    ) {
                        TVPhotoRow(items: library.favorites)
                    }
                }
                if !library.albums.isEmpty {
                    TVShelf(title: Text("Albums", comment: "TV: title of the shelf of the user's albums.")) {
                        ForEach(library.albums.prefix(20)) { album in TVAlbumCard(album: album) }
                    }
                }
                if !library.sharedAlbums.isEmpty {
                    TVShelf(title: Text("Shared Albums", comment: "TV: title of the shelf of albums shared with the user.")) {
                        ForEach(library.sharedAlbums.prefix(20)) { album in TVAlbumCard(album: album) }
                    }
                }
                if !library.recent.isEmpty {
                    TVShelf(
                        title: Text("Recent", comment: "TV: title of the shelf of the newest photos."),
                        destination: .items(
                            title: String(localized: "Library", comment: "TV: title of the screen with all photos."), filter: .all)
                    ) {
                        TVPhotoRow(items: library.recent)
                    }
                }
            }
            .padding(.vertical, 40)
        }
        .scrollClipDisabled()
    }

    var isEmpty: Bool {
        library.memories.isEmpty && library.favorites.isEmpty && library.albums.isEmpty && library.sharedAlbums.isEmpty
            && library.recent.isEmpty
    }

    @ViewBuilder var emptyState: some View {
        let syncing = session.syncStatus.isWorking || !library.hasLoaded
        if syncing {
            HStack(spacing: 24) {
                ProgressView()
                Text("Loading your photos…", comment: "TV: shown on the home screen while the first sync runs.")
                    .font(.title3)
            }
            .frame(maxWidth: .infinity, minHeight: 400)
        } else {
            ContentUnavailableView {
                Label {
                    Text("No Photos Yet", comment: "TV: title of the empty home screen.")
                } icon: {
                    Image(systemName: "photo.on.rectangle.angled")
                }
            } description: {
                Text(
                    "Photos and videos you add to your Nextcloud appear here.",
                    comment: "TV: explanation on the empty home screen.")
            }
            .frame(maxWidth: .infinity, minHeight: 400)
        }
    }
}

/// A titled, horizontally scrolling row of cards. Focus moves into it as a whole (`focusSection`).
struct TVShelf<Content: View>: View {
    let title: Text
    var destination: TVDestination?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                title.font(.title3.bold())
                Spacer()
                if let destination {
                    NavigationLink(value: destination) {
                        Text("Show All", comment: "TV: button at the end of a shelf title that opens all of its items.")
                            .font(.callout)
                    }
                    .buttonStyle(.borderless)
                }
            }
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 48) {
                    content()
                }
                .padding(.vertical, 24)
            }
            .scrollClipDisabled()
            .scrollIndicators(.hidden)
        }
        .focusSection()
    }
}

/// The family slideshow at the top of Home: one click starts it.
struct TVFamilyBanner: View {
    let album: Album
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            ZStack(alignment: .bottomLeading) {
                if let cover = album.displayCoverFileId {
                    TVPreview(fileId: cover, bucket: 1024, maxPixelSize: 1600)
                } else {
                    Rectangle().fill(.quaternary)
                }
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                HStack(spacing: 24) {
                    Image(systemName: "play.rectangle.fill").font(.system(size: 56))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Family Slideshow", comment: "TV: title of the banner that starts the family slideshow.")
                            .font(.title2.bold())
                        Text(album.title).font(.headline).foregroundStyle(.white.opacity(0.8))
                    }
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 10)
                .padding(40)
            }
            .frame(maxWidth: .infinity, minHeight: 420, maxHeight: 420)
        }
        .buttonStyle(.card)
        .focusSection()
    }
}

/// A row of photo cards; a click opens the viewer at that photo.
struct TVPhotoRow: View {
    let items: [MediaItem]
    @Environment(TVPresenter.self) private var presenter

    var body: some View {
        ForEach(Array(items.enumerated()), id: \.element.fileId) { index, item in
            Button {
                presenter.viewer = TVViewerRequest(items: items, index: index)
            } label: {
                TVPhotoTile(item: item, size: CGSize(width: 420, height: 280))
            }
            .buttonStyle(.card)
        }
    }
}
