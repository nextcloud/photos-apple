// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosStore
import SwiftUI
import TVServices

/// A memory, an album or a filtered library: a header with Play and a grid of everything in it.
struct TVDestinationView: View {
    let destination: TVDestination
    @Environment(TVLibrary.self) private var library
    @Environment(TVPresenter.self) private var presenter
    @State private var items: [MediaItem] = []
    @State private var loaded = false
    @AppStorage(TVSettings.familyAlbumKey) private var familyAlbumId = ""

    static let columns = Array(repeating: GridItem(.fixed(404), spacing: 48), count: 4)

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 48) {
                header
                if loaded && items.isEmpty {
                    Text("Nothing to show here.", comment: "TV: an album or memory without photos.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else if !loaded {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 300)
                }
                LazyVGrid(columns: Self.columns, spacing: 48) {
                    ForEach(Array(items.enumerated()), id: \.element.fileId) { index, item in
                        Button {
                            presenter.viewer = TVViewerRequest(items: items, index: index)
                        } label: {
                            TVPhotoTile(item: item, size: CGSize(width: 404, height: 270))
                        }
                        .buttonStyle(.card)
                    }
                }
                .focusSection()
            }
            .padding(.vertical, 40)
        }
        .task(id: destination) { await load() }
    }

    var title: String {
        switch destination {
        case .memory(let memory): memory.title
        case .album(let album): album.title
        case .items(let title, _): title
        }
    }

    var subtitle: String? {
        switch destination {
        case .memory(let memory): Memories.dateLine(for: memory)
        case .album(let album):
            [
                album.location,
                album.dateStart.map { start in
                    DateRangeLabel.string(from: start, to: album.dateEnd ?? start, locale: .current, calendar: .current)
                },
            ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        case .items: nil
        }
    }

    var header: some View {
        HStack(alignment: .bottom, spacing: 48) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.largeTitle.bold()).lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.headline).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if items.contains(where: { $0.kind == .image }) {
                Button {
                    switch destination {
                    case .memory(let memory): presenter.slideshow = .memory(memory)
                    case .album(let album): presenter.slideshow = .album(album)
                    case .items(let title, _): presenter.slideshow = .items(title: title, items: items)
                    }
                } label: {
                    Label {
                        Text("Play Slideshow", comment: "TV: button above a memory's or album's photos.")
                    } icon: {
                        Image(systemName: "play.fill")
                    }
                }
            }
            if case .album(let album) = destination {
                Button {
                    familyAlbumId = familyAlbumId == album.id ? "" : album.id
                } label: {
                    Label {
                        if familyAlbumId == album.id {
                            Text(
                                "Family Slideshow",
                                comment: "TV: button state when the album is the family slideshow; pressing it again stops using it.")
                        } else {
                            Text("Use for Family Slideshow", comment: "TV: button that makes the album the family slideshow.")
                        }
                    } icon: {
                        Image(systemName: familyAlbumId == album.id ? "checkmark.circle.fill" : "rectangle.stack.badge.play")
                    }
                }
            }
        }
        .focusSection()
    }

    func load() async {
        switch destination {
        case .memory(let memory): items = await library.media(memory.items)
        case .album(let album): items = await library.media(of: album)
        case .items(_, let filter): items = await library.items(filter)
        }
        loaded = true
    }
}

/// All albums, the user's own and those shared with them.
struct TVAlbumsView: View {
    @Environment(TVLibrary.self) private var library

    static let columns = Array(repeating: GridItem(.fixed(400), spacing: 48), count: 4)

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 56) {
                if library.albums.isEmpty && library.sharedAlbums.isEmpty {
                    ContentUnavailableView {
                        Label {
                            Text("No Albums", comment: "TV: title when the account has no albums.")
                        } icon: {
                            Image(systemName: "rectangle.stack")
                        }
                    } description: {
                        Text("Albums you create on your other devices appear here.", comment: "TV: explanation when there are no albums.")
                    }
                    .frame(maxWidth: .infinity, minHeight: 500)
                }
                section(Text("My Albums", comment: "TV: heading of the user's own albums."), library.albums)
                section(Text("Shared with You", comment: "TV: heading of the albums others shared with the user."), library.sharedAlbums)
            }
            .padding(.vertical, 40)
        }
    }

    @ViewBuilder
    func section(_ title: Text, _ albums: [Album]) -> some View {
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: 24) {
                title.font(.title3.bold())
                LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 56) {
                    ForEach(albums) { album in TVAlbumCard(album: album) }
                }
            }
            .focusSection()
        }
    }
}

