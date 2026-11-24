// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import MapKit
import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosStore
import SwiftUI

// MARK: - Map (SPEC MP-1)

struct MapScreen: View {
    @Environment(SessionModel.self) private var session
    /// One annotation per grid cell of the loaded region, aggregated by the database; MapKit clusters them. The located
    /// items are never loaded.
    @State private var cells: [MapCell] = []
    @State private var region: MKCoordinateRegion?
    /// Where the map opens: around all geotagged photos.
    @State private var target: MapTarget?
    @State private var selected: Selection?
    /// The months between the oldest and the newest geotagged photo.
    @State private var timeline: MapTimeline?
    @State private var showsTimeRange = false
    @State private var fromMonth = 0.0
    @State private var toMonth = 0.0

    /// What the sheet lists: the items of a marker (one cell or a cluster of them) or of the visible area.
    enum Selection: Identifiable, Hashable {
        case cells([MapCell])
        case area(MapRegion, period: Range<Date>?, count: Int)

        var id: String {
            switch self {
            case .cells(let cells): "cells-" + cells.map { "\($0.id)-\($0.cover.fileId)-\($0.count)" }.joined(separator: ",")
            case .area(let area, _, let count):
                "area-\(area.minLatitude)-\(area.minLongitude)-\(area.maxLatitude)-\(area.maxLongitude)-\(count)"
            }
        }

        var count: Int {
            switch self {
            case .cells(let cells): MapGrid.merged(cells).count
            case .area(_, _, let count): count
            }
        }
    }

    /// Identifies a region for `.task(id:)`.
    struct RegionKey: Hashable {
        var latitude: Double
        var longitude: Double
        var latitudeDelta: Double
        var longitudeDelta: Double

        init?(_ region: MKCoordinateRegion?) {
            guard let region else { return nil }
            latitude = region.center.latitude
            longitude = region.center.longitude
            latitudeDelta = region.span.latitudeDelta
            longitudeDelta = region.span.longitudeDelta
        }
    }

    /// What the markers depend on.
    struct QueryKey: Hashable {
        var region: RegionKey?
        var period: Range<Date>?
    }

    /// The time the map is filtered to; nil while the time range is hidden or covers every month.
    var period: Range<Date>? {
        guard showsTimeRange, let timeline else { return nil }
        let from = Int(fromMonth)
        let to = Int(toMonth)
        if min(from, to) == 0 && max(from, to) == timeline.months - 1 { return nil }
        return timeline.period(from: from, to: to)
    }

    var body: some View {
        ClusteredMapView(
            cells: cells, target: target, session: session, onRegionChange: { region = $0 }, onSelect: { selected = .cells($0) }
        )
        .safeAreaInset(edge: .bottom) {
            if showsTimeRange, let timeline {
                MapTimeRangePanel(timeline: timeline, from: $fromMonth, to: $toMonth)
            }
        }
        .navigationTitle(String(localized: "Map", bundle: .module))
        .toolbar { toolbar }
        .sheet(item: $selected) { selection in
            NavigationStack {
                MapItemsScreen(title: AccessibilityText.photos(selection.count), total: selection.count) { library, limit, offset in
                    switch selection {
                    case .cells(let cells): try await library.mapGridItems(in: cells, limit: limit, offset: offset)
                    case .area(let area, let period, _):
                        try await library.mapGridItems(in: area, during: period, limit: limit, offset: offset)
                    }
                }
            }
            #if os(macOS)
                // A sheet on the Mac has no size of its own; elsewhere the sheet fills the screen.
                .frame(minWidth: 600, minHeight: 500)
            #endif
        }
        .task { await loadOverview() }
        .task(id: QueryKey(region: RegionKey(region), period: period)) { await loadCells() }
    }

    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        ToolbarItem {
            Toggle(isOn: $showsTimeRange.animation()) {
                Label(Self.timeRangeTitle, systemImage: "calendar.badge.clock")
            }
            .disabled(timeline == nil)
            .help(Self.timeRangeTitle)
        }
        ToolbarItem {
            Button {
                Task { await selectVisibleArea() }
            } label: {
                Label(String(localized: "Photos in this area", bundle: .module), systemImage: "square.grid.2x2")
            }
            .help(String(localized: "Photos in this area", bundle: .module))
        }
        // The trips on a globe (SPEC §15.6): also where the server has no Places.
        ToolbarItem {
            NavigationLink {
                TravelGlobeScreen()
            } label: {
                Label(TravelWording.title, systemImage: "globe.europe.africa")
            }
            .help(TravelWording.title)
        }
    }

    static var timeRangeTitle: String {
        PlatformWording.title(
            mac: LocalizedStringResource(
                "Time Range", bundle: .module, comment: "Map toolbar: shows or hides the slider that limits the map to some months."),
            other: LocalizedStringResource(
                "Time range", bundle: .module, comment: "Map toolbar: shows or hides the slider that limits the map to some months."))
    }

    /// The months of the time slider, and the area the map opens on.
    func loadOverview() async {
        guard let library = session.services?.library, let overview = try? await library.mapOverview() else { return }
        let timeline = MapTimeline(span: overview.oldest...overview.newest)
        if timeline != self.timeline {
            self.timeline = timeline
            fromMonth = 0
            toMonth = Double(max((timeline?.months ?? 1) - 1, 0))
        }
        if target == nil { target = MapTarget(region: Self.region(around: overview.region)) }
    }

    /// A camera region that shows a rectangle of photos with some room around it.
    static func region(around area: MapRegion) -> MKCoordinateRegion {
        let latitudeDelta = min(max((area.maxLatitude - area.minLatitude) * 1.3, 0.05), 170)
        let longitudeDelta = min(max((area.maxLongitude - area.minLongitude) * 1.3, 0.05), 360)
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (area.minLatitude + area.maxLatitude) / 2, longitude: (area.minLongitude + area.maxLongitude) / 2),
            span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta))
    }

    /// Aggregates the cells of the current region in the database, off the main thread; the query also brings the
    /// covers' place names, so nothing is read per marker.
    func loadCells() async {
        guard let key = RegionKey(region), let library = session.services?.library else { return }
        let query = MapGrid.query(
            centerLatitude: key.latitude, centerLongitude: key.longitude, latitudeDelta: key.latitudeDelta,
            longitudeDelta: key.longitudeDelta)
        guard
            let loaded = try? await library.mapCells(
                in: query.region, cellLatitude: query.cellLatitude, cellLongitude: query.cellLongitude, during: period)
        else { return }
        // The camera has moved on; the newer region is being loaded.
        guard !Task.isCancelled else { return }
        if loaded != cells { cells = loaded }
    }

    func selectVisibleArea() async {
        guard let key = RegionKey(region), let library = session.services?.library else { return }
        let area = MapRegion(
            centerLatitude: key.latitude, centerLongitude: key.longitude, latitudeReach: key.latitudeDelta / 2,
            longitudeReach: key.longitudeDelta / 2)
        let period = period
        guard let count = try? await library.mapItemCount(in: area, during: period) else { return }
        selected = .area(area, period: period, count: count)
    }
}

