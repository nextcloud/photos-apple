// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import PhotosDomain
import PhotosModel

extension LibraryStore {
    // MARK: Map

    static let located =
        "\(visible) AND media.latitude IS NOT NULL AND media.longitude IS NOT NULL AND NOT (media.latitude = 0 AND media.longitude = 0)"

    static let inRegion = "media.latitude >= ? AND media.latitude <= ? AND media.longitude >= ? AND media.longitude <= ?"

    static func arguments(_ region: MapRegion) -> StatementArguments {
        [region.minLatitude, region.maxLatitude, region.minLongitude, region.maxLongitude]
    }

    /// The located items of a region, within a period when the map is filtered by time.
    static func mapCondition(_ region: MapRegion, period: Range<Date>?) -> (String, StatementArguments) {
        guard let period else { return ("\(located) AND \(inRegion)", arguments(region)) }
        return (
            "\(located) AND \(inRegion) AND \(timestamp) >= ? AND \(timestamp) < ?",
            arguments(region) + [period.lowerBound.timeIntervalSince1970, period.upperBound.timeIntervalSince1970]
        )
    }

    /// The grid cell of a coordinate, as SQL. The offsets keep the values positive, so the cast rounds down.
    static let cellRow = "CAST((media.latitude + 90.0) / ? AS INTEGER)"
    static let cellColumn = "CAST((media.longitude + 180.0) / ? AS INTEGER)"

