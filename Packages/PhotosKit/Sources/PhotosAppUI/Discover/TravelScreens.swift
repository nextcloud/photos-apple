// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import MapKit
import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosStore
import SwiftUI

// MARK: - Travel globe and countries (SPEC §15.6)

extension GeoCoordinate {
    var location: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

/// Wording and number formats of the travel screens.
enum TravelWording {
    static var title: String {
        String(localized: "Travel", bundle: .module, comment: "Title of the globe with the user's trips, from the geotagged photos.")
    }

    static func countries(_ count: Int) -> String {
        String(
            localized: "\(count) countries", bundle: .module,
            comment: "Travel stats: number of countries visited; plural variations in the catalog.")
    }

    static func places(_ count: Int) -> String {
        String(
            localized: "\(count) places", bundle: .module,
            comment: "Travel stats: number of places visited; plural variations in the catalog.")
    }

    static func trips(_ count: Int) -> String {
        String(localized: "\(count) trips", bundle: .module, comment: "Travel stats: number of trips; plural variations in the catalog.")
    }

    /// "412,000 km" (miles where the locale uses them), whole numbers.
    static func distance(_ metres: Double, locale: Locale = .current) -> String {
        Measurement(value: metres / 1000, unit: UnitLength.kilometers)
            .formatted(
                .measurement(width: .abbreviated, usage: .road, numberFormatStyle: .number.precision(.fractionLength(0))).locale(locale))
    }

    /// "37 countries · 412,000 km": the fun line under Travel; places when there are no trips.
    static func statsLine(_ stats: TravelHistory.Stats, locale: Locale = .current) -> String {
        var parts: [String] = []
        if stats.countries > 0 { parts.append(countries(stats.countries)) }
        if stats.distance >= 1000 { parts.append(distance(stats.distance, locale: locale)) } else { parts.append(places(stats.places)) }
        return parts.joined(separator: " · ")
    }

    /// The name of a trip: its two main places ("Lisbon & Porto"), else its dates.
    static func tripTitle(_ trip: TravelHistory.Trip) -> String {
        switch trip.placeNames.count {
        case 0: DateRangeLabel.string(from: trip.start, to: trip.end)
        case 1: trip.placeNames[0]
        default: "\(trip.placeNames[0]) & \(trip.placeNames[1])"
        }
    }

    static func countryName(_ code: String, locale: Locale = .current) -> String {
        locale.localizedString(forRegionCode: code) ?? code
    }

    static var allYears: String {
        String(localized: "All years", bundle: .module, comment: "Travel: the year filter's choice that shows every year.")
    }

    static var countriesTitle: String {
        String(localized: "Countries", bundle: .module, comment: "Travel: title of the list of countries visited (a scratch map).")
    }

    static var home: String {
        String(
            localized: "Home", bundle: .module,
            comment: "Travel: the marker of the place the user photographs most often (probably where they live).")
    }
}

/// The travel history of the account, built once on a background task and kept for a few minutes; countries the server
/// does not know can be looked up with Apple Maps when the user asks for it.
@MainActor @Observable
final class TravelModel {
    private(set) var history: TravelHistory?
    private(set) var lookingUp = false

    private static var cache: [AccountID: (date: Date, history: TravelHistory)] = [:]

    func load(_ services: AccountServices) async {
        let account = services.account.id
        if let cached = Self.cache[account], Date().timeIntervalSince(cached.date) < ThenAndNowModel.cacheLifetime {
            history = cached.history
            return
        }
        let library = services.library
        var built = await Task.detached(priority: .userInitiated) { () -> TravelHistory in
            TravelHistory((try? await library.locatedItems()) ?? [])
        }.value
        built = built.assigningCountries(CountryLookup.cachedCodes(for: built.placesWithoutCountry))
        Self.cache[account] = (Date(), built)
        history = built
    }

