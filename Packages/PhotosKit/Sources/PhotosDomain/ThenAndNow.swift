// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// A spot the user took photos at in several years: "Lisbon · 2014 · 2019 · 2025" (SPEC §15.6).
public struct ThenAndNowSpot: Hashable, Sendable, Identifiable {
    /// The photos of one year at the spot, the one that shows it best first.
    public struct Year: Hashable, Sendable, Identifiable {
        public var year: Int
        public var items: [FileID]
        public var id: Int { year }
        /// The photo the side-by-side and the time-lapse show for this year.
        public var cover: FileID { items[0] }

        public init(year: Int, items: [FileID]) {
            precondition(!items.isEmpty, "a year of a spot has photos")
            self.year = year
            self.items = items
        }
    }

    public var id: String
    public var center: GeoCoordinate
    /// The server's name of the place (most frequent among the photos), nil when it has none.
    public var placeName: String?
    public var countryCode: String?
    /// Oldest first; at least `ThenAndNow.minimumYears`.
    public var years: [Year]

    public var itemCount: Int { years.reduce(0) { $0 + $1.items.count } }
    public var allItems: [FileID] { years.flatMap(\.items) }
    /// The photos of the time-lapse and the side-by-side view, one per year, oldest first.
    public var covers: [FileID] { years.map(\.cover) }

    public init(id: String, center: GeoCoordinate, placeName: String?, countryCode: String?, years: [Year]) {
        self.id = id
        self.center = center
        self.placeName = placeName
        self.countryCode = countryCode
        self.years = years
    }
}

/// Finds "Then and now" spots on the device: geotagged photos within about 100 m of each other, taken in at least two
/// different years (SPEC §15.6). The view each year shows best is chosen by `alignedYears` once the photos are compared
/// (Vision feature prints, in PhotosMedia); without that, favourites and photos nearest the spot's middle come first.
public enum ThenAndNow {
    /// Photos within this distance (metres) count as the same spot.
    public static let radius = 100.0
    public static let minimumYears = 2
    /// The photos of one year compared with the other years' when the matching view is looked for.
    public static let comparedPerYear = 12

    /// All spots of a library, the best first: most years, then the longest time between first and last, then the most
    /// recent. Spots are discs of `radius` around the first photo taken there (oldest photos seed them), so the result
    /// does not depend on the order of the rows.
    public static func spots(_ items: [LocatedItem], calendar: Calendar = .current) -> [ThenAndNowSpot] {
        let sorted = items.filter(\.coordinate.isValid).sorted { ($0.timestamp, $0.fileId) < ($1.timestamp, $1.fileId) }
        var seeds: [GeoCoordinate] = []
        var members: [[LocatedItem]] = []
        var grid = GeoGrid<Int>(radius: radius)
        for item in sorted {
            let nearest = grid.candidates(near: item.coordinate)
                .map { (index: $0, distance: seeds[$0].distance(to: item.coordinate)) }
                .filter { $0.distance <= radius }
                .min { ($0.distance, $0.index) < ($1.distance, $1.index) }
            if let nearest {
                members[nearest.index].append(item)
            } else {
                grid.insert(seeds.count, at: item.coordinate)
                seeds.append(item.coordinate)
                members.append([item])
            }
        }
        let spots = members.compactMap { spot(of: $0, anchor: nil, calendar: calendar) }
        return spots.sorted { rank($0) > rank($1) }
    }

    /// The spot around one photo (the viewer's "Then and now"): the photos within `radius` of it, if they span at least
    /// two years. The photo itself leads its year. `nearby` may contain more (a box around it from the index).
    public static func spot(around item: LocatedItem, nearby: [LocatedItem], calendar: Calendar = .current) -> ThenAndNowSpot? {
        guard item.coordinate.isValid else { return nil }
        var close = nearby.filter { $0.fileId != item.fileId && $0.coordinate.isValid && $0.coordinate.distance(to: item.coordinate) <= radius }
        close.append(item)
        return spot(of: close, anchor: item.fileId, calendar: calendar)
    }

    /// The photos of each year of a spot, best first: the anchor, favourites, then the photos nearest its middle.
    static func spot(of items: [LocatedItem], anchor: FileID?, calendar: Calendar) -> ThenAndNowSpot? {
        var byYear: [Int: [LocatedItem]] = [:]
        for item in items { byYear[calendar.component(.year, from: item.timestamp), default: []].append(item) }
        guard byYear.count >= minimumYears else { return nil }
        var centroid = GeoCentroid()
        for item in items { centroid.add(item.coordinate) }
        guard let center = centroid.value else { return nil }
        let years = byYear.keys.sorted().map { year -> ThenAndNowSpot.Year in
            let ordered = byYear[year]!.sorted { a, b in
                let aKey = (a.fileId == anchor ? 0 : 1, a.isFavorite ? 0 : 1)
                let bKey = (b.fileId == anchor ? 0 : 1, b.isFavorite ? 0 : 1)
                if aKey != bKey { return aKey < bKey }
                let aDistance = a.coordinate.distance(to: center)
                let bDistance = b.coordinate.distance(to: center)
                if aDistance != bDistance { return aDistance < bDistance }
                return (a.timestamp, a.fileId) > (b.timestamp, b.fileId)
            }
            return ThenAndNowSpot.Year(year: year, items: ordered.map(\.fileId))
        }
        let seed = anchor.flatMap { id in items.first { $0.fileId == id } } ?? items.min { ($0.timestamp, $0.fileId) < ($1.timestamp, $1.fileId) }!
        return ThenAndNowSpot(
            id: "spot-\(seed.fileId)", center: center, placeName: mostFrequent(items.map(\.place)),
            countryCode: mostFrequent(items.map(\.countryCode)), years: years)
    }

