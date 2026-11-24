// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// A place on Earth in degrees.
public struct GeoPoint: Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// A usable coordinate: finite, in range, and not 0/0 (what cameras write when they have no fix).
    public init?(latitude: Double?, longitude: Double?) {
        guard let latitude, let longitude, latitude.isFinite, longitude.isFinite, abs(latitude) <= 90, abs(longitude) <= 180,
            !(latitude == 0 && longitude == 0)
        else { return nil }
        self.init(latitude: latitude, longitude: longitude)
    }
}

/// Where photos were taken one after the other, as stops and the distance between them (SPEC §15.1). Used for a trip
/// film's map flights and the "kilometres travelled" of the year in review. Kept small and free of map frameworks so
/// other features (the travel globe) can use it too.
public enum TravelRoute {
    /// Photos within this distance of a stop's first photo belong to the stop.
    public static let stopRadiusKilometres = 25.0
    /// A lone far-away photo between two photos of one stop taken within this many hours is a detour, not a stop.
    public static let detourHours = 6.0
    /// Mean Earth radius (IUGG).
    static let earthRadiusKilometres = 6371.0088

    /// One place the photos stayed at for a while.
    public struct Stop: Hashable, Sendable {
        /// The mean position of the stop's photos.
        public var centre: GeoPoint
        /// The most frequent place name of its photos, if they have any.
        public var name: String?
        /// Indexes (into the points given to `stops`) of the photos taken there.
        public var members: [Int]
        public var start: Date
        public var end: Date
    }

    /// One located photo.
    public struct Point: Hashable, Sendable {
        public var location: GeoPoint
        public var date: Date
        public var name: String?

        public init(location: GeoPoint, date: Date, name: String? = nil) {
            self.location = location
            self.date = date
            self.name = name
        }
    }

    /// Great-circle distance in kilometres (haversine).
    public static func distance(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadiusKilometres * asin(min(1, sqrt(h)))
    }

    /// The stops of photos in the order they were taken: consecutive photos within `radius` of the stop's first photo
    /// form one stop. A single photo far away within a few hours between two photos of the same stop (a wrong GPS fix, a
    /// photo someone sent) is not a stop of its own; it is left out.
    public static func stops(_ points: [Point], radius: Double = stopRadiusKilometres) -> [Stop] {
        let order = points.indices.sorted { points[$0].date < points[$1].date }
        var groups: [[Int]] = []
        var anchors: [GeoPoint] = []
        for index in order {
            let location = points[index].location
            if let anchor = anchors.last, distance(anchor, location) <= radius {
                groups[groups.count - 1].append(index)
            } else {
                groups.append([index])
                anchors.append(location)
            }
        }
        // A one-photo detour between two parts of the same stop: drop it and join the parts.
        var merged: [[Int]] = []
        var mergedAnchors: [GeoPoint] = []
        var position = 0
        while position < groups.count {
            let group = groups[position]
            if group.count == 1, let previous = mergedAnchors.last, position + 1 < groups.count,
                distance(previous, anchors[position + 1]) <= radius,
                let before = merged.last?.last, let after = groups[position + 1].first,
                points[after].date.timeIntervalSince(points[before].date) <= detourHours * 3600
            {
                merged[merged.count - 1] += groups[position + 1]
                position += 2
                continue
            }
            merged.append(group)
            mergedAnchors.append(anchors[position])
            position += 1
        }
        return merged.map { members in
            let latitude = members.map { points[$0].location.latitude }.reduce(0, +) / Double(members.count)
            let longitude = members.map { points[$0].location.longitude }.reduce(0, +) / Double(members.count)
            var counts: [String: Int] = [:]
            for member in members { if let name = points[member].name, !name.isEmpty { counts[name, default: 0] += 1 } }
            let name = counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
            let dates = members.map { points[$0].date }
            return Stop(
                centre: GeoPoint(latitude: latitude, longitude: longitude), name: name, members: members, start: dates.min()!,
                end: dates.max()!)
        }
    }

    /// Kilometres between consecutive stops, as the crow flies.
    public static func kilometres(_ stops: [Stop]) -> Double {
        zip(stops, stops.dropFirst()).reduce(0) { $0 + distance($1.0.centre, $1.1.centre) }
    }
}

/// Where a set of photos was taken (SPEC §15.1): distinct places and countries, and the kilometres between the stops.
public struct TravelStats: Hashable, Sendable {
    /// Distinct place names, most photographed first.
    public var places: [String]
    /// Distinct countries (from the server's place data; empty when the server has none), most photographed first.
    public var countries: [String]
    /// Between consecutive stops, as the crow flies.
    public var kilometres: Double
    public var stops: [TravelRoute.Stop]

    /// One photo's place data.
    public struct Sample: Hashable, Sendable {
        public var location: GeoPoint?
        public var date: Date
        public var place: String?
        public var country: String?

        public init(location: GeoPoint?, date: Date, place: String? = nil, country: String? = nil) {
            self.location = location
            self.date = date
            self.place = place
            self.country = country
        }
    }

    public init(_ samples: [Sample]) {
        places = Self.ranked(samples.compactMap(\.place))
        countries = Self.ranked(samples.compactMap(\.country))
        let points = samples.compactMap { sample in
            sample.location.map { TravelRoute.Point(location: $0, date: sample.date, name: sample.place) }
        }
        stops = TravelRoute.stops(points)
        kilometres = TravelRoute.kilometres(stops)
    }

    /// Distinct non-empty names, most frequent first (ties by name).
    static func ranked(_ names: [String]) -> [String] {
        var counts: [String: Int] = [:]
        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { counts[trimmed, default: 0] += 1 }
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }
}
