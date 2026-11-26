// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosStore
import SwiftUI

#if !os(macOS)
    import MapKit
    import UIKit
#endif

/// What the shelves of the Collections tab show, and when they are loaded again (SPEC §20.4).
enum CollectionsOverview {
    /// Loaded again after a sync and when the day changes (memories are about the day).
    struct LoadKey: Hashable {
        var lastSync: Date?
        var day: Date
        var account: String

        init(_ status: SyncStatus, account: String, now: Date = Date()) {
            if case .idle(let date) = status { lastSync = date }
            day = Calendar.current.startOfDay(for: now)
            self.account = account
        }
    }

    /// At most this many covers on a shelf: a shelf is a way in, the place has them all.
    static let shelfLimit = 12

    static func shelfPeople(_ all: [Person]) -> [Person] {
        let sorted = all.sorted { lhs, rhs in
            if lhs.isUnnamed != rhs.isUnnamed { return !lhs.isUnnamed }
            return lhs.itemCount > rhs.itemCount
        }
        return Array(sorted.prefix(shelfLimit))
    }

    /// The photos' rectangle with some room around it, at least a few degrees wide (one city would otherwise fill the
    /// card with streets).
    static func paddedRegion(_ region: MapRegion) -> MapRegion {
        let latitudeReach = max(1, (region.maxLatitude - region.minLatitude) * 0.7)
        let longitudeReach = max(1.5, (region.maxLongitude - region.minLongitude) * 0.7)
        return MapRegion(
            centerLatitude: (region.minLatitude + region.maxLatitude) / 2,
            centerLongitude: (region.minLongitude + region.maxLongitude) / 2, latitudeReach: latitudeReach,
            longitudeReach: longitudeReach)
    }
}

