// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// Where the user has been, from the geotagged photos of the library (SPEC §15.6): stays, places, home, trips and
/// countries, with stats such as "37 countries · 412 000 km". Built on the device from a few columns of the index; a
/// value, so any screen (the travel globe, Year in Review, a widget) can build it and ask it for a year.
///
/// - A **visit** is a run of consecutive photos within `visitRadius` of where it started, without a gap of more than
///   `visitGap`.
/// - A **place** is all visits within `placeRadius` of each other (the largest visit seeds it), named after the server's
///   most frequent place name of its photos.
/// - **Home** is the place photographed on the most different days; everything within `homeRadius` of it counts as home.
/// - A **trip** is a run of visits away from home, ended by a visit at home or a gap of more than `tripGap`. Its path goes
///   from home through its visits and back home; the distance travelled is the length of these paths.
/// - A visit's **country** is the server's country code of most of its photos, else that of its place
///   (`assigningCountries`, from reverse geocoding on the device when the server has none).
public struct TravelHistory: Sendable, Equatable {
    public struct Visit: Hashable, Sendable, Identifiable {
        public var id: Int
        public var coordinate: GeoCoordinate
        public var start: Date
        public var end: Date
        /// Oldest first.
        public var items: [FileID]
        public var cover: FileID
        public var placeName: String?
        public var countryCode: String?
        /// Index into `places`.
        public var place: Int
    }

    public struct Place: Hashable, Sendable, Identifiable {
        public var id: Int
        public var coordinate: GeoCoordinate
        public var name: String?
        public var countryCode: String?
        /// Indexes into `visits`, oldest first.
        public var visits: [Int]
        public var itemCount: Int
        public var cover: FileID
        public var firstVisit: Date
        public var lastVisit: Date
    }

    public struct Trip: Hashable, Sendable, Identifiable {
        public var id: Int
        public var start: Date
        public var end: Date
        /// Indexes into `visits`, in time order.
        public var visits: [Int]
        /// Home, the visits, home again (without home when there is none, or the trip starts or ends there).
        public var path: [GeoCoordinate]
        /// Length of `path` in metres.
        public var distance: Double
        public var itemCount: Int
        public var cover: FileID
        /// The places' names in order of the photos taken there, most first ("Lisbon & Porto"); empty when none has one.
        public var placeNames: [String]
    }

    public struct Country: Hashable, Sendable, Identifiable {
        /// ISO 3166-1 alpha-2.
        public var code: String
        public var id: String { code }
        public var firstVisit: Date
        public var lastVisit: Date
        /// Years with visits, oldest first.
        public var years: [Int]
        public var itemCount: Int
        /// Indexes into `places`.
        public var places: [Int]
        public var cover: FileID
    }

    public struct Stats: Hashable, Sendable {
        public var countries: Int
        public var places: Int
        public var trips: Int
        /// Metres along the trips' paths.
        public var distance: Double
        public var items: Int
        /// The place farthest from home, and how far (metres).
        public var farthest: (place: Int, distance: Double)?

        public static func == (a: Stats, b: Stats) -> Bool {
            a.countries == b.countries && a.places == b.places && a.trips == b.trips && a.distance == b.distance && a.items == b.items
                && a.farthest?.place == b.farthest?.place && a.farthest?.distance == b.farthest?.distance
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(countries)
            hasher.combine(places)
            hasher.combine(trips)
            hasher.combine(distance)
            hasher.combine(items)
        }
    }

    public static let visitRadius = 25_000.0
    public static let visitGap: TimeInterval = 2 * 86_400
    public static let placeRadius = 25_000.0
    public static let homeRadius = 50_000.0
    public static let tripGap: TimeInterval = 4 * 86_400

    public var visits: [Visit]
    public var places: [Place]
    public var trips: [Trip]
    /// Index into `places`.
    public var home: Int?
    let calendar: Calendar

    public static func == (a: TravelHistory, b: TravelHistory) -> Bool {
        a.visits == b.visits && a.places == b.places && a.trips == b.trips && a.home == b.home
    }

