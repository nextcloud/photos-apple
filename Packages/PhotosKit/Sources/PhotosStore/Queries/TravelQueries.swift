// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import PhotosDomain
import PhotosModel

/// The geotagged photos for the travel globe and "Then and now" (SPEC §15.6): six columns of the located rows, read
/// through the coordinate index; the items themselves are never loaded.
extension LibraryStore {
    static let locatedColumns =
        "media.fileId, \(timestamp), media.latitude, media.longitude, media.place, media.placeCountry, media.isFavorite"

    static func fetchLocated(_ db: Database, sql: String, arguments: StatementArguments = []) throws -> [LocatedItem] {
        var result: [LocatedItem] = []
        let rows = try Row.fetchCursor(db, sql: sql, arguments: arguments)
        while let row = try rows.next() {
            let item = LocatedItem(
                fileId: row[0], timestamp: Date(timeIntervalSince1970: row[1] ?? 0),
                coordinate: GeoCoordinate(latitude: row[2], longitude: row[3]), place: row[4], countryCode: row[5], isFavorite: row[6])
            if item.coordinate.isValid { result.append(item) }
        }
        return result
    }

    /// Every visible geotagged photo.
    public func locatedItems() async throws -> [LocatedItem] {
        let sql = "SELECT \(Self.locatedColumns) FROM media WHERE \(Self.located)"
        return try await database.writer.read { db in try Self.fetchLocated(db, sql: sql) }
    }

    /// The box around a coordinate that contains everything within `radius` metres (a little more: the corners), as a
    /// latitude range and one or two longitude ranges (two where it crosses the antimeridian).
    static func box(around center: GeoCoordinate, radius: Double) -> (latitude: ClosedRange<Double>, longitudes: [ClosedRange<Double>]) {
        let latitudeReach = radius / 111_195
        let scale = max(cos(min(89.9, abs(center.latitude) + latitudeReach) * .pi / 180), 1e-3)
        let longitudeReach = min(180, latitudeReach / scale)
        let latitude = max(-90, center.latitude - latitudeReach)...min(90, center.latitude + latitudeReach)
        let west = center.longitude - longitudeReach
        let east = center.longitude + longitudeReach
        if longitudeReach >= 180 { return (latitude, [-180...180]) }
        if west < -180 { return (latitude, [(west + 360)...180, -180...east]) }
        if east > 180 { return (latitude, [west...180, -180...(east - 360)]) }
        return (latitude, [west...east])
    }

    /// The condition of the located items in the box around a coordinate.
    static func nearCondition(_ center: GeoCoordinate, radius: Double) -> (String, StatementArguments) {
        let box = box(around: center, radius: radius)
        var arguments: StatementArguments = [box.latitude.lowerBound, box.latitude.upperBound]
        var ranges: [String] = []
        for range in box.longitudes {
            arguments += [range.lowerBound, range.upperBound]
            ranges.append("(media.longitude >= ? AND media.longitude <= ?)")
        }
        return ("\(located) AND media.latitude >= ? AND media.latitude <= ? AND (\(ranges.joined(separator: " OR ")))", arguments)
    }

    /// The geotagged photos around a coordinate (a box a little larger than `radius`; callers measure the distance).
    public func locatedItems(near center: GeoCoordinate, radius: Double) throws -> [LocatedItem] {
        let (condition, arguments) = Self.nearCondition(center, radius: radius)
        return try database.writer.read { db in
            try Self.fetchLocated(db, sql: "SELECT \(Self.locatedColumns) FROM media WHERE \(condition)", arguments: arguments)
        }
    }

    /// The "Then and now" spot around a photo (SPEC §15.6), nil when it has no location or no photos from other years
    /// near it. Synchronous and cheap (a box of the coordinate index), so a menu can ask while it opens.
    public func thenAndNowSpot(around fileId: FileID, calendar: Calendar = .current) throws -> ThenAndNowSpot? {
        try database.writer.read { db in
            let sql = "SELECT \(Self.locatedColumns) FROM media WHERE media.fileId = ? AND \(Self.located)"
            guard let item = try Self.fetchLocated(db, sql: sql, arguments: [fileId]).first else { return nil }
            let (condition, arguments) = Self.nearCondition(item.coordinate, radius: ThenAndNow.radius)
            let nearby = try Self.fetchLocated(db, sql: "SELECT \(Self.locatedColumns) FROM media WHERE \(condition)", arguments: arguments)
            return ThenAndNow.spot(around: item, nearby: nearby, calendar: calendar)
        }
    }
}