/// The account, the slideshows and signing out.
struct TVSettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(SessionModel.self) private var session
    @Environment(TVLibrary.self) private var library
    @AppStorage(TVSettings.familyAlbumKey) private var familyAlbumId = ""
    @AppStorage(TVSettings.intervalKey) private var interval = 5
    @AppStorage(TVSettings.clockKey) private var showsClock = true
    @State private var confirmsSignOut = false

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Text(session.account.displayName)
                } label: {
                    Text("Account", comment: "TV settings: label of the signed-in user's name.")
                }
                LabeledContent {
                    Text(session.account.serverURL.host() ?? session.account.serverURL.absoluteString)
                } label: {
                    Text("Server", comment: "TV settings: label of the server's host name.")
                }
                LabeledContent {
                    syncText
                } label: {
                    Text("Library", comment: "TV settings: label of the sync state.")
                }
                Button {
                    Task { await session.syncNow(forceReconcile: true) }
                } label: {
                    Text("Sync Now", comment: "TV settings: button.")
                }
            } header: {
                Text("Nextcloud", comment: "TV settings: section header of the account.")
            }
            Section {
                Picker(selection: $interval) {
                    ForEach(SlideshowPlan.intervals, id: \.self) { seconds in
                        Text("\(seconds) seconds", comment: "TV settings: time per photo in slideshows; plural variations.").tag(seconds)
                    }
                } label: {
                    Text("Time per Photo", comment: "TV settings: picker of the slideshow interval.")
                }
                Picker(selection: $familyAlbumId) {
                    Text("None", comment: "TV settings: no album chosen for the family slideshow.").tag("")
                    ForEach(library.albums + library.sharedAlbums) { album in
                        Text(album.title).tag(album.id)
                    }
                } label: {
                    Text("Family Slideshow", comment: "TV settings: picker of the album of the family slideshow.")
                }
                Toggle(isOn: $showsClock) {
                    Text("Show Time and Date", comment: "TV settings: the family slideshow shows a clock.")
                }
            } header: {
                Text("Slideshows", comment: "TV settings: section header.")
            } footer: {
                Text(
                    "The family slideshow plays the chosen album in a shuffled order for as long as you like, like a picture frame. Start it from Home.",
                    comment: "TV settings: explanation of the family slideshow.")
            }
            Section {
                Button(role: .destructive) {
                    confirmsSignOut = true
                } label: {
                    Text("Log Out", comment: "TV settings: button that removes the account from the TV.")
                }
            } footer: {
                Text(
                    "Logging out removes the TV's access to your Nextcloud and everything the app keeps on this Apple TV.",
                    comment: "TV settings: explanation under Log Out.")
            }
        }
        .frame(maxWidth: 1200)
        .confirmationDialog(
            Text(
                "Log out of \(session.account.displayName)?",
                comment: "TV settings: question before logging out; the placeholder is the user's name."),
            isPresented: $confirmsSignOut, titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                let id = session.account.id
                Task {
                    CompanionExport.clearTopShelf()
                    TVTopShelfContentProvider.topShelfContentDidChange()
                    await app.removeAccount(id)
                }
            } label: {
                Text("Log Out", comment: "TV settings: button that removes the account from the TV.")
            }
        }
    }

    @ViewBuilder var syncText: some View {
        switch session.syncStatus {
        case .idle(let date?):
            Text(
                "Up to date, \(date.formatted(.relative(presentation: .named)))",
                comment: "TV settings: last sync; the placeholder is e.g. '5 minutes ago'.")
        case .idle(nil):
            Text("Not synced yet", comment: "TV settings: no sync has finished yet.")
        case .failed(let message, _):
            Text(message)
        case .offline:
            Text("Offline", comment: "TV settings: the server cannot be reached.")
        default:
            Text("Syncing…", comment: "TV settings: a sync is running.")
        }
    }
}