    /// An empty history.
    public init(calendar: Calendar = .current) {
        visits = []
        places = []
        trips = []
        home = nil
        self.calendar = calendar
    }

    /// Builds the history of some geotagged photos (in any order; invalid coordinates are left out).
    public init(_ items: [LocatedItem], calendar: Calendar = .current) {
        self.calendar = calendar
        let sorted = items.filter(\.coordinate.isValid).sorted { ($0.timestamp, $0.fileId) < ($1.timestamp, $1.fileId) }
        let groups = Self.visitGroups(sorted)
        let (places, assignment) = Self.places(of: groups)
        visits = groups.enumerated().map { index, group in
            var centroid = GeoCentroid()
            for item in group { centroid.add(item.coordinate) }
            return Visit(
                id: index, coordinate: centroid.value!, start: group.first!.timestamp, end: group.last!.timestamp, items: group.map(\.fileId),
                cover: Self.cover(of: group), placeName: mostFrequent(group.map(\.place)),
                countryCode: mostFrequent(group.map(\.countryCode)), place: assignment[index])
        }
        self.places = places.enumerated().map { index, members in
            var centroid = GeoCentroid()
            var names: [String?] = []
            var countries: [String?] = []
            for visit in members {
                centroid.add(groups[visit][0].coordinate, weight: groups[visit].count)
                names += groups[visit].map(\.place)
                countries += groups[visit].map(\.countryCode)
            }
            let largest = members.max { (groups[$0].count, -$0) < (groups[$1].count, -$1) }!
            return Place(
                id: index, coordinate: centroid.value!, name: mostFrequent(names), countryCode: mostFrequent(countries), visits: members,
                itemCount: members.reduce(0) { $0 + groups[$1].count }, cover: Self.cover(of: groups[largest]),
                firstVisit: groups[members.first!].first!.timestamp, lastVisit: groups[members.last!].last!.timestamp)
        }
        home = Self.home(places: self.places, visits: visits, calendar: calendar)
        trips = []
        trips = makeTrips()
    }

    /// Consecutive photos near where the visit started and without a long gap.
    static func visitGroups(_ sorted: [LocatedItem]) -> [[LocatedItem]] {
        var groups: [[LocatedItem]] = []
        var seed: GeoCoordinate?
        for item in sorted {
            if let seed, let last = groups.last?.last, item.timestamp.timeIntervalSince(last.timestamp) <= visitGap,
                seed.distance(to: item.coordinate) <= visitRadius
            {
                groups[groups.count - 1].append(item)
            } else {
                groups.append([item])
                seed = item.coordinate
            }
        }
        return groups
    }

    /// Visits within `placeRadius` of a place's first (largest) visit belong to it. Returns the places' visits (oldest
    /// first, places ordered by their first visit) and each visit's place.
    static func places(of groups: [[LocatedItem]]) -> (places: [[Int]], assignment: [Int]) {
        let bySize = groups.indices.sorted { (groups[$0].count, -$0) > (groups[$1].count, -$1) }
        var seeds: [GeoCoordinate] = []
        var members: [[Int]] = []
        var grid = GeoGrid<Int>(radius: placeRadius)
        for visit in bySize {
            let coordinate = groups[visit][0].coordinate
            let nearest = grid.candidates(near: coordinate)
                .map { (index: $0, distance: seeds[$0].distance(to: coordinate)) }
                .filter { $0.distance <= placeRadius }
                .min { ($0.distance, $0.index) < ($1.distance, $1.index) }
            if let nearest {
                members[nearest.index].append(visit)
            } else {
                grid.insert(seeds.count, at: coordinate)
                seeds.append(coordinate)
                members.append([visit])
            }
        }
        let places = members.map { $0.sorted() }.sorted { $0[0] < $1[0] }
        var assignment = [Int](repeating: 0, count: groups.count)
        for (index, visits) in places.enumerated() { for visit in visits { assignment[visit] = index } }
        return (places, assignment)
    }

