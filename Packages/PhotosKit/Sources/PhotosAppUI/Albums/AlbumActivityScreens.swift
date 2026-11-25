// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosStore
import SwiftUI

/// Wording of the activity in shared albums (SPEC SH-9).
enum AlbumActivityText {
    /// "12 new photos in 2 albums" for the banner.
    static func summary(_ unseen: [AlbumActivity]) -> String {
        let photos = unseen.reduce(0) { $0 + $1.added }
        let albums = Set(unseen.map(\.albumId)).count
        if albums == 1, let only = unseen.first {
            return only.isNewAlbum
                ? String(localized: "“\(only.title)” was shared with you", bundle: .module, comment: "Activity banner; an album title")
                : String(
                    localized: "\(photos) new photos in “\(only.title)”", bundle: .module,
                    comment: "Activity banner: a count of photos and an album title")
        }
        return String(
            localized: "\(photos) new photos in \(albums) albums", bundle: .module,
            comment: "Activity banner: a count of photos, then a count of albums")
    }

    /// The detail of one entry: who shared it, or how many photos are new.
    static func detail(_ activity: AlbumActivity) -> String {
        if activity.isNewAlbum {
            if let owner = activity.ownerDisplayName {
                return String(localized: "Shared with you by \(owner)", bundle: .module, comment: "Activity entry; the owner's name")
            }
            return String(localized: "Shared with you", bundle: .module, comment: "Activity entry of an album that was newly shared")
        }
        return String(localized: "\(activity.added) new photos", bundle: .module, comment: "Activity entry: how many photos were added")
    }
}

/// "New in shared albums": a row above the albums while something is unseen; opens the activity list.
struct AlbumActivityBanner: View {
    @Environment(SessionModel.self) private var session
    @State private var unseen: [AlbumActivity] = []

    var body: some View {
        Group {
            if !unseen.isEmpty {
                NavigationLink {
                    AlbumActivityScreen()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles.rectangle.stack")
                            .font(.title2)
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("New in shared albums", bundle: .module).font(.headline)
                            Text(AlbumActivityText.summary(unseen)).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.forward").foregroundStyle(.tertiary).accessibilityHidden(true)
                    }
                    .padding(12)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
                    .contentShape(.rect)
                    .accessibilityElement(children: .combine)
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
                .padding(.top, 8)
            }
        }
        .task {
            guard let services = session.services else { return }
            do {
                for try await all in AlbumActivityStore(database: services.database).observe() {
                    unseen = all.filter { !$0.isSeen }
                }
            } catch {}
        }
    }
}

/// What is new in shared albums, newest first (SPEC SH-9). Found by comparing the albums each time the app lists them;
/// opening an album marks its entry as seen.
struct AlbumActivityScreen: View {
    /// An album zooms out of its thumbnail (SPEC §17.4).
    @Environment(\.routeTransitionNamespace) private var transitions
    @Environment(SessionModel.self) private var session
    @State private var entries: [AlbumActivity] = []
    @State private var loaded = false

    var body: some View {
        List {
            let unseen: [AlbumActivity] = entries.filter { !$0.isSeen }
            let seen: [AlbumActivity] = entries.filter(\.isSeen)
            if !unseen.isEmpty {
                Section(String(localized: "New", bundle: .module)) {
                    ForEach(unseen) { entry in row(entry) }
                }
            }
            if !seen.isEmpty {
                Section(String(localized: "Earlier", bundle: .module)) {
                    ForEach(seen) { entry in row(entry) }
                }
            }
            Section {
            } footer: {
                Text(
                    "The app looks for new photos in shared albums whenever it refreshes. To be told the moment someone adds photos, your Nextcloud server would need to send notifications for it.",
                    bundle: .module)
            }
        }
        .overlay {
            if loaded && entries.isEmpty {
                ContentUnavailableView(
                    String(localized: "Nothing new", bundle: .module), systemImage: "rectangle.stack.badge.person.crop",
                    description: Text("Photos that others add to shared albums are listed here.", bundle: .module))
            }
        }
        .navigationTitle(String(localized: "New in shared albums", bundle: .module))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(String(localized: "Mark all as seen", bundle: .module)) {
                    guard let services = session.services else { return }
                    try? AlbumActivityStore(database: services.database).markAllSeen()
                }
                .disabled(!entries.contains { !$0.isSeen })
            }
        }
        .refreshable { try? await session.refreshAlbums(force: true) }
        .task {
            guard let services = session.services else { return }
            do {
                for try await value in AlbumActivityStore(database: services.database).observe() {
                    entries = value
                    loaded = true
                }
            } catch {}
        }
    }

    func row(_ entry: AlbumActivity) -> some View {
        // By value: the stack's path (MainView) opens the album, which marks the entry as seen.
        NavigationLink(value: AppRoute.album(id: entry.albumId)) {
            HStack(spacing: 12) {
                Group {
                    if let cover = entry.coverFileId {
                        AlbumCover(fileId: cover)
                    } else {
                        Rectangle().fill(.quaternary)
                    }
                }
                .frame(width: 48, height: 48)
                .clipShape(.rect(cornerRadius: 6))
                .cardTransitionSource(id: AppRoute.album(id: entry.albumId), in: transitions, cornerRadius: 6)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title).font(.headline).lineLimit(1)
                    Text(AlbumActivityText.detail(entry)).font(.callout).foregroundStyle(.secondary)
                    Text(entry.detectedAt, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                if !entry.isSeen {
                    Circle().fill(.tint).frame(width: 8, height: 8)
                        .accessibilityLabel(Text("New", bundle: .module))
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}