    /// Geotagged items of a region, aggregated into grid cells by the database (SPEC MP-1): the map never holds the
    /// located items themselves, only one row per cell. With a `period` only the items taken then (time slider).
    public func mapCells(in region: MapRegion, cellLatitude: Double, cellLongitude: Double, during period: Range<Date>? = nil)
        async throws -> [MapCell]
    {
        guard cellLatitude > 0, cellLongitude > 0 else { return [] }
        let (condition, conditionArguments) = Self.mapCondition(region, period: period)
        return try await database.writer.read { db in
            let sql = """
                SELECT \(Self.cellRow) AS cellRow, \(Self.cellColumn) AS cellColumn, COUNT(*), MAX(media.fileId)
                FROM media WHERE \(condition) GROUP BY cellRow, cellColumn
                """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [cellLatitude, cellLongitude] + conditionArguments)
            let coverIds: [FileID] = rows.map { $0[3] }
            let covers = try Self.gridMedia(db, coverIds)
            var coordinates: [FileID: (Double, Double, String?)] = [:]
            for chunk in coverIds.chunked(500) {
                let list = chunk.map { String($0) }.joined(separator: ",")
                for row in try Row.fetchAll(db, sql: "SELECT fileId, latitude, longitude, place FROM media WHERE fileId IN (\(list))") {
                    coordinates[row[0]] = (row[1], row[2], row[3])
                }
            }
            return rows.compactMap { row -> MapCell? in
                let coverId: FileID = row[3]
                guard let cover = covers[coverId], let coordinate = coordinates[coverId] else { return nil }
                return MapCell(
                    row: row[0], column: row[1], count: row[2], cover: cover, latitude: coordinate.0, longitude: coordinate.1,
                    place: coordinate.2.flatMap { $0.isEmpty ? nil : $0 }, region: region, cellLatitude: cellLatitude,
                    cellLongitude: cellLongitude, period: period)
            }
        }
    }

    /// The condition of the items of some cells of the same size and period (a marker, or a cluster of markers MapKit
    /// merged, which may come from the queries of different regions as the map moved): their rows and columns, within the
    /// rectangle around the cells (for the coordinate index) and around the regions they were counted in.
    static func cellsCondition(_ cells: [MapCell]) -> (String, StatementArguments)? {
        guard let first = cells.first else { return nil }
        // A little more than the cells: the rows and columns decide, the rectangle only narrows the index range.
        let margin = 1e-9
        let rows = cells.map(\.row)
        let columns = cells.map(\.column)
        let around = MapRegion(
            minLatitude: max(Double(rows.min()!) * first.cellLatitude - 90 - margin, cells.map(\.region.minLatitude).min()!),
            maxLatitude: min(Double(rows.max()! + 1) * first.cellLatitude - 90 + margin, cells.map(\.region.maxLatitude).max()!),
            minLongitude: max(Double(columns.min()!) * first.cellLongitude - 180 - margin, cells.map(\.region.minLongitude).min()!),
            maxLongitude: min(Double(columns.max()! + 1) * first.cellLongitude - 180 + margin, cells.map(\.region.maxLongitude).max()!))
        var (condition, arguments) = mapCondition(around, period: first.period)
        let pairs = cells.map { _ in "(?, ?)" }.joined(separator: ", ")
        condition += " AND (\(cellRow), \(cellColumn)) IN (VALUES \(pairs))"
        arguments += [first.cellLatitude, first.cellLongitude]
        for cell in cells { arguments += [cell.row, cell.column] }
        return (condition, arguments)
    }

    /// The items of a map cell, newest first.
    public func mapItems(in cell: MapCell) async throws -> [MediaItem] {
        guard let (condition, arguments) = Self.cellsCondition([cell]) else { return [] }
        let sql = "SELECT media.* FROM media WHERE \(condition) \(Self.displayOrder)"
        return try await database.writer.read { db in try MediaItem.fetchAll(db, sql: sql, arguments: arguments) }
    }

    /// The geotagged items of a region, newest first.
    public func mapItems(in region: MapRegion, during period: Range<Date>? = nil) async throws -> [MediaItem] {
        let (condition, arguments) = Self.mapCondition(region, period: period)
        let sql = "SELECT media.* FROM media WHERE \(condition) \(Self.displayOrder)"
        return try await database.writer.read { db in try MediaItem.fetchAll(db, sql: sql, arguments: arguments) }
    }

    /// A page of the items of a map cell as grid rows, newest first ("Photos in this area" can be most of the library).
    public func mapGridItems(in cell: MapCell, limit: Int, offset: Int = 0) async throws -> [GridMedia] {
        try await mapGridItems(in: [cell], limit: limit, offset: offset)
    }

    /// A page of the items of several cells of the same query (a cluster) as grid rows, newest first.
    public func mapGridItems(in cells: [MapCell], limit: Int, offset: Int = 0) async throws -> [GridMedia] {
        guard let (condition, arguments) = Self.cellsCondition(cells) else { return [] }
        let sql = "SELECT \(Self.gridColumns) FROM media WHERE \(condition) \(Self.displayOrder) LIMIT ? OFFSET ?"
        return try await database.writer.read { db in try Self.fetchGrid(db, sql: sql, arguments: arguments + [limit, offset]) }
    }

    /// A page of the geotagged items of a region as grid rows, newest first.
    public func mapGridItems(in region: MapRegion, during period: Range<Date>? = nil, limit: Int, offset: Int = 0) async throws
        -> [GridMedia]
    {
        let (condition, arguments) = Self.mapCondition(region, period: period)
        let sql = "SELECT \(Self.gridColumns) FROM media WHERE \(condition) \(Self.displayOrder) LIMIT ? OFFSET ?"
        return try await database.writer.read { db in try Self.fetchGrid(db, sql: sql, arguments: arguments + [limit, offset]) }
    }

    public func mapItemCount(in region: MapRegion, during period: Range<Date>? = nil) async throws -> Int {
        let (condition, arguments) = Self.mapCondition(region, period: period)
        let sql = "SELECT COUNT(*) FROM media WHERE \(condition)"
        return try await database.writer.read { db in try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0 }
    }

    /// Where and when the geotagged photos were taken: the area the map opens on and the ends of its time slider.
    public func mapOverview() async throws -> MapOverview? {
        try await database.writer.read { db in
            let sql = """
                SELECT MIN(\(Self.timestamp)), MAX(\(Self.timestamp)), MIN(media.latitude), MAX(media.latitude),
                    MIN(media.longitude), MAX(media.longitude)
                FROM media WHERE \(Self.located)
                """
            guard let row = try Row.fetchOne(db, sql: sql), let oldest = row[0] as Double?, let newest = row[1] as Double? else {
                return nil
            }
            return MapOverview(
                oldest: Date(timeIntervalSince1970: oldest), newest: Date(timeIntervalSince1970: newest),
                region: MapRegion(minLatitude: row[2], maxLatitude: row[3], minLongitude: row[4], maxLongitude: row[5]))
        }
    }
}