    static func rank(_ spot: ThenAndNowSpot) -> (Int, Int, Int, Int, String) {
        let first = spot.years.first?.year ?? 0
        let last = spot.years.last?.year ?? 0
        return (spot.years.count, last - first, last, spot.itemCount, spot.id)
    }

    /// One spot per place name, best first: the row in Places and Memories shows different places, not five corners of
    /// the same city. Spots without a name are all kept.
    public static func distinctPlaces(_ spots: [ThenAndNowSpot], limit: Int) -> [ThenAndNowSpot] {
        var seen = Set<String>()
        var result: [ThenAndNowSpot] = []
        for spot in spots where result.count < limit {
            if let name = spot.placeName, !seen.insert(name).inserted { continue }
            result.append(spot)
        }
        return result
    }

    /// The photos of a year that are compared with the others: the first ones (favourites, the middle of the spot) and
    /// then evenly spread over the rest, at most `comparedPerYear`.
    public static func compared(_ year: ThenAndNowSpot.Year, limit: Int = comparedPerYear) -> [FileID] {
        let items = year.items
        guard items.count > limit, limit > 1 else { return Array(items.prefix(max(limit, 1))) }
        let head = limit / 2
        let rest = items.count - head
        let tail = limit - head
        var result = Array(items.prefix(head))
        for index in 0..<tail { result.append(items[head + index * rest / tail]) }
        return result
    }

    /// The years of a spot with the photos that show the same view first.
    ///
    /// `distance` compares two photos (smaller is more alike; nil when either could not be looked at). The anchor is
    /// chosen among the first photos of `anchorYear` (default: the newest year) as the one the other years match best;
    /// each other year then leads with its photo closest to the anchor. Years whose photos cannot be compared keep
    /// their order.
    public static func alignedYears(
        _ spot: ThenAndNowSpot, anchorYear: Int? = nil, anchorCandidates: Int = 4, distance: (FileID, FileID) -> Double?
    ) -> ThenAndNowSpot {
        guard let anchorIndex = spot.years.firstIndex(where: { $0.year == (anchorYear ?? spot.years.last?.year) }) else { return spot }
        let candidates = Array(spot.years[anchorIndex].items.prefix(max(1, anchorCandidates)))
        let others = spot.years.indices.filter { $0 != anchorIndex }
        let compared = others.map { compared(spot.years[$0]) }

        var best: (anchor: FileID, score: Double, picks: [FileID?])?
        for anchor in candidates {
            var score = 0.0
            var picks: [FileID?] = []
            for list in compared {
                let scored = list.compactMap { id in distance(anchor, id).map { (id, $0) } }
                let pick = scored.min { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 < $1.0 }
                picks.append(pick?.0)
                // A year that cannot be compared costs as much as an unlike photo.
                score += pick?.1 ?? 1_000
            }
            if best == nil || score < best!.score { best = (anchor, score, picks) }
        }
        guard let best else { return spot }
        var result = spot
        result.years[anchorIndex].items = leading(best.anchor, in: spot.years[anchorIndex].items)
        for (position, index) in others.enumerated() {
            if let pick = best.picks[position] { result.years[index].items = leading(pick, in: spot.years[index].items) }
        }
        return result
    }

    static func leading(_ id: FileID, in items: [FileID]) -> [FileID] {
        [id] + items.filter { $0 != id }
    }

    /// "Lisbon · 2014 · 2019 · 2025": the place's name (or `fallback`) and the years, as many as fit in `maximumYears`
    /// (first, …, last).
    public static func title(_ spot: ThenAndNowSpot, fallback: String, maximumYears: Int = 4) -> String {
        ([spot.placeName ?? fallback] + yearList(spot, maximum: maximumYears)).joined(separator: " · ")
    }

    /// The years as shown in a title: all when they fit, else the first ones, "…" and the last.
    public static func yearList(_ spot: ThenAndNowSpot, maximum: Int = 4) -> [String] {
        let years = spot.years.map { String($0.year) }
        guard years.count > maximum, maximum >= 2 else { return years }
        return Array(years.prefix(maximum - 1)) + ["…", years.last!]
    }
}