    /// A favourite, else the photo in the middle.
    static func cover(of group: [LocatedItem]) -> FileID {
        (group.first(where: \.isFavorite) ?? group[group.count / 2]).fileId
    }

    /// The place with photos on the most different days (ties: the most photos, then the first).
    static func home(places: [Place], visits: [Visit], calendar: Calendar) -> Int? {
        var best: (place: Int, days: Int, items: Int)?
        for place in places {
            var days = Set<DateComponents>()
            for visit in place.visits {
                var day = visits[visit].start
                // Each day of the visit counts (a stay of a week at home is seven days).
                while day <= visits[visit].end {
                    days.insert(calendar.dateComponents([.year, .month, .day], from: day))
                    guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                    day = next
                }
                days.insert(calendar.dateComponents([.year, .month, .day], from: visits[visit].end))
            }
            if best == nil || (days.count, place.itemCount) > (best!.days, best!.items) {
                best = (place.id, days.count, place.itemCount)
            }
        }
        return best?.place
    }

    func isAtHome(_ visit: Visit) -> Bool {
        guard let home else { return false }
        return visit.place == home || visit.coordinate.distance(to: places[home].coordinate) <= Self.homeRadius
    }

    func makeTrips() -> [Trip] {
        var runs: [[Int]] = []
        var current: [Int] = []
        for visit in visits {
            if isAtHome(visit) {
                if !current.isEmpty { runs.append(current) }
                current = []
                continue
            }
            if let last = current.last, visit.start.timeIntervalSince(visits[last].end) > Self.tripGap {
                runs.append(current)
                current = []
            }
            current.append(visit.id)
        }
        if !current.isEmpty { runs.append(current) }
        let homeCoordinate = home.map { places[$0].coordinate }
        return runs.enumerated().map { index, run in
            let stops = run.map { visits[$0].coordinate }
            let path = homeCoordinate.map { [$0] + stops + [$0] } ?? stops
            var distance = 0.0
            for (a, b) in zip(path, path.dropFirst()) { distance += a.distance(to: b) }
            var counts: [String: Int] = [:]
            for visit in run { if let name = places[visits[visit].place].name { counts[name, default: 0] += visits[visit].items.count } }
            let names = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
            let items = run.reduce(0) { $0 + visits[$1].items.count }
            let largest = run.max { (visits[$0].items.count, -$0) < (visits[$1].items.count, -$1) }!
            return Trip(
                id: index, start: visits[run.first!].start, end: visits[run.last!].end, visits: run, path: path, distance: distance,
                itemCount: items, cover: visits[largest].cover, placeNames: names)
        }
    }

    // MARK: Years

    /// Years with photos, newest first (the year filter).
    public var years: [Int] {
        Set(visits.map { calendar.component(.year, from: $0.start) }).sorted(by: >)
    }

    func isIn(_ year: Int?, _ start: Date, _ end: Date) -> Bool {
        guard let year else { return true }
        return calendar.component(.year, from: start) <= year && calendar.component(.year, from: end) >= year
    }

    /// The trips of a year (those that started or ended in it), all with nil.
    public func trips(in year: Int?) -> [Trip] {
        trips.filter { isIn(year, $0.start, $0.end) }
    }

    /// The visits of a year.
    public func visits(in year: Int?) -> [Visit] {
        visits.filter { isIn(year, $0.start, $0.end) }
    }

    /// The places visited in a year, most photos first.
    public func places(in year: Int?) -> [Place] {
        let ids = Set(visits(in: year).map(\.place))
        return places.filter { ids.contains($0.id) }.sorted { ($0.itemCount, -$0.id) > ($1.itemCount, -$1.id) }
    }

    // MARK: Countries

    /// A visit's country: its photos' (from the server), else its place's.
    public func countryCode(of visit: Visit) -> String? {
        visit.countryCode ?? places[visit.place].countryCode
    }

