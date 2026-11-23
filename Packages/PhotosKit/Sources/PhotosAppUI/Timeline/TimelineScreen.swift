// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosModel
import PhotosStore
import SwiftUI

/// Observes a grid query from the store.
@MainActor
@Observable
final class GridFeed {
    private(set) var items: [GridMedia] = []
    private(set) var byId: [FileID: GridMedia] = [:]
    private(set) var sections: [GridSection] = []
    private(set) var loaded = false
    @ObservationIgnored private var task: Task<Void, Never>?

    func observe(_ observation: @escaping @Sendable () -> GridStream, flat: Bool) {
        task?.cancel()
        task = Task { [weak self] in
            do {
                for try await items in observation() {
                    guard let self else { return }
                    self.apply(items, flat: flat)
                }
            } catch {}
        }
    }

    func apply(_ items: [GridMedia], flat: Bool) {
        self.items = items
        byId = Dictionary(items.map { ($0.fileId, $0) }, uniquingKeysWith: { a, _ in a })
        sections = flat ? GridSectioning.flat(items) : GridSectioning.byDay(items)
        loaded = true
    }

    func cancel() { task?.cancel() }
}

typealias GridStream = AsyncThrowingStream<[GridMedia], any Error>

/// Timeline views: All media, Photos, Videos, Favorites (SPEC §7.1).
struct TimelineScreen: View {
    let filter: MediaFilter
    @Environment(SessionModel.self) private var session
    @State private var feed = GridFeed()
    @AppStorage("gridColumns") private var columns = GridColumns.default
    @State private var mediaKind: MediaFilter

    init(filter: MediaFilter) {
        self.filter = filter
        _mediaKind = State(initialValue: filter)
    }

    #if os(macOS)
        /// Zoom slider position: 0 shows the most columns, `maxZoomLevel` the fewest.
        private var maxZoomLevel: Double { Double(GridColumns.options.count - 1) }

        private var zoomLevel: Binding<Double> {
            Binding<Double>(
                get: { () -> Double in
                    let index: Int = GridColumns.options.firstIndex(of: columns) ?? 0
                    return Double(GridColumns.options.count - 1 - index)
                },
                set: { (value: Double) in
                    let level: Int = Int(value.rounded())
                    let index: Int = max(0, min(GridColumns.options.count - 1, GridColumns.options.count - 1 - level))
                    columns = GridColumns.options[index]
                }
            )
        }
    #endif

    var title: String {
        switch filter {
        case .photos: String(localized: "Photos", bundle: .module)
        case .videos: String(localized: "Videos", bundle: .module)
        case .favorites: String(localized: "Favorites", bundle: .module)
        default: String(localized: "Library", bundle: .module)
        }
    }

    var body: some View {
        MediaGridScreen(
            feed: feed,
            title: title,
            showsHeaders: true,
            emptyTitle: emptyTitle,
            emptyMessage: emptyMessage,
            columns: $columns
        ) {
            TransfersIndicator()
            UploadMenu()
            #if os(macOS)
                // Mac: zoom slider and a segmented control, like Apple Photos.
                Slider(value: zoomLevel, in: 0...maxZoomLevel) {
                    Text("Zoom", bundle: .module)
                } minimumValueLabel: {
                    Image(systemName: "square.grid.4x3.fill").imageScale(.small)
                } maximumValueLabel: {
                    Image(systemName: "square.grid.2x2.fill").imageScale(.small)
                }
                .frame(width: 140)
                .help(String(localized: "Zoom", bundle: .module))
            #endif
            if filter == .all {
                Picker(selection: $mediaKind) {
                    Text("All", bundle: .module).tag(MediaFilter.all)
                    Text("Photos", bundle: .module).tag(MediaFilter.photos)
                    Text("Videos", bundle: .module).tag(MediaFilter.videos)
                    Text("Favorites", bundle: .module).tag(MediaFilter.favorites)
                } label: {
                    Label(String(localized: "Show", bundle: .module), systemImage: "line.3.horizontal.decrease.circle")
                }
                #if os(macOS)
                    .pickerStyle(.segmented)
                    .fixedSize()
                #else
                    .pickerStyle(.menu)
                #endif
            }
        }
        .task(id: mediaKind) { observe() }
        .dropDestination(for: URL.self) { urls, _ in
            session.transfers.upload(urls.map { UploadSource(file: $0, isTemporary: false) })
            return !urls.isEmpty
        }
        .refreshable { await session.syncNow() }
    }

    func observe() {
        guard let services = session.services else { return }
        let library = services.library
        let excluded = session.excludedFolders
        let kind = mediaKind
        feed.observe({ library.observeGrid(kind, excludedFolders: excluded) }, flat: false)
    }

    var emptyTitle: String {
        if case .initialSync = session.syncStatus { return String(localized: "Loading your library…", bundle: .module) }
        switch mediaKind {
        case .favorites: return String(localized: "No favorites yet", bundle: .module)
        case .videos: return String(localized: "No videos", bundle: .module)
        default: return String(localized: "No photos yet", bundle: .module)
        }
    }

    var emptyMessage: String {
        if case .initialSync(let count) = session.syncStatus {
            return String(localized: "\(count) items found so far.", bundle: .module)
        }
        let folders = session.features.userConfig.photosSourceFolders.joined(separator: ", ")
        return String(localized: "Photos and videos in \(folders) on your Nextcloud appear here.", bundle: .module)
    }
}
