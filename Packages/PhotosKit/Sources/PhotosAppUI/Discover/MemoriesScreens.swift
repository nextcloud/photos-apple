// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import LocalAuthentication
import MapKit
import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosStore
import SwiftUI

// MARK: - Memories and On this day (SPEC §7.12)

struct MemoriesScreen: View {
    var onlyOnThisDay = false
    @Environment(SessionModel.self) private var session
    @State private var onThisDay: [Memory] = []
    @State private var trips: [Memory] = []
    @State private var recap: Memory?
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if !onThisDay.isEmpty {
                    section(String(localized: "On this day", bundle: .module), onThisDay)
                }
                if !onlyOnThisDay {
                    if let recap { section(String(localized: "Year in review", bundle: .module), [recap]) }
                    if !trips.isEmpty { section(String(localized: "Trips", bundle: .module), trips) }
                }
                if loaded && onThisDay.isEmpty && (onlyOnThisDay || (trips.isEmpty && recap == nil)) {
                    ContentUnavailableView(
                        onlyOnThisDay
                            ? String(localized: "Nothing on this day", bundle: .module)
                            : String(localized: "No memories yet", bundle: .module),
                        systemImage: "sparkles",
                        description: Text("Memories appear as your library grows.", bundle: .module))
                }
            }
            .padding()
        }
        .navigationTitle(onlyOnThisDay ? String(localized: "On this day", bundle: .module) : String(localized: "Memories", bundle: .module))
        .task {
            guard let services = session.services else { return }
            // Purpose-built queries on a database queue; the library itself never comes into memory.
            let memories = (try? await services.library.memories(onlyOnThisDay: onlyOnThisDay)) ?? MemoriesSnapshot()
            onThisDay = memories.onThisDay
            trips = memories.trips
            recap = memories.recap
            loaded = true
        }
    }

    func section(_ title: String, _ memories: [Memory]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.bold())
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 360), spacing: 16)], spacing: 16) {
                ForEach(memories) { memory in
                    NavigationLink {
                        ItemsScreen(title: memory.title, sectioned: false) { services in
                            let map = try await services.library.fetchItems(memory.items)
                            return memory.items.compactMap { map[$0] }
                        }
                    } label: {
                        MemoryCard(memory: memory)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct MemoryCard: View {
    let memory: Memory

    var body: some View {
        PreviewImage(fileId: memory.cover, etag: "", bucket: 1024)
            .aspectRatio(4 / 3, contentMode: .fit)
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(memory.title).font(.title3.bold())
                    Text((memory.start..<max(memory.end, memory.start.addingTimeInterval(1))).formatted(.interval.day().month().year()))
                        .font(.caption)
                }
                .foregroundStyle(.white)
                .shadow(radius: 4)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
            }
            .clipShape(.rect(cornerRadius: 14))
            .accessibilityElement(children: .combine)
    }
}

// MARK: - Map (SPEC MP-1)

struct MapScreen: View {
    @Environment(SessionModel.self) private var session
    /// One marker per grid cell of the visible region, aggregated by the database. The located items are never loaded.
    @State private var cells: [MapCell] = []
    @State private var region: MKCoordinateRegion?
    @State private var position: MapCameraPosition = .automatic
    @State private var selected: Selection?

    /// What the sheet lists: the items of a marker or of the visible area.
    enum Selection: Identifiable, Hashable {
        case cell(MapCell)
        case area(MapRegion, count: Int)

        var id: String {
            switch self {
            case .cell(let cell): "cell-\(cell.id)-\(cell.cover.fileId)-\(cell.count)"
            case .area(let area, let count): "area-\(area.minLatitude)-\(area.minLongitude)-\(area.maxLatitude)-\(area.maxLongitude)-\(count)"
            }
        }

        var count: Int {
            switch self {
            case .cell(let cell): cell.count
            case .area(_, let count): count
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

    /// The query for a camera region: cells of an eighth of the visible span, for the visible region and half a screen
    /// around it (so markers are there when the map is dragged a little).
    static func query(for key: RegionKey) -> (region: MapRegion, cellLatitude: Double, cellLongitude: Double) {
        let area = MapRegion(
            centerLatitude: key.latitude, centerLongitude: key.longitude, latitudeReach: key.latitudeDelta, longitudeReach: key.longitudeDelta)
        return (area, max(key.latitudeDelta / 8, 0.0001), max(key.longitudeDelta / 8, 0.0001))
    }

    var body: some View {
        Map(position: $position) {
            ForEach(cells) { cell in
                Annotation("", coordinate: CLLocationCoordinate2D(latitude: cell.latitude, longitude: cell.longitude)) {
                    Button {
                        selected = .cell(cell)
                    } label: {
                        PreviewImage(
                            fileId: cell.cover.fileId, etag: cell.cover.etag, bucket: 256, blurhash: cell.cover.blurhash,
                            hasPreview: cell.cover.hasPreview, mimeType: cell.cover.mimeType,
                            path: cell.cover.directory == "/" ? "/" + cell.cover.name : cell.cover.directory + "/" + cell.cover.name
                        )
                        .frame(width: 52, height: 52)
                        .clipShape(.rect(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white, lineWidth: 2))
                        .overlay(alignment: .topTrailing) {
                            if cell.count > 1 {
                                Text("\(cell.count)").font(.caption2.bold()).padding(4).background(.tint, in: .capsule)
                                    .foregroundStyle(.white).offset(x: 8, y: -8)
                            }
                        }
                        .shadow(radius: 3)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .onMapCameraChange(frequency: .onEnd) { context in region = context.region }
        .navigationTitle(String(localized: "Map", bundle: .module))
        .toolbar {
            Button {
                Task { await selectVisibleArea() }
            } label: {
                Label(String(localized: "Photos in this area", bundle: .module), systemImage: "square.grid.2x2")
            }
        }
        .sheet(item: $selected) { selection in
            NavigationStack {
                ItemsScreen(title: String(localized: "\(selection.count) photos", bundle: .module)) { services in
                    switch selection {
                    case .cell(let cell): try await services.library.mapItems(in: cell)
                    case .area(let area, _): try await services.library.mapItems(in: area)
                    }
                }
            }
            .frame(minWidth: 600, minHeight: 500)
        }
        .task(id: RegionKey(region)) { await loadCells() }
    }

    /// Aggregates the markers of the current region in the database, off the main thread.
    func loadCells() async {
        guard let key = RegionKey(region), let library = session.services?.library else { return }
        let query = Self.query(for: key)
        guard let loaded = try? await library.mapCells(in: query.region, cellLatitude: query.cellLatitude, cellLongitude: query.cellLongitude)
        else { return }
        // The camera has moved on; the newer region is being loaded.
        guard !Task.isCancelled else { return }
        cells = loaded
    }

    func selectVisibleArea() async {
        guard let key = RegionKey(region), let library = session.services?.library else { return }
        let area = MapRegion(
            centerLatitude: key.latitude, centerLongitude: key.longitude, latitudeReach: key.latitudeDelta / 2,
            longitudeReach: key.longitudeDelta / 2)
        guard let count = try? await library.mapItemCount(in: area) else { return }
        selected = .area(area, count: count)
    }
}

// MARK: - Archive (SPEC §7.13)

/// Archive needs authentication every time it is opened.
struct ArchiveScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var unlocked = false
    @State private var error: String?

    var body: some View {
        Group {
            if unlocked {
                TimelineScreenArchived()
            } else {
                ContentUnavailableView {
                    Label(String(localized: "Archive is locked", bundle: .module), systemImage: "lock")
                } description: {
                    Text(error ?? String(localized: "Archived photos are hidden from your library.", bundle: .module))
                } actions: {
                    Button(String(localized: "Unlock", bundle: .module)) { Task { await unlock() } }.buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle(String(localized: "Archive", bundle: .module))
        .task { await unlock() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { unlocked = false } }
        .onDisappear { unlocked = false }
    }

    func unlock() async {
        let context = LAContext()
        do {
            unlocked = try await context.evaluatePolicy(
                .deviceOwnerAuthentication, localizedReason: String(localized: "Show archived photos", bundle: .module))
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct TimelineScreenArchived: View {
    @Environment(SessionModel.self) private var session
    @State private var feed = GridFeed()
    @AppStorage("gridColumns") private var columns = GridColumns.default

    var body: some View {
        MediaGridScreen(
            feed: feed, title: String(localized: "Archive", bundle: .module), showsHeaders: true,
            emptyTitle: String(localized: "The archive is empty", bundle: .module),
            emptyMessage: String(
                localized: "Archived photos are moved to the .archive folder and hidden everywhere else.", bundle: .module),
            columns: $columns
        ) { EmptyView() }
        .task {
            guard let library = session.services?.library else { return }
            feed.observe({ library.observeGrid(.archived) }, flat: false)
        }
    }
}

// MARK: - App lock (SPEC §8)

/// Covers the app when it is locked or in the app switcher.
struct AppLockGate<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @AppStorage("appLockEnabled") private var enabled = false
    @AppStorage("appLockTimeout") private var timeout = 60.0
    @Environment(\.scenePhase) private var scenePhase
    @State private var locked = UserDefaults.standard.bool(forKey: "appLockEnabled")
    @State private var backgroundedAt: Date?

    var body: some View {
        ZStack {
            content()
            if enabled && (locked || scenePhase != .active) {
                ZStack {
                    Rectangle().fill(.regularMaterial).ignoresSafeArea()
                    VStack(spacing: 16) {
                        NextcloudLogo().frame(width: 120, height: 60)
                        if locked {
                            Button(String(localized: "Unlock Nextcloud Photos", bundle: .module)) { Task { await unlock() } }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: backgroundedAt = Date()
            case .active:
                if enabled, let date = backgroundedAt, Date().timeIntervalSince(date) >= timeout { locked = true }
                if locked { Task { await unlock() } }
            default: break
            }
        }
        .task { if enabled && locked { await unlock() } }
    }

    func unlock() async {
        let context = LAContext()
        if (try? await context.evaluatePolicy(
            .deviceOwnerAuthentication, localizedReason: String(localized: "Unlock Nextcloud Photos", bundle: .module)))
            == true
        {
            locked = false
        }
    }
}