    /// The countries visited in a year (all with nil), in order of the first visit.
    public func countries(in year: Int? = nil) -> [Country] {
        var result: [String: Country] = [:]
        var order: [String] = []
        for visit in visits(in: year) {
            guard let code = countryCode(of: visit) else { continue }
            let visitYear = calendar.component(.year, from: visit.start)
            if var country = result[code] {
                country.lastVisit = max(country.lastVisit, visit.end)
                if !country.years.contains(visitYear) { country.years.append(visitYear) }
                country.itemCount += visit.items.count
                if !country.places.contains(visit.place) { country.places.append(visit.place) }
                result[code] = country
            } else {
                order.append(code)
                result[code] = Country(
                    code: code, firstVisit: visit.start, lastVisit: visit.end, years: [visitYear], itemCount: visit.items.count,
                    places: [visit.place], cover: places[visit.place].cover)
            }
        }
        return order.compactMap { code in
            guard var country = result[code] else { return nil }
            country.years.sort()
            // The cover of the place with the most photos in the country.
            if let place = country.places.max(by: { (places[$0].itemCount, -$0) < (places[$1].itemCount, -$1) }) {
                country.cover = places[place].cover
            }
            return country
        }
    }

    /// The places without a country, largest first: what reverse geocoding on the device has to look up.
    public var placesWithoutCountry: [Place] {
        places.filter { place in place.countryCode == nil && place.visits.contains { visits[$0].countryCode == nil } }
            .sorted { ($0.itemCount, -$0.id) > ($1.itemCount, -$1.id) }
    }

    /// The history with countries found on the device for places the server knows none for.
    public func assigningCountries(_ codes: [Int: String]) -> TravelHistory {
        var copy = self
        for (place, code) in codes where copy.places.indices.contains(place) && copy.places[place].countryCode == nil {
            copy.places[place].countryCode = code.uppercased()
        }
        return copy
    }

    // MARK: Stats

    /// Countries, places, trips and distance of a year (all with nil).
    public func stats(in year: Int? = nil) -> Stats {
        let visits = visits(in: year)
        let trips = trips(in: year)
        let placeIds = Set(visits.map(\.place))
        var farthest: (place: Int, distance: Double)?
        if let home {
            for place in placeIds {
                let distance = places[place].coordinate.distance(to: places[home].coordinate)
                if farthest == nil || distance > farthest!.distance { farthest = (place, distance) }
            }
        }
        return Stats(
            countries: countries(in: year).count, places: placeIds.count, trips: trips.count,
            distance: trips.reduce(0) { $0 + $1.distance }, items: visits.reduce(0) { $0 + $1.items.count },
            farthest: farthest.flatMap { $0.distance > 0 ? $0 : nil })
    }

    /// The photos of a place (in a year), oldest first.
    public func items(ofPlace place: Int, in year: Int? = nil) -> [FileID] {
        guard places.indices.contains(place) else { return [] }
        return places[place].visits.map { visits[$0] }.filter { isIn(year, $0.start, $0.end) }.flatMap(\.items)
    }

    /// The photos of a trip, oldest first.
    public func items(ofTrip trip: Trip) -> [FileID] {
        trip.visits.flatMap { visits[$0].items }
    }

    /// The photos taken in a country (in a year), oldest first.
    public func items(inCountry code: String, year: Int? = nil) -> [FileID] {
        visits(in: year).filter { countryCode(of: $0) == code }.flatMap(\.items)
    }
}

extension TravelHistory {
    /// The flag of a country code ("PT" → 🇵🇹), nil for codes that are not two letters.
    public static func flag(_ code: String) -> String? {
        let letters = code.uppercased().unicodeScalars
        guard letters.count == 2, letters.allSatisfy({ $0.value >= 65 && $0.value <= 90 }) else { return nil }
        var flag = ""
        for letter in letters { flag.unicodeScalars.append(UnicodeScalar(127_397 + letter.value)!) }
        return flag
    }

    /// Countries of the world as most people count them (UN members), for "12 % of the world".
    public static let worldCountries = 195

    /// The share of the world's countries, 0…1.
    public static func worldShare(_ countries: Int) -> Double {
        min(1, Double(countries) / Double(worldCountries))
    }
}