    /// Looks up the countries of places without one (largest first, rate-limited; results are kept on the device).
    func lookUpCountries(_ services: AccountServices) async {
        guard !lookingUp, var history else { return }
        lookingUp = true
        defer { lookingUp = false }
        for place in history.placesWithoutCountry.prefix(CountryLookup.maximumPerRun) {
            guard !Task.isCancelled else { break }
            guard let code = await CountryLookup.shared.code(at: place.coordinate) else { continue }
            history = history.assigningCountries([place.id: code])
            self.history = history
        }
        Self.cache[services.account.id] = (Date(), history)
    }
}

/// Reverse geocoding of place coordinates to country codes with MapKit, for places the server has no country for. Sends
/// the coordinate of a place to Apple, so it only runs when the user asks for it; at most one request every 1.5 s, and
/// every answer (also "none") is kept on the device by coordinate (rounded to 0.1°).
@MainActor
final class CountryLookup {
    static let shared = CountryLookup()
    static let maximumPerRun = 40
    static let interval: Duration = .milliseconds(1500)
    static let defaultsKey = "travelCountryCodes"
    private var last: ContinuousClock.Instant?

    static func key(_ coordinate: GeoCoordinate) -> String {
        String(format: "%.1f,%.1f", coordinate.latitude, coordinate.longitude)
    }

    static var stored: [String: String] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }

    /// The codes already looked up for some places (by place id).
    static func cachedCodes(for places: [TravelHistory.Place]) -> [Int: String] {
        let stored = stored
        var result: [Int: String] = [:]
        for place in places { if let code = stored[key(place.coordinate)], !code.isEmpty { result[place.id] = code } }
        return result
    }

    func code(at coordinate: GeoCoordinate) async -> String? {
        let key = Self.key(coordinate)
        if let stored = Self.stored[key] { return stored.isEmpty ? nil : stored }
        if let last {
            let wait = last + Self.interval - ContinuousClock.now
            if wait > .zero { try? await Task.sleep(for: wait) }
        }
        last = ContinuousClock.now
        guard !Task.isCancelled,
            let request = MKReverseGeocodingRequest(location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
        else { return nil }
        do {
            let items = try await request.mapItems
            let code = items.lazy.compactMap { $0.addressRepresentations?.region?.identifier }.first ?? ""
            var stored = Self.stored
            stored[key] = code
            UserDefaults.standard.set(stored, forKey: Self.defaultsKey)
            return code.isEmpty ? nil : code
        } catch {
            // Not stored: tried again next time (offline, or the service's limit was reached).
            return nil
        }
    }
}

/// The travel card at the top of Places: the stats line, opening the globe.
struct TravelSummaryCard: View {
    let model: TravelModel