#if !os(macOS)
    /// What the shelves of the Collections tab show (SPEC §20.4), loaded once per sync and kept while the tab is alive:
    /// the covers are there at once when the user comes back, and nothing is computed again until the library changed.
    @MainActor @Observable final class CollectionsOverviewModel {
        /// Where the geotagged photos are, for the small map of the Places shelf.
        struct MapSummary: Hashable, Sendable {
            struct Point: Hashable, Sendable {
                var latitude: Double
                var longitude: Double
                var count: Int
            }

            var region: MapRegion
            var points: [Point]
            var photoCount: Int { points.reduce(0) { $0 + $1.count } }
        }

        var albums: [Album] = []
        var shared: [Album] = []
        var albumsLoaded = false
        /// Nil until loaded.
        var memories: [Memory]?
        var people: [Person]?
        var map: MapSummary?
        var mapLoaded = false
        /// The newest favourite: the Favorites card's cover, as in Apple's Photos (SPEC §20.1). Nil: no favourites (the
        /// card shows its gradient and heart).
        var favoritesCover: FileID?
        private var loadedKey: CollectionsOverview.LoadKey?

        func load(session: SessionModel, people withPeople: Bool) async {
            let key = CollectionsOverview.LoadKey(session.syncStatus, account: session.account.id.rawValue)
            guard key != loadedKey, let services = session.services else { return }
            // Each part on its own: the memories need a pass over the index, people the server.
            async let memories: [Memory]? = MemoriesStrip.load(services)
            async let map: MapSummary? = Self.mapSummary(services.library)
            let people: [Person]? = withPeople ? await Self.people(session: session) : []
            let loadedMemories = await memories
            let loadedMap = await map
            guard !Task.isCancelled else { return }
            if let loadedMemories { self.memories = loadedMemories }
            self.people = people ?? self.people ?? []
            self.map = loadedMap
            mapLoaded = true
            loadedKey = key
        }

        /// Own and shared albums from the local index, as they change; asks the server once whether they changed.
        func observeAlbums(session: SessionModel) async {
            guard let services = session.services else { return }
            async let favorites: Void = observeFavorites(services: services, excludedFolders: TimelineScreen.excludedFolders(session))
            guard session.features.has(.photosDAV) else {
                albumsLoaded = true
                await favorites
                return
            }
            Task { try? await session.refreshAlbums(force: false) }
            async let own: Void = observe(.own, services: services)
            async let shared: Void = observe(.shared, services: services)
            _ = await (own, shared, favorites)
        }

        /// The Favorites card's cover follows the newest favourite (one indexed row, read again when the index changes).
        private func observeFavorites(services: AccountServices, excludedFolders: [String]) async {
            do {
                for try await newest in services.library.observeNewest(.favorites, excludedFolders: excludedFolders) {
                    favoritesCover = newest?.fileId
                }
            } catch {}
        }

        private func observe(_ kind: AlbumKind, services: AccountServices) async {
            do {
                for try await value in services.collections.observeAlbums(kind) {
                    if kind == .shared {
                        shared = value
                    } else {
                        albums = value
                        albumsLoaded = true
                    }
                }
            } catch {}
        }

        /// The albums used last in this app, then the most recently changed (like "Add to Album").
        func recentAlbums(account: AccountID) -> [Album] {
            RecentAlbums.pick(albums, used: RecentAlbumsStore.used(account), limit: CollectionsOverview.shelfLimit)
        }

        /// The people with the most photos, named ones first. Nil when the server could not be asked.
        static func people(session: SessionModel) async -> [Person]? {
            guard let services = session.services else { return nil }
            guard let all = try? await services.api.people(key: await session.recognizeKey()) else { return nil }
            return CollectionsOverview.shelfPeople(all)
        }

        static func mapSummary(_ library: LibraryStore) async -> MapSummary? {
            guard let overview = try? await library.mapOverview() else { return nil }
            let region = CollectionsOverview.paddedRegion(overview.region)
            // About eight cells across: enough dots to show where the photos are, few enough to draw at once.
            let cells: [MapCell] =
                (try? await library.mapCells(
                    in: region, cellLatitude: max(0.05, (region.maxLatitude - region.minLatitude) / 8),
                    cellLongitude: max(0.05, (region.maxLongitude - region.minLongitude) / 8))) ?? []
            let points = cells.map { MapSummary.Point(latitude: $0.latitude, longitude: $0.longitude, count: $0.count) }
            return MapSummary(region: region, points: points)
        }

    }

    /// One shelf: its title (which opens the place) and its covers in a row.
    struct CollectionsShelfView: View {
        let shelf: CompactNavigation.Shelf
        let destination: AppDestination
        /// The server has albums: the Albums shelf lists them after Favorites.
        let showsAlbums: Bool
        let model: CollectionsOverviewModel
        @Environment(SessionModel.self) private var session
        @Environment(\.routeTransitionNamespace) private var transitions
        /// A memory zooms out of its card (SPEC §17.4).
        @Namespace private var zoom

        static let albumSide: CGFloat = 150
        static let memorySize = CGSize(width: 210, height: 150)
        static let personSide: CGFloat = 84

        var title: String {
            switch shelf {
            case .albums: String(localized: showsAlbums ? AppDestination.albums.title : AppDestination.favorites.title)
            case .shared: String(localized: AppDestination.sharedAlbums.rowTitle)
            default: String(localized: destination.title)
            }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                header
                content
            }
        }

        /// The shelf's title: a link to the whole place.
        var header: some View {
            NavigationLink(value: AppRoute.destination(destination.rawValue)) {
                HStack(spacing: 6) {
                    Text(title).font(Typography.sectionTitle).foregroundStyle(.primary)
                    Image(systemName: "chevron.right")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("collections-shelf-\(shelf)")
        }

        @ViewBuilder var content: some View {
            switch shelf {
            case .albums: albumsRow
            case .memories: memoriesRow
            case .people: peopleRow
            case .places: placesCard
            case .shared: sharedRow
            }
        }

        func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
            ScrollView(.horizontal) {
                // Not lazy: a lazy stack takes its height from the cards it measured first, and at the accessibility text
                // sizes it cut the titles of the others to that height ("r7-grid-…" in two of its four lines). A shelf
                // has at most `CollectionsOverview.shelfLimit` cards, and their covers load when they come on screen.
                HStack(alignment: .top, spacing: 12) { content() }
                    .padding(.horizontal)
            }
            .scrollIndicators(.hidden)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(title))
        }

        var albumsRow: some View {
            row {
                NavigationLink(value: AppRoute.destination(AppDestination.favorites.rawValue)) {
                    FavoritesCard(cover: model.favoritesCover).frame(width: Self.albumSide)
                }
                .buttonStyle(.plain)
                if showsAlbums {
                    if model.albumsLoaded {
                        ForEach(model.recentAlbums(account: session.account.id)) { (album: Album) in albumLink(album) }
                    } else {
                        placeholders(count: 3, size: CGSize(width: Self.albumSide, height: Self.albumSide))
                    }
                }
            }
        }

        var sharedRow: some View {
            Group {
                if !model.shared.isEmpty {
                    row {
                        ForEach(Array(model.shared.prefix(CollectionsOverview.shelfLimit))) { (album: Album) in albumLink(album) }
                    }
                }
            }
        }

        func albumLink(_ album: Album) -> some View {
            // By value: the stack's path (MainView) knows which album is open; it zooms out of its card.
            NavigationLink(value: AppRoute.album(id: album.id)) {
                AlbumCard(album: album)
                    .frame(width: Self.albumSide)
                    .cardTransitionSource(id: AppRoute.album(id: album.id), in: transitions)
            }
            .buttonStyle(.plain)
        }

        @ViewBuilder var memoriesRow: some View {
            if let memories = model.memories, memories.isEmpty {
                emptyNote(Text("Memories appear here as your library grows.", bundle: .module, comment: "Collections: no memories yet."))
            } else {
                row {
                    if let memories = model.memories {
                        ForEach(Array(memories.prefix(CollectionsOverview.shelfLimit))) { (memory: Memory) in
                            NavigationLink {
                                MemoryScreen(memory: memory).cardTransitionDestination(id: memory.id, in: zoom)
                            } label: {
                                MemoryCard(memory: memory, compact: true)
                                    .frame(width: Self.memorySize.width, height: Self.memorySize.height)
                                    .cardTransitionSource(id: memory.id, in: zoom, cornerRadius: 12)
                                    // A fixed size: the whole title is in the VoiceOver label and on the memory's screen.
                                    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        placeholders(count: 2, size: Self.memorySize)
                    }
                }
            }
        }

        @ViewBuilder var peopleRow: some View {
            if let people = model.people, !people.isEmpty {
                row {
                    ForEach(people) { (person: Person) in
                        NavigationLink(value: AppRoute.person(name: person.name)) {
                            CollectionTile(
                                title: person.isUnnamed ? String(localized: "Add name", bundle: .module) : person.name,
                                coverFileId: person.coverFileId, faceBox: person.coverBox, circular: true,
                                kind: String(localized: "person", bundle: .module)
                            )
                            .frame(width: Self.personSide)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else if model.people == nil {
                row { placeholders(count: 4, size: CGSize(width: Self.personSide, height: Self.personSide), circular: true) }
            }
        }

        @ViewBuilder var placesCard: some View {
            if let map = model.map {
                NavigationLink(value: AppRoute.destination(AppDestination.places.rawValue)) {
                    PlacesMapCard(summary: map)
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
            } else if !model.mapLoaded {
                RoundedRectangle(cornerRadius: Design.coverCornerRadius).fill(.quaternary)
                    .frame(height: PlacesMapCard.height)
                    .padding(.horizontal)
                    .accessibilityHidden(true)
            }
        }

        func emptyNote(_ text: Text) -> some View {
            text.font(.subheadline).foregroundStyle(.secondary).padding(.horizontal)
        }

        /// The covers' shape while they load (SPEC §15.5: no spinners), so the shelf does not jump when they come.
        func placeholders(count: Int, size: CGSize, circular: Bool = false) -> some View {
            ForEach(0..<count, id: \.self) { _ in
                Group {
                    if circular {
                        Circle().fill(.quaternary)
                    } else {
                        RoundedRectangle(cornerRadius: Design.coverCornerRadius).fill(.quaternary)
                    }
                }
                .frame(width: size.width, height: size.height)
                .accessibilityHidden(true)
            }
        }
    }

    /// Favorites as the first card of the Albums shelf, the size of an album's cover: the newest favourite as its cover
    /// and a small heart before the title, as in Apple's Photos; the gradient with a large heart while there are none.
    struct FavoritesCard: View {
        /// The newest favourite photo; nil when there are no favourites.
        let cover: FileID?
        @Environment(\.dynamicTypeSize) private var dynamicTypeSize

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                // The gradient stays behind the cover, as on album cards: a cover still loading (or without a preview)
                // is not blank.
                ZStack {
                    AlbumGradientView(name: "Favorites")
                    if let cover {
                        AlbumCover(fileId: cover)
                    } else {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 44, weight: .semibold))
                            .foregroundStyle(.white)
                            .shadow(radius: 6)
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(.rect(cornerRadius: Design.coverCornerRadius))
                .overlay(alignment: .bottom) {
                    if !dynamicTypeSize.isAccessibilitySize {
                        CaptionPlate(cornerRadius: Design.coverCornerRadius - 3) { title.font(Typography.cardTitle).lineLimit(1) }
                            .padding(6)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if cover != nil && dynamicTypeSize.isAccessibilitySize {
                        Image(systemName: "heart.fill")
                            .font(.caption)
                            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                            .frame(width: 26, height: 26)
                            .modifier(GlassCircle())
                            .padding(6)
                            .accessibilityHidden(true)
                    }
                }
                if dynamicTypeSize.isAccessibilitySize {
                    // Large text does not fit on the cover: below it, wrapped instead of cut off, as album cards do; the
                    // heart then stays on the cover, so that the word keeps the card's whole width.
                    Text(AppDestination.favorites.title).cardTitleStyle()
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(AppDestination.favorites.title))
        }

        /// "♥ Favorites": the heart stays with the title when a photo is the cover.
        var title: some View {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if cover != nil {
                    Image(systemName: "heart.fill").imageScale(.small).accessibilityHidden(true)
                }
                Text(AppDestination.favorites.title)
            }
        }
    }

    /// A small map of where the photos were taken, with a dot per area: the Places shelf.
    struct PlacesMapCard: View {
        let summary: CollectionsOverviewModel.MapSummary
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.displayScale) private var displayScale
        @State private var image: UIImage?
        @State private var width: CGFloat = 0

        static let height: CGFloat = 170

        struct SnapshotKey: Hashable {
            var summary: CollectionsOverviewModel.MapSummary
            var dark: Bool
            var width: Int
            var scale: Double
        }

        var key: SnapshotKey {
            SnapshotKey(summary: summary, dark: colorScheme == .dark, width: Int(width), scale: Double(displayScale))
        }

        var body: some View {
            RoundedRectangle(cornerRadius: Design.coverCornerRadius).fill(.quaternary)
                .overlay {
                    if let image {
                        Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: Self.height)
                .clipShape(.rect(cornerRadius: Design.coverCornerRadius))
                // At the top: the card is the last one on the iPhone's first screen of Collections, and its lower edge rests
                // under the floating tab bar, whose glass covered a caption at the bottom ("411 phot…", SPEC §20.1).
                .overlay(alignment: .topLeading) {
                    CaptionPlate(cornerRadius: Design.coverCornerRadius - 3) {
                        Text(AccessibilityText.photos(summary.photoCount)).font(Typography.cardSubtitle).lineLimit(1)
                    }
                    .fixedSize()
                    .padding(6)
                }
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { value in
                    width = value
                }
                .task(id: key) {
                    let key = key
                    guard key.width > 0 else { return }
                    if let cached = MapSnapshotCache.images[key] {
                        image = cached
                        return
                    }
                    guard let made = await Self.snapshot(key) else { return }
                    MapSnapshotCache.store(made, for: key)
                    image = made
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    Text(
                        "Map of your places, \(AccessibilityText.photos(summary.photoCount))", bundle: .module,
                        comment: "VoiceOver label of the small map in Collections; the argument is e.g. \"120 photos\"."))
        }

        static func snapshot(_ key: SnapshotKey) async -> UIImage? {
            let region = key.summary.region
            let options = MKMapSnapshotter.Options()
            options.region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(
                    latitude: (region.minLatitude + region.maxLatitude) / 2, longitude: (region.minLongitude + region.maxLongitude) / 2),
                span: MKCoordinateSpan(
                    latitudeDelta: min(170, region.maxLatitude - region.minLatitude),
                    longitudeDelta: min(360, region.maxLongitude - region.minLongitude)))
            let size = CGSize(width: CGFloat(key.width), height: height)
            options.size = size
            options.traitCollection = UITraitCollection(mutations: { traits in
                traits.userInterfaceStyle = key.dark ? .dark : .light
                traits.displayScale = key.scale
            })
            options.pointOfInterestFilter = .excludingAll
            guard let snapshot = try? await MKMapSnapshotter(options: options).start() else { return nil }
            let format = UIGraphicsImageRendererFormat()
            format.scale = key.scale
            return UIGraphicsImageRenderer(size: size, format: format).image { context in
                snapshot.image.draw(at: .zero)
                let fill = UIColor(Design.accent)
                for point in key.summary.points {
                    let center = snapshot.point(for: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude))
                    // Bigger where there are more photos, within reason.
                    let radius: CGFloat = 3.5 + min(5, log2(CGFloat(max(1, point.count))) / 2)
                    let rect = CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)
                    context.cgContext.setFillColor(fill.cgColor)
                    context.cgContext.setStrokeColor(UIColor.white.cgColor)
                    context.cgContext.setLineWidth(1.5)
                    context.cgContext.fillEllipse(in: rect)
                    context.cgContext.strokeEllipse(in: rect)
                }
            }
        }
    }

    /// The Places shelf's maps of this run of the app, a few at most (light and dark, a rotation).
    @MainActor enum MapSnapshotCache {
        private(set) static var images: [PlacesMapCard.SnapshotKey: UIImage] = [:]

        static func store(_ image: UIImage, for key: PlacesMapCard.SnapshotKey) {
            if images.count >= 4 { images.removeAll() }
            images[key] = image
        }
    }
#endif
