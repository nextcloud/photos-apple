// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

#if canImport(FoundationXML)
    import FoundationXML
#endif

/// A recorded track: positions with times, from a GPX or KML file (SPEC §16.4 GPX geotagging).
public struct GeoTrack: Hashable, Sendable {
    public struct Point: Hashable, Sendable {
        public var time: Date
        public var latitude: Double
        public var longitude: Double
        public var altitude: Double?

        public init(time: Date, latitude: Double, longitude: Double, altitude: Double? = nil) {
            self.time = time
            self.latitude = latitude
            self.longitude = longitude
            self.altitude = altitude
        }
    }

    /// Sorted by time; points without a time are not kept (they cannot be matched).
    public var points: [Point]
    public var name: String?

    public init(points: [Point], name: String? = nil) {
        self.points = points.sorted { $0.time < $1.time }
        self.name = name
    }

    public var start: Date? { points.first?.time }
    public var end: Date? { points.last?.time }

    public enum ParseError: Error, Equatable {
        /// Not GPX or KML, or no point with a time in it.
        case noTimedPoints
        case unreadable
    }

    /// Reads GPX (`trkpt`, `wpt`, `rtept` with `<time>`) or KML (`gx:Track` with `when`/`gx:coord`, placemarks with a
    /// `TimeStamp` and a `Point`). Several files make one track (`merged`).
    public static func parse(_ data: Data) throws -> GeoTrack {
        let delegate = TrackParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        guard parser.parse() || !delegate.points.isEmpty else { throw ParseError.unreadable }
        delegate.finishTrack()
        guard !delegate.points.isEmpty else { throw ParseError.noTimedPoints }
        return GeoTrack(points: delegate.points, name: delegate.name)
    }

    public static func merged(_ tracks: [GeoTrack]) -> GeoTrack {
        GeoTrack(points: tracks.flatMap(\.points), name: tracks.compactMap(\.name).first)
    }

    /// ISO 8601 times as GPX and KML write them (with or without fractions, `Z` or an offset).
    static func date(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let date = try? Date(trimmed, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
        if let date = try? Date(trimmed, strategy: Date.ISO8601FormatStyle()) { return date }
        // Without a zone: GPX requires UTC.
        if let date = try? Date(trimmed + "Z", strategy: Date.ISO8601FormatStyle()) { return date }
        return nil
    }
}

/// SAX parser for GPX and KML.
private final class TrackParser: NSObject, XMLParserDelegate {
    var points: [GeoTrack.Point] = []
    var name: String?
    private var text = ""
    private var path: [String] = []
    // GPX point being read.
    private var latitude: Double?
    private var longitude: Double?
    private var elevation: Double?
    private var time: Date?
    // KML gx:Track: `when` and `gx:coord` come as two lists of the same length.
    private var whens: [Date?] = []
    private var coords: [(Double, Double, Double?)] = []
    // KML placemark.
    private var placemarkTime: Date?
    private var placemarkCoordinate: (Double, Double, Double?)?

    static func local(_ name: String) -> String { name.split(separator: ":").last.map(String.init) ?? name }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        let element = Self.local(elementName)
        path.append(element)
        text = ""
        switch element {
        case "trkpt", "wpt", "rtept":
            latitude = attributes["lat"].flatMap(Double.init)
            longitude = attributes["lon"].flatMap(Double.init)
            elevation = nil
            time = nil
        case "Placemark":
            placemarkTime = nil
            placemarkCoordinate = nil
        case "Track":
            whens = []
            coords = []
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let element = Self.local(elementName)
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer {
            if !path.isEmpty { path.removeLast() }
            text = ""
        }
        let parent = path.dropLast().last
        switch element {
        case "ele": elevation = Double(value)
        case "time":
            time = GeoTrack.date(value)
        case "name" where name == nil && (parent == "trk" || parent == "metadata" || parent == "Document"):
            name = value.isEmpty ? nil : value
        case "trkpt", "wpt", "rtept":
            if let latitude, let longitude, let time, Self.valid(latitude, longitude) {
                points.append(.init(time: time, latitude: latitude, longitude: longitude, altitude: elevation))
            }
        case "when":
            if parent == "Track" {
                whens.append(GeoTrack.date(value))
            } else {
                // TimeStamp/when of a placemark.
                placemarkTime = GeoTrack.date(value)
            }
        case "coord":
            let parts = value.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
            if parts.count >= 2 { coords.append((parts[1], parts[0], parts.count > 2 ? parts[2] : nil)) }
        case "coordinates" where path.contains("Point"):
            let parts = value.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count >= 2 { placemarkCoordinate = (parts[1], parts[0], parts.count > 2 ? parts[2] : nil) }
        case "Track":
            finishTrack()
        case "Placemark":
            if let placemarkTime, let coordinate = placemarkCoordinate, Self.valid(coordinate.0, coordinate.1) {
                points.append(.init(time: placemarkTime, latitude: coordinate.0, longitude: coordinate.1, altitude: coordinate.2))
            }
        default: break
        }
    }

    func finishTrack() {
        for (when, coord) in zip(whens, coords) {
            guard let when, Self.valid(coord.0, coord.1) else { continue }
            points.append(.init(time: when, latitude: coord.0, longitude: coord.1, altitude: coord.2))
        }
        whens = []
        coords = []
    }

