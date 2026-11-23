// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosModel
import PhotosStore
import SwiftUI

/// A grid of items from any source (place, person, tag, folder, memory, search result).
struct ItemsScreen<Accessory: View>: View {
    let title: String
    var sectioned = true
    var emptyMessage = ""
    var extraActions: ([MediaItem]) -> [GridMenuAction] = { _ in [] }
    /// Loads the items; items not in the index are stored as collection media so the viewer can show them.
    let load: @MainActor (AccountServices) async throws -> [MediaItem]
    @ViewBuilder var accessory: () -> Accessory

    @Environment(SessionModel.self) private var session
    @State private var feed = GridFeed()
    @State private var error: String?
    @AppStorage("gridColumns") private var columns = GridColumns.default

    var body: some View {
        MediaGridScreen(
            feed: feed, title: title, showsHeaders: sectioned,
            emptyTitle: error
                ?? (feed.loaded ? String(localized: "Nothing here", bundle: .module) : String(localized: "Loading…", bundle: .module)),
            emptyMessage: emptyMessage, columns: $columns, extraActions: extraActions, accessory: accessory
        )
        .task { await reload() }
        .refreshable { await reload() }
    }

    func reload() async {
        guard let services = session.services else { return }
        do {
            let items = try await load(services).filter { !$0.isLivePhotoVideo }
            feed.apply(await ItemsPreparation.prepare(items, library: services.library), flat: !sectioned)
        } catch {
            self.error = error.localizedDescription
            feed.apply([], flat: true)
        }
    }
}

enum ItemsPreparation {
    /// Stores the items for the viewer and turns them into grid rows, newest first. Off the main thread: a memory or a
    /// map area can have tens of thousands of items.
    static func prepare(_ items: [MediaItem], library: LibraryStore) async -> [GridMedia] {
        await Task.detached(priority: .userInitiated) {
            try? library.storeCollectionMedia(items)
            return items.sorted { $0.timestamp > $1.timestamp }.map(GridMedia.init)
        }.value
    }
}

extension ItemsScreen where Accessory == EmptyView {
    init(
        title: String, sectioned: Bool = true, emptyMessage: String = "",
        extraActions: @escaping ([MediaItem]) -> [GridMenuAction] = { _ in [] },
        load: @escaping @MainActor (AccountServices) async throws -> [MediaItem]
    ) {
        self.init(title: title, sectioned: sectioned, emptyMessage: emptyMessage, extraActions: extraActions, load: load) { EmptyView() }
    }
}

/// A square cover with title and count, used by places, people, tags, folders and memories.
struct CollectionTile: View {
    let title: String
    var subtitle: String?
    var coverFileId: FileID?
    var faceBox: FaceBox?
    var circular = false
    /// What the tile is, for VoiceOver ("place", "person", "tag").
    var kind: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: circular ? .center : .leading, spacing: 6) {
            Group {
                if let coverFileId {
                    FaceCroppedPreview(fileId: coverFileId, box: faceBox)
                } else {
                    ZStack {
                        Color.secondary.opacity(0.15)
                        Image(systemName: "photo").foregroundStyle(.secondary)
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(circular ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: Design.coverCornerRadius)))
            // One line in the grid; wrapped at the accessibility text sizes instead of cut off after a few letters.
            Text(title).font(.headline).lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AccessibilityText.collection(title: title, kind: kind, detail: subtitle))
    }
}

/// A preview zoomed onto a face box (margin factor 1.4, as the web app).
struct FaceCroppedPreview: View {
    let fileId: FileID
    var box: FaceBox?

    var body: some View {
        GeometryReader { proxy in
            if let box, box.width > 0, box.height > 0 {
                let side = max(box.width, box.height) * 1.4
                let scale = 1 / max(side, 0.05)
                let centerX = box.x + box.width / 2
                let centerY = box.y + box.height / 2
                PreviewImage(fileId: fileId, etag: "", bucket: 1024, contentMode: .fill)
                    .frame(width: proxy.size.width * scale, height: proxy.size.height * scale)
                    .offset(x: proxy.size.width * (0.5 - centerX * scale), y: proxy.size.height * (0.5 - centerY * scale))
            } else {
                PreviewImage(fileId: fileId, etag: "", bucket: 256)
            }
        }
        .clipped()
    }
}