/// The time slider of the map (SPEC MP-1): the first and the last month to show, the months between them in the title.
struct MapTimeRangePanel: View {
    let timeline: MapTimeline
    @Binding var from: Double
    @Binding var to: Double

    var last: Double { Double(timeline.months - 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(timeline.title(from: Int(from), to: Int(to)))
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Button(Self.allTimeTitle) {
                    from = 0
                    to = last
                }
                .disabled(from == 0 && to == last)
            }
            if timeline.months > 1 {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    GridRow {
                        Text("From", bundle: .module, comment: "Map time slider: the first month shown.")
                            .foregroundStyle(.secondary)
                        slider(value: $from, label: Text("From", bundle: .module, comment: "Map time slider: the first month shown."))
                            .onChange(of: from) { _, value in if value > to { to = value } }
                    }
                    GridRow {
                        Text("To", bundle: .module, comment: "Map time slider: the last month shown.")
                            .foregroundStyle(.secondary)
                        slider(value: $to, label: Text("To", bundle: .module, comment: "Map time slider: the last month shown."))
                            .onChange(of: to) { _, value in if value < from { from = value } }
                    }
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
        .padding(.horizontal)
        .padding(.bottom, 8)
        .frame(maxWidth: 640)
    }

    func slider(value: Binding<Double>, label: Text) -> some View {
        Slider(value: value, in: 0...last, step: 1) { label }
            .labelsHidden()
            .accessibilityValue(timeline.monthTitle(Int(value.wrappedValue)))
    }

    static var allTimeTitle: String {
        PlatformWording.title(
            mac: LocalizedStringResource(
                "All Time", bundle: .module, comment: "Map time slider: button that shows the photos of every month again."),
            other: LocalizedStringResource(
                "All time", bundle: .module, comment: "Map time slider: button that shows the photos of every month again."))
    }
}

/// The photos of a map marker or of the visible area, newest first. An area can hold most of the library: the grid
/// loads a page of rows from the index and offers the next one, instead of every item at once.
struct MapItemsScreen: View {
    let title: String
    /// How many items there are (the marker's or the area's count).
    let total: Int
    let load: @MainActor (LibraryStore, _ limit: Int, _ offset: Int) async throws -> [GridMedia]

    @Environment(SessionModel.self) private var session
    @State private var feed = GridFeed()
    @State private var items: [GridMedia] = []
    @State private var loading = false
    @State private var error: String?
    @AppStorage("gridColumns") private var columns = GridColumns.default

    static let pageSize = 2000

    var body: some View {
        MediaGridScreen(
            feed: feed, title: title, showsHeaders: true,
            emptyTitle: error
                ?? (feed.loaded ? String(localized: "Nothing here", bundle: .module) : String(localized: "Loading…", bundle: .module)),
            emptyMessage: "", columns: $columns
        ) {
            if items.count < total && !items.isEmpty {
                let showMore: String = PlatformWording.title(
                    mac: LocalizedStringResource("Show More", bundle: .module),
                    other: LocalizedStringResource("Show more", bundle: .module))
                Button {
                    Task { await loadMore() }
                } label: {
                    Label(showMore, systemImage: "arrow.down.circle")
                }
                .disabled(loading)
                .help(showMore)
            }
        }
        .task { await loadMore() }
    }

    func loadMore() async {
        guard !loading, let library = session.services?.library else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await load(library, Self.pageSize, items.count)
            items += page
            error = nil
            feed.apply(items, flat: false)
        } catch {
            self.error = error.localizedDescription
            feed.apply(items, flat: false)
        }
    }
}