    static func valid(_ latitude: Double, _ longitude: Double) -> Bool {
        abs(latitude) <= 90 && abs(longitude) <= 180 && !(latitude == 0 && longitude == 0)
    }
}

/// Finds positions for photos in a track by time (SPEC §16.4).
public enum GeoTagger {
    public struct Match: Hashable, Sendable {
        public var fileId: FileID
        public var latitude: Double
        public var longitude: Double
        public var altitude: Double?
        /// Seconds between the photo and the nearest track point.
        public var distance: TimeInterval
        /// Between two points (interpolated) rather than taken from one.
        public var interpolated: Bool
    }

    /// Positions for the photos.
    /// - Parameters:
    ///   - offset: seconds added to each photo's capture time before matching (the camera clock's error or its zone).
    ///   - tolerance: the longest time between a photo and the nearest track point.
    ///   - interpolationGap: two points further apart than this are not interpolated between (a gap in the recording,
    ///     a train ride): the nearer one is used if it is within the tolerance.
    public static func match(
        _ items: [MediaItem], track: GeoTrack, offset: TimeInterval = 0, tolerance: TimeInterval = 5 * 60,
        interpolationGap: TimeInterval = 15 * 60
    ) -> [Match] {
        let points = track.points
        guard !points.isEmpty else { return [] }
        let times = points.map(\.time.timeIntervalSince1970)
        var result: [Match] = []
        for item in items {
            let t = item.timestamp.timeIntervalSince1970 + offset
            // First index with time >= t.
            var low = 0
            var high = times.count
            while low < high {
                let mid = (low + high) / 2
                if times[mid] < t { low = mid + 1 } else { high = mid }
            }
            let after = low < points.count ? low : nil
            let before = low > 0 ? low - 1 : nil
            if let b = before, let a = after, times[a] - times[b] <= interpolationGap, times[a] > times[b] {
                // Close points: the recording was continuous here, so the position between them is good enough.
                let distance = min(t - times[b], times[a] - t)
                let fraction = (t - times[b]) / (times[a] - times[b])
                let p0 = points[b]
                let p1 = points[a]
                let altitude: Double? = {
                    guard let a0 = p0.altitude, let a1 = p1.altitude else { return p0.altitude ?? p1.altitude }
                    return a0 + (a1 - a0) * fraction
                }()
                result.append(
                    Match(
                        fileId: item.fileId, latitude: p0.latitude + (p1.latitude - p0.latitude) * fraction,
                        longitude: interpolateLongitude(p0.longitude, p1.longitude, fraction), altitude: altitude, distance: distance,
                        interpolated: true))
                continue
            }
            // The nearest single point.
            let candidates = [before, after].compactMap { $0 }
            guard let nearest = candidates.min(by: { abs(times[$0] - t) < abs(times[$1] - t) }) else { continue }
            let distance = abs(times[nearest] - t)
            guard distance <= tolerance else { continue }
            let point = points[nearest]
            result.append(
                Match(
                    fileId: item.fileId, latitude: point.latitude, longitude: point.longitude, altitude: point.altitude,
                    distance: distance, interpolated: false))
        }
        return result
    }

    /// Between two longitudes the short way round (across ±180°).
    static func interpolateLongitude(_ a: Double, _ b: Double, _ fraction: Double) -> Double {
        var delta = b - a
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        var value = a + delta * fraction
        if value > 180 { value -= 360 }
        if value < -180 { value += 360 }
        return value
    }

    /// The camera clock offset that matches the most photos: whole quarter hours from −14 h to +14 h (time zones), and
    /// the one closest to zero among equals. Photos that already have a position are used first when there are any
    /// (their positions must agree with the track); else the photos to be tagged are counted.
    public static func suggestedOffset(
        for items: [MediaItem], track: GeoTrack, tolerance: TimeInterval = 5 * 60
    ) -> TimeInterval? {
        guard !items.isEmpty, !track.points.isEmpty else { return nil }
        let located = items.filter(\.hasLocation)
        var best: (offset: TimeInterval, score: Double)?
        for step in -56...56 {
            let offset = TimeInterval(step) * 900
            let score: Double
            if located.count >= 3 {
                // Agreement of known positions: matches closer than 1 km count.
                let matches = match(located, track: track, offset: offset, tolerance: tolerance)
                let byId = Dictionary(uniqueKeysWithValues: located.map { ($0.fileId, $0) })
                score = Double(
                    matches.filter { match in
                        guard let item = byId[match.fileId], let lat = item.latitude, let lon = item.longitude else { return false }
                        return GeoCoordinate(latitude: lat, longitude: lon).distance(
                            to: GeoCoordinate(latitude: match.latitude, longitude: match.longitude)) < 1000
                    }.count)
            } else {
                score = Double(match(items, track: track, offset: offset, tolerance: tolerance).count)
            }
            guard score > 0 else { continue }
            if let current = best {
                if score > current.score || (score == current.score && abs(offset) < abs(current.offset)) {
                    best = (offset, score)
                }
            } else {
                best = (offset, score)
            }
        }
        return best?.offset
    }
}