    var body: some View {
        if let history = model.history, !history.visits.isEmpty {
            let stats = history.stats()
            NavigationLink {
                TravelGlobeScreen(model: model)
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "globe.europe.africa.fill")
                        .font(.system(size: 34))
                        .symbolRenderingMode(.multicolor)
                        .foregroundStyle(.blue, .green)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(TravelWording.title).font(.headline)
                        Text(TravelWording.statsLine(stats)).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .padding(14)
                .background(.fill.quaternary, in: .rect(cornerRadius: 16))
                .contentShape(.rect(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
        }
    }
}

/// A place opened from the globe: its photos in the year shown.
private struct PlaceSelection: Identifiable, Hashable {
    var place: Int
    var year: Int?
    var id: String { "\(place)-\(year ?? 0)" }
}

/// The user's trips as arcs on a globe, in time order, filtered by year; places open their photos, trips fly the globe
/// to them. MapKit's realistic imagery shows the earth as a globe when zoomed out.
struct TravelGlobeScreen: View {
    @State private var model: TravelModel
    @State private var year: Int?
    @State private var selectedTrip: TravelHistory.Trip.ID?
    @State private var selectedPlace: PlaceSelection?
    @State private var position: MapCameraPosition = .automatic
    @Environment(SessionModel.self) private var session

    /// Places with a photo marker; the others are dots (hundreds of photo markers would make the globe slow and busy).
    static let photoMarkers = 40
    /// Camera distance (metres) that shows the whole globe.
    static let globeDistance: Double = 45_000_000

    /// `model`: the one Places already loaded; else the globe loads its own.
    init(model: TravelModel? = nil) {
        let model = model ?? TravelModel()
        _model = State(initialValue: model)
        // Already loaded (from Places): open on the globe at once instead of the default framing.
        _position = State(initialValue: model.history.map { .camera(Self.overview(of: $0)) } ?? .automatic)
    }

    var history: TravelHistory { model.history ?? TravelHistory() }
    var trips: [TravelHistory.Trip] { history.trips(in: year) }
    var places: [TravelHistory.Place] { history.places(in: year) }

    var body: some View {
        map
            .safeAreaInset(edge: .bottom) { panel }
            .navigationTitle(TravelWording.title)
            #if os(iOS)
                // The globe goes up to the top; a large title would sit on it.
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbar }
            .sheet(item: $selectedPlace) { selection in
                NavigationStack {
                    ItemsScreen(title: history.places[selection.place].name ?? TravelWording.title) { services in
                        let ids = history.items(ofPlace: selection.place, in: selection.year)
                        let map = try await services.library.fetchItems(ids)
                        return ids.compactMap { map[$0] }
                    }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(String(localized: "Done", bundle: .module)) { selectedPlace = nil }
                        }
                    }
                }
                .sheetMinimumSize(width: 600, height: 500)
            }
            .task {
                guard let services = session.services else { return }
                guard model.history == nil else { return }
                await model.load(services)
                position = .camera(Self.overview(of: history))
            }
            .onChange(of: year) { _, _ in
                selectedTrip = nil
                withAnimation(.smooth(duration: 1.2)) { position = .camera(Self.overview(of: history, year: year)) }
            }
    }

