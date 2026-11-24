// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosStore
import SwiftUI

/// Timeline views: All media, Photos, Videos, Favorites (SPEC §7.1).
struct TimelineScreen: View {
    let filter: MediaFilter
    @Environment(SessionModel.self) private var session
    @State private var feed = GridFeed()
    @AppStorage("gridColumns") private var columns = GridColumns.default
    @State private var mediaKind: MediaFilter
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage(TimelineDisplay.stackCopiesKey) private var stackCopies = true
    @AppStorage(TimelineDisplay.showsMemoriesKey) private var showsMemories = true
    /// Photos are being selected: the memories strip makes room for the grid.
    @State private var gridSelection = GridSelectionState()
    @State private var memories: [Memory] = []

    /// The memories strip is at the top of the whole library, not of a filtered one (SPEC TL-3), and not while selecting.
    var showsMemoriesStrip: Bool {
        filter == .all && mediaKind == .all && showsMemories && !gridSelection.isSelecting
    }

    /// What the grid observes: the media kind and whether copies of a photo are stacked.
    struct Query: Hashable {
        var kind: MediaFilter
        var stacksCopies: Bool
    }

    init(filter: MediaFilter) {
        self.filter = filter
        _mediaKind = State(initialValue: filter)
    }

    #if os(macOS)
        /// Zoom slider position: 0 shows the most columns, `maxZoomLevel` the fewest.
        private var maxZoomLevel: Double { Double(GridColumns.options.count - 1) }

        private func zoomButton(zoomIn: Bool) -> some View {
            let title: String =
                zoomIn ? String(localized: "Zoom In", bundle: .module) : String(localized: "Zoom Out", bundle: .module)
            let next: Int = GridColumns.step(columns, zoomIn: zoomIn)
            return Button {
                columns = next
            } label: {
                Label(title, systemImage: zoomIn ? "square.grid.2x2.fill" : "square.grid.4x3.fill")
                    .labelStyle(.iconOnly)
                    .imageScale(.small)
            }
            .buttonStyle(.borderless)
            .disabled(next == columns)
            .help(title)
        }

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
        VStack(spacing: 0) {
            if showsMemoriesStrip && !memories.isEmpty {
                MemoriesStrip(memories: memories)
            }
            grid
        }
        .task(id: MemoriesStrip.loadKey(session.syncStatus, isShown: filter == .all && showsMemories)) {
            guard filter == .all, showsMemories, let services = session.services else { return }
            if let loaded = await MemoriesStrip.load(services) { memories = loaded }
        }
        .onPreferenceChange(GridSelectionState.Key.self) { state in
            gridSelection = state
        }
        .task(id: Query(kind: mediaKind, stacksCopies: stackCopies)) { observe() }
        .dropDestination(for: URL.self) { urls, _ in
            session.transfers.upload(urls.map { UploadSource(file: $0, isTemporary: false) })
            return !urls.isEmpty
        }
        .refreshable { await session.syncNow(forceReconcile: true) }
    }

    var grid: some View {
        MediaGridScreen(
            feed: feed,
            title: title,
            showsHeaders: true,
            emptyTitle: emptyTitle,
            emptyMessage: emptyMessage,
            columns: $columns,
            waitsForFirstSync: true
        ) {
            TransfersIndicator()
            UploadMenu()
            #if os(macOS)
                // Mac: zoom slider between two buttons that step, like Apple Photos. Three toolbar items, not a slider
                // with value labels or a stack: the toolbar gives every control of an item that item's label, so the
                // end caps would both be read as "Zoom".
                zoomButton(zoomIn: false)
                Slider(value: zoomLevel, in: 0...maxZoomLevel) {
                    Text("Zoom", bundle: .module)
                }
                .frame(width: 100)
                .accessibilityLabel(Text("Zoom", bundle: .module))
                .help(String(localized: "Zoom", bundle: .module))
                zoomButton(zoomIn: true)
            #endif
            // Only where no sidebar offers Photos, Videos and Favorites (iPhone, narrow iPad windows).
            if filter == .all && TimelineToolbar.showsMediaKindPicker(sizeClass) {
                Picker(selection: $mediaKind) {
                    Text("All", bundle: .module).tag(MediaFilter.all)
                    Text("Photos", bundle: .module).tag(MediaFilter.photos)
                    Text("Videos", bundle: .module).tag(MediaFilter.videos)
                    Text("Favorites", bundle: .module).tag(MediaFilter.favorites)
                } label: {
                    Label(String(localized: "Show", bundle: .module), systemImage: "line.3.horizontal.decrease.circle")
                }
                .pickerStyle(.menu)
            }
        }
    }

    func observe() {
        guard let services = session.services else { return }
        let library = services.library
        let excluded = session.excludedFolders
        let kind = mediaKind
        // Coalesced: a running sync commits page after page; a single change (a favourite) still arrives at once.
        let query: @Sendable () -> GridStream = {
            library.observeGrid(kind, excludedFolders: excluded, coalescing: .milliseconds(300))
        }
        feed.observe(stackCopies ? TimelineStacking.stacked(query) : query, flat: false)
    }

    var emptyTitle: String {
        // While the first sync runs the grid shows a skeleton; these are for a library that could not be loaded.
        switch session.syncStatus {
        case .offline(lastSync: nil): return String(localized: "You're offline", bundle: .module)
        case .failed(_, lastSync: nil): return String(localized: "Couldn't load your library", bundle: .module)
        default: break
        }
        switch mediaKind {
        case .favorites: return String(localized: "No favorites yet", bundle: .module)
        case .videos: return String(localized: "No videos", bundle: .module)
        default: return String(localized: "No photos yet", bundle: .module)
        }
    }

    var emptyMessage: String {
        switch session.syncStatus {
        case .offline(lastSync: nil):
            return String(localized: "Your library is loaded as soon as the server can be reached.", bundle: .module)
        case .failed(let message, lastSync: nil): return message
        default: break
        }
        let folders = session.features.userConfig.photosSourceFolders.joined(separator: ", ")
        return String(localized: "Photos and videos in \(folders) on your Nextcloud appear here.", bundle: .module)
    }
}
