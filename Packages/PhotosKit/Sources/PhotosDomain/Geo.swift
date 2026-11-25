// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// A point on the earth in degrees (WGS 84, as in EXIF and on the server).
public struct GeoCoordinate: Hashable, Sendable, Codable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Mean earth radius in metres (IUGG).
    public static let earthRadius = 6_371_008.8

    /// A usable coordinate: in range, finite, and not 0/0 (what broken GPS tags say).
    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite && abs(latitude) <= 90 && abs(longitude) <= 180 && !(latitude == 0 && longitude == 0)
    }

    /// Great-circle distance in metres (haversine).
    public func distance(to other: GeoCoordinate) -> Double {
        let φ1 = latitude * .pi / 180
        let φ2 = other.latitude * .pi / 180
        let Δφ = φ2 - φ1
        let Δλ = (other.longitude - longitude) * .pi / 180
        let a = sin(Δφ / 2) * sin(Δφ / 2) + cos(φ1) * cos(φ2) * sin(Δλ / 2) * sin(Δλ / 2)
        return 2 * Self.earthRadius * atan2(sqrt(a), sqrt(max(0, 1 - a)))
    }

    /// The middle of some coordinates (their mean, also across the antimeridian); nil for none.
    public static func center(of coordinates: [GeoCoordinate]) -> GeoCoordinate? {
        var centroid = GeoCentroid()
        for coordinate in coordinates { centroid.add(coordinate) }
        return centroid.value
    }
}

/// The mean of some coordinates, also across the antimeridian (longitudes are unwrapped around the first one).
struct GeoCentroid {
    private var latitude = 0.0
    private var longitude = 0.0
    private var reference: Double?
    private(set) var count = 0

    mutating func add(_ coordinate: GeoCoordinate, weight: Int = 1) {
        var longitude = coordinate.longitude
        if let reference {
            if longitude - reference > 180 { longitude -= 360 } else if reference - longitude > 180 { longitude += 360 }
        } else {
            reference = longitude
        }
        latitude += coordinate.latitude * Double(weight)
        self.longitude += longitude * Double(weight)
        count += weight
    }

    var value: GeoCoordinate? {
        guard count > 0 else { return nil }
        var longitude = self.longitude / Double(count)
        if longitude > 180 { longitude -= 360 } else if longitude < -180 { longitude += 360 }
        return GeoCoordinate(latitude: latitude / Double(count), longitude: longitude)
    }
}

/// Buckets coordinates into cells at least `radius` metres wide, so that everything within `radius` of a point is in
/// its cell or the eight around it. Cells of a row of latitude get wider in degrees towards the poles.
struct GeoGrid<Value> {
    struct Key: Hashable {
        var row: Int
        var column: Int
    }

    let cellDegrees: Double
    private(set) var cells: [Key: [Value]] = [:]

    init(radius: Double) {
        // One degree of latitude is 111.2 km everywhere.
        cellDegrees = max(radius / 111_195, 1e-6)
    }

    func row(of latitude: Double) -> Int { Int(((latitude + 90) / cellDegrees).rounded(.down)) }

    /// The number of cells of a row: as many as fit when each is at least `radius` wide at the row's edge nearest the
    /// pole. They divide the circle evenly, so the cells on both sides of the antimeridian are as wide as the others.
    func columns(row: Int) -> Int {
        let edge = min(90, max(abs(Double(row) * cellDegrees - 90), abs(Double(row + 1) * cellDegrees - 90)))
        let scale = cos(edge * .pi / 180)
        guard scale >= 1e-3 else { return 1 }
        return max(1, Int((360 / (cellDegrees / scale)).rounded(.down)))
    }

    /// Width of the cells of a row in degrees of longitude.
    func columnDegrees(row: Int) -> Double { 360 / Double(columns(row: row)) }

    /// The column of a longitude in a row; columns wrap around at the antimeridian.
    func column(of longitude: Double, row: Int) -> Int {
        let columns = columns(row: row)
        let raw = Int(((longitude + 180) / columnDegrees(row: row)).rounded(.down))
        return (raw % columns + columns) % columns
    }

    func key(of coordinate: GeoCoordinate) -> Key {
        let row = row(of: coordinate.latitude)
        return Key(row: row, column: column(of: coordinate.longitude, row: row))
    }

    mutating func insert(_ value: Value, at coordinate: GeoCoordinate) {
        cells[key(of: coordinate), default: []].append(value)
    }

    /// The values in the cells around a coordinate (a superset of those within `radius`), also across the antimeridian.
    func candidates(near coordinate: GeoCoordinate) -> [Value] {
        let center = row(of: coordinate.latitude)
        var result: [Value] = []
        for row in (center - 1)...(center + 1) {
            let columns = columns(row: row)
            let column = column(of: coordinate.longitude, row: row)
            var seen = Set<Int>()
            for offset in -1...1 {
                let wrapped = ((column + offset) % columns + columns) % columns
                guard seen.insert(wrapped).inserted, let values = cells[Key(row: row, column: wrapped)] else { continue }
                result += values
            }
        }
        return result
    }
}

/// What travel and "Then and now" need to know about a geotagged photo: a few columns of the index.
public struct LocatedItem: Hashable, Sendable {
    public var fileId: FileID
    public var timestamp: Date
    public var coordinate: GeoCoordinate
    /// The server's place name (`nc:metadata-photos-place`), e.g. "Lisbon".
    public var place: String?
    /// ISO 3166 country code from the server (`nc:metadata-photos-place-country`), e.g. "PT".
    public var countryCode: String?
    public var isFavorite: Bool

    public init(
        fileId: FileID, timestamp: Date, coordinate: GeoCoordinate, place: String? = nil, countryCode: String? = nil,
        isFavorite: Bool = false
    ) {
        self.fileId = fileId
        self.timestamp = timestamp
        self.coordinate = coordinate
        self.place = place.flatMap { $0.isEmpty ? nil : $0 }
        self.countryCode = countryCode.flatMap { $0.isEmpty ? nil : $0.uppercased() }
        self.isFavorite = isFavorite
    }
}

/// The most frequent of some names (ties: alphabetically first), nil when there are none.
func mostFrequent<S: Sequence>(_ names: S) -> String? where S.Element == String? {
    var counts: [String: Int] = [:]
    for case let name? in names { counts[name, default: 0] += 1 }
    return counts.min { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }?.key
}