    var map: some View {
        Map(position: $position) {
            // Each leg once, however often it was travelled (wider the more often); the selected trip on top.
            ForEach(legs) { leg in
                MapPolyline(
                    coordinates: [history.places[leg.from].coordinate.location, history.places[leg.to].coordinate.location],
                    contourStyle: .geodesic
                )
                .stroke(color(of: leg), style: StrokeStyle(lineWidth: Self.width(of: leg), lineCap: .round))
            }
            if let trip = trips.first(where: { $0.id == selectedTrip }) {
                MapPolyline(coordinates: trip.path.map(\.location), contourStyle: .geodesic)
                    .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            ForEach(Array(places.enumerated()), id: \.element.id) { rank, place in
                Annotation(place.name ?? "", coordinate: place.coordinate.location, anchor: .center) {
                    PlaceMarker(place: place, isHome: place.id == history.home, showsPhoto: rank < Self.photoMarkers)
                        .onTapGesture { selectedPlace = PlaceSelection(place: place.id, year: year) }
                        // Annotations are hosted outside the view hierarchy: the preview needs the session passed on.
                        .environment(session)
                }
                .annotationTitles(rank < Self.photoMarkers ? .automatic : .hidden)
            }
        }
        .mapStyle(.hybrid(elevation: .realistic, pointsOfInterest: .excludingAll))
        .mapControls {
            MapCompass()
            MapPitchToggle()
        }
    }

    var legs: [TravelHistory.Leg] { history.legs(in: year) }

    /// Legs last travelled long ago fade towards the background; they all recede while a trip is selected.
    func color(of leg: TravelHistory.Leg) -> Color {
        if selectedTrip != nil { return .yellow.opacity(0.3) }
        let legs = legs
        guard let first = legs.first?.latest, let last = legs.last?.latest, last > first else { return .yellow }
        let age = last.timeIntervalSince(leg.latest) / last.timeIntervalSince(first)
        return Color(hue: 0.13 - 0.06 * age, saturation: 0.95, brightness: 1, opacity: 1 - 0.45 * age)
    }

    /// 1.5 pt, up to 4 pt for a leg travelled often.
    static func width(of leg: TravelHistory.Leg) -> CGFloat {
        1.5 + min(2.5, CGFloat(leg.count - 1) * 0.5)
    }

    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        ToolbarItem {
            Menu {
                Picker(selection: $year) {
                    Text(TravelWording.allYears).tag(Int?.none)
                    ForEach(history.years, id: \.self) { year in
                        Text(String(year)).tag(Int?.some(year))
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.inline)
            } label: {
                Label(year.map { String($0) } ?? TravelWording.allYears, systemImage: "calendar")
            }
            .help(String(localized: "Year", bundle: .module, comment: "Travel: help of the year filter."))
        }
        ToolbarItem {
            NavigationLink {
                CountriesScreen(model: model, year: year)
            } label: {
                Label(TravelWording.countriesTitle, systemImage: "flag")
            }
            .help(TravelWording.countriesTitle)
        }
    }

    var panel: some View {
        let stats = history.stats(in: year)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(year.map { String($0) } ?? TravelWording.allYears).font(.headline)
                    Text(TravelWording.statsLine(stats)).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                if stats.trips > 0 {
                    Text(TravelWording.trips(stats.trips)).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if let trip = trips.first(where: { $0.id == selectedTrip }) {
                selectedTripRow(trip)
            }
            if !trips.isEmpty {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 10) {
                        ForEach(trips.reversed()) { trip in
                            TripChip(trip: trip, isSelected: trip.id == selectedTrip) { select(trip) }
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned)
                // As tall as the trips, not as tall as the map.
                .fixedSize(horizontal: false, vertical: true)
            } else if model.history != nil {
                Text("No trips in this time.", bundle: .module, comment: "Travel: the year filter shows a year without trips.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: .rect(cornerRadius: 20))
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    func selectedTripRow(_ trip: TravelHistory.Trip) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(TravelWording.tripTitle(trip)).font(.subheadline.weight(.semibold))
                Text(
                    AccessibilityText.join([DateRangeLabel.string(from: trip.start, to: trip.end), TravelWording.distance(trip.distance)])
                ).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            NavigationLink {
                ItemsScreen(title: TravelWording.tripTitle(trip)) { services in
                    let ids = history.items(ofTrip: trip)
                    let map = try await services.library.fetchItems(ids)
                    return ids.compactMap { map[$0] }
                }
            } label: {
                Label(AccessibilityText.photos(trip.itemCount), systemImage: "photo.on.rectangle")
            }
            .buttonStyle(.bordered)
        }
    }

    func select(_ trip: TravelHistory.Trip) {
        if selectedTrip == trip.id {
            selectedTrip = nil
            withAnimation(.smooth(duration: 1.2)) { position = .camera(Self.overview(of: history, year: year)) }
            return
        }
        selectedTrip = trip.id
        withAnimation(.smooth(duration: 1.5)) { position = .camera(Self.camera(around: trip.path)) }
    }

    /// The globe turned to home (or the middle of the year's places), far enough out to see the whole earth.
    static func overview(of history: TravelHistory, year: Int? = nil) -> MapCamera {
        let center: GeoCoordinate
        if year == nil, let home = history.home {
            center = history.places[home].coordinate
        } else {
            center =
                history.places(in: year).first?.coordinate ?? history.home.map { history.places[$0].coordinate }
                ?? GeoCoordinate(latitude: 30, longitude: 10)
        }
        // Far enough for the whole earth also in a narrow, portrait window.
        return MapCamera(centerCoordinate: center.location, distance: Self.globeDistance, heading: 0, pitch: 0)
    }

    /// A camera that shows some coordinates: centred on them, as far out as the farthest one needs.
    static func camera(around coordinates: [GeoCoordinate]) -> MapCamera {
        let center = GeoCoordinate.center(of: coordinates) ?? GeoCoordinate(latitude: 30, longitude: 10)
        let reach = coordinates.map { $0.distance(to: center) }.max() ?? 0
        return MapCamera(
            centerCoordinate: center.location, distance: min(Self.globeDistance, max(400_000, reach * 3.2)), heading: 0, pitch: 0)
    }
}

/// A place on the globe: its photo in a white ring for the larger places, a dot for the others, a house for home.
private struct PlaceMarker: View {
    let place: TravelHistory.Place
    let isHome: Bool
    let showsPhoto: Bool

    var body: some View {
        Group {
            if isHome {
                Image(systemName: "house.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Design.accent, in: Circle())
                    .overlay(Circle().stroke(.white, lineWidth: 2))
            } else if showsPhoto {
                PreviewImage(fileId: place.cover, etag: "", bucket: 64)
                    .frame(width: 36, height: 36)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(.white, lineWidth: 2))
            } else {
                Circle().fill(.yellow).frame(width: 10, height: 10).overlay(Circle().stroke(.white, lineWidth: 1.5))
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 3)
        .contentShape(Circle().inset(by: -8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            AccessibilityText.join([isHome ? TravelWording.home : nil, place.name, AccessibilityText.photos(place.itemCount)])
        )
        .accessibilityAddTraits(.isButton)
    }
}

/// A trip in the globe's list: cover, places, year and distance.
private struct TripChip: View {
    let trip: TravelHistory.Trip
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                PreviewImage(fileId: trip.cover, etag: "", bucket: 256)
                    .frame(width: 44, height: 44)
                    .clipShape(.rect(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 1) {
                    Text(TravelWording.tripTitle(trip)).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(
                        AccessibilityText.join([
                            trip.start.formatted(.dateTime.month(.abbreviated).year()), TravelWording.distance(trip.distance),
                        ])
                    )
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(6)
            .padding(.trailing, 6)
            .frame(maxWidth: 260, alignment: .leading)
            .background(isSelected ? AnyShapeStyle(.tint.opacity(0.25)) : AnyShapeStyle(.fill.quaternary), in: .rect(cornerRadius: 12))
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Countries (scratch map)

/// The countries visited: a big count, the share of the world, and per continent either the visited countries with
/// their years or a "scratch map" of every country's flag, the visited ones in colour.
struct CountriesScreen: View {
    let model: TravelModel
    var year: Int?
    @State private var scratchMap = false
    @AppStorage("travelLookUpCountries") private var lookUpAllowed = false
    @Environment(SessionModel.self) private var session

    var countries: [TravelHistory.Country] { model.history?.countries(in: year) ?? [] }

    /// Continents (by name) with their visited countries, the continent with most first.
    var continents: [(name: String, countries: [TravelHistory.Country])] {
        let groups = Dictionary(grouping: countries) { CountryRegions.continentName(of: $0.code) }
        return groups.map {
            (name: $0.key, countries: $0.value.sorted { TravelWording.countryName($0.code) < TravelWording.countryName($1.code) })
        }
        .sorted { ($0.countries.count, $1.name) > ($1.countries.count, $0.name) }
    }

    var body: some View {
        List {
            Section {
                header
            }
            Picker(selection: $scratchMap) {
                Text("Visited", bundle: .module, comment: "Countries: show the visited countries as a list.").tag(false)
                Text(
                    "Scratch map", bundle: .module,
                    comment: "Countries: show every country's flag, the visited ones in colour (like a scratch-off world map)."
                ).tag(true)
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            if scratchMap {
                ForEach(CountryRegions.continents, id: \.name) { continent in
                    Section(continent.name) {
                        FlagGrid(codes: continent.codes, visited: Set(countries.map(\.code)))
                    }
                }
            } else {
                ForEach(continents, id: \.name) { continent in
                    Section {
                        ForEach(continent.countries) { country in
                            NavigationLink {
                                ItemsScreen(title: TravelWording.countryName(country.code)) { services in
                                    let ids = model.history?.items(inCountry: country.code, year: year) ?? []
                                    let map = try await services.library.fetchItems(ids)
                                    return ids.compactMap { map[$0] }
                                }
                            } label: {
                                CountryRow(country: country)
                            }
                        }
                    } header: {
                        Text(verbatim: "\(continent.name) · \(continent.countries.count)")
                    }
                }
            }
            lookUpSection
        }
        .navigationTitle(year.map { "\(TravelWording.countriesTitle) \($0)" } ?? TravelWording.countriesTitle)
        .task {
            guard let services = session.services else { return }
            if model.history == nil { await model.load(services) }
            if lookUpAllowed { await model.lookUpCountries(services) }
        }
    }

    var header: some View {
        let share = TravelHistory.worldShare(countries.count)
        return HStack(spacing: 18) {
            Gauge(value: share) {
                EmptyView()
            } currentValueLabel: {
                Text(share.formatted(.percent.precision(.fractionLength(0))))
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(.green)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(TravelWording.countries(countries.count)).font(.title.bold())
                Text(
                    "\(share.formatted(.percent.precision(.fractionLength(0)))) of the world", bundle: .module,
                    comment: "Countries: the share of the world's 195 countries visited, e.g. \"19 % of the world\"."
                ).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    /// Places without a country from the server: offered to look up with Apple Maps (the coordinates go to Apple).
    @ViewBuilder var lookUpSection: some View {
        let missing = model.history?.placesWithoutCountry.count ?? 0
        if missing > 0 {
            Section {
                if model.lookingUp {
                    HStack {
                        ProgressView()
                        Text(
                            "Looking up countries…", bundle: .module,
                            comment: "Countries: shown while the countries of places are looked up with Apple Maps.")
                    }
                } else {
                    Button {
                        lookUpAllowed = true
                        Task {
                            guard let services = session.services else { return }
                            await model.lookUpCountries(services)
                        }
                    } label: {
                        Text(
                            "Look up countries with Apple Maps", bundle: .module,
                            comment: "Countries: button that finds the countries of places the server knows none for.")
                    }
                }
            } footer: {
                Text(
                    "\(missing) places have no country on your server. Looking them up sends their approximate location to Apple.",
                    bundle: .module,
                    comment: "Countries: explanation under the button that looks up countries. The argument is the number of places.")
            }
        }
    }
}

private struct CountryRow: View {
    let country: TravelHistory.Country

    var body: some View {
        HStack(spacing: 12) {
            Text(TravelHistory.flag(country.code) ?? "🏳️").font(.largeTitle).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(TravelWording.countryName(country.code)).font(.headline)
                Text(AccessibilityText.join([CountryRegions.yearList(country.years), AccessibilityText.photos(country.itemCount)]))
                    .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Every country's flag of a continent; the visited ones in colour, the others faded.
private struct FlagGrid: View {
    let codes: [String]
    let visited: Set<String>

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 6)], spacing: 6) {
            ForEach(codes, id: \.self) { code in
                let isVisited = visited.contains(code)
                Text(TravelHistory.flag(code) ?? "")
                    .font(.system(size: 30))
                    .grayscale(isVisited ? 0 : 1)
                    .opacity(isVisited ? 1 : 0.25)
                    .scaleEffect(isVisited ? 1.1 : 1)
                    .help(TravelWording.countryName(code))
                    .accessibilityLabel(TravelWording.countryName(code))
                    .accessibilityAddTraits(isVisited ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}

/// The world's countries by continent, from the system's region data.
enum CountryRegions {
    /// Continents with the ISO codes of their countries and territories, sorted by name.
    static let continents: [(name: String, codes: [String])] = {
        var groups: [String: [String]] = [:]
        for region in Locale.Region.isoRegions where region.identifier.count == 2 && region.identifier.allSatisfy(\.isLetter) {
            // Regions that are not countries (the EU, the UN, "unknown") have no continent.
            guard region.continent != nil else { continue }
            groups[continentName(of: region.identifier), default: []].append(region.identifier)
        }
        return groups.map { (name: $0.key, codes: $0.value.sorted { TravelWording.countryName($0) < TravelWording.countryName($1) }) }
            .sorted { $0.name < $1.name }
    }()

    static func continentName(of code: String, locale: Locale = .current) -> String {
        guard let continent = Locale.Region(code).continent else {
            return String(localized: "Other", bundle: .module)
        }
        return locale.localizedString(forRegionCode: continent.identifier) ?? continent.identifier
    }

    /// "2014, 2019, 2025", or "2014–2025" for many years.
    static func yearList(_ years: [Int]) -> String {
        guard years.count > 4, let first = years.first, let last = years.last else { return years.map(String.init).joined(separator: ", ") }
        return "\(first)–\(last)"
    }
}
