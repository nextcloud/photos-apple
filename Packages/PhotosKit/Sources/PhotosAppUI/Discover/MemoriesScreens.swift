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
            let items = (try? services.library.allVisibleItems()) ?? []
            onThisDay = Memories.onThisDay(items)
            if !onlyOnThisDay {
                trips = Memories.trips(items)
                recap = Memories.yearRecap(items)
            }
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
                            let map = try services.library.items(memory.items)
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
                    Text(DateRangeLabel.string(from: memory.start, to: memory.end))
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
    @State private var items: [MediaItem] = []
    @State private var region: MKCoordinateRegion?
    @State private var position: MapCameraPosition = .automatic
    @State private var selected: [FileID]?

    struct Cluster: Identifiable {
        var id: String
        var coordinate: CLLocationCoordinate2D
        var items: [MediaItem]
    }

    /// Grid clustering in the visible region (MapKit's own clustering needs MKMapView).
    var clusters: [Cluster] {
        guard let region else { return [] }
        let cellLat = max(region.span.latitudeDelta / 8, 0.0001)
        let cellLon = max(region.span.longitudeDelta / 8, 0.0001)
        var cells: [String: [MediaItem]] = [:]
        for item in items {
            guard let lat = item.latitude, let lon = item.longitude,
                abs(lat - region.center.latitude) <= region.span.latitudeDelta,
                abs(lon - region.center.longitude) <= region.span.longitudeDelta
            else { continue }
            cells["\(Int((lat / cellLat).rounded(.down)))-\(Int((lon / cellLon).rounded(.down)))", default: []].append(item)
        }
        return cells.map { key, members in
            Cluster(
                id: key, coordinate: CLLocationCoordinate2D(latitude: members[0].latitude!, longitude: members[0].longitude!),
                items: members)
        }
    }

    var body: some View {
        Map(position: $position) {
            ForEach(clusters) { cluster in
                Annotation("", coordinate: cluster.coordinate) {
                    Button {
                        selected = cluster.items.map(\.fileId)
                    } label: {
                        PreviewImage(item: cluster.items[0], bucket: 256)
                            .frame(width: 52, height: 52)
                            .clipShape(.rect(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white, lineWidth: 2))
                            .overlay(alignment: .topTrailing) {
                                if cluster.items.count > 1 {
                                    Text("\(cluster.items.count)").font(.caption2.bold()).padding(4).background(.tint, in: .capsule)
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
                if let region {
                    selected = items.filter { item in
                        guard let lat = item.latitude, let lon = item.longitude else { return false }
                        return abs(lat - region.center.latitude) <= region.span.latitudeDelta / 2
                            && abs(lon - region.center.longitude) <= region.span.longitudeDelta / 2
                    }.map(\.fileId)
                }
            } label: {
                Label(String(localized: "Photos in this area", bundle: .module), systemImage: "square.grid.2x2")
            }
        }
        .sheet(item: Binding(get: { selected.map { SelectedIds(ids: $0) } }, set: { selected = $0?.ids })) { selection in
            NavigationStack {
                ItemsScreen(title: String(localized: "\(selection.ids.count) photos", bundle: .module)) { services in
                    let map = try services.library.items(selection.ids)
                    return selection.ids.compactMap { map[$0] }
                }
            }
            .frame(minWidth: 600, minHeight: 500)
        }
        .task {
            items = ((try? session.services?.library.allVisibleItems()) ?? []).filter(\.hasLocation)
        }
    }

    struct SelectedIds: Identifiable {
        var id: String { ids.map(String.init).joined(separator: ",") }
        var ids: [FileID]
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
