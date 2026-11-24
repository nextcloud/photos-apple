// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosModel
@testable import PhotosStore

/// The map's time filter, clusters and opening area (SPEC MP-1).
@Suite struct MapQueryTests {
    let library: LibraryStore

    init() throws {
        library = LibraryStore(database: try AccountDatabase.temporary())
    }

    func located(_ id: FileID, _ latitude: Double, _ longitude: Double, time: Double) -> MediaItem {
        MediaItem(
            fileId: id, path: "/Photos/\(id).jpg", mimeType: "image/jpeg", etag: "e\(id)", modifiedAt: Date(timeIntervalSince1970: time),
            capturedAt: Date(timeIntervalSince1970: time), latitude: latitude, longitude: longitude)
    }

    @Test func mapFiltersByTimeAndListsClusters() async throws {
        try library.upsert([
            located(10, 48.1, 11.5, time: 1000), located(11, 48.2, 11.6, time: 2000), located(12, 48.15, 11.55, time: 3000),
            located(13, 52.5, 13.4, time: 4000), located(14, 38.7, -9.1, time: 5000),
        ])
        let world = MapRegion(minLatitude: -90, maxLatitude: 90, minLongitude: -180, maxLongitude: 180)
        let all = try await library.mapCells(in: world, cellLatitude: 1, cellLongitude: 1)
        #expect(all.map(\.count).reduce(0, +) == 5)
        #expect(all.count == 3)

        // Only what was taken in the period; the cells carry it to their lists.
        let period = Date(timeIntervalSince1970: 1500)..<Date(timeIntervalSince1970: 4500)
        let filtered = try await library.mapCells(in: world, cellLatitude: 1, cellLongitude: 1, during: period)
        #expect(filtered.map(\.count).reduce(0, +) == 3)
        #expect(filtered.allSatisfy { $0.period == period })
        let munich = try #require(filtered.first { $0.count == 2 })
        #expect(munich.cover.fileId == 12)
        #expect(try await library.mapGridItems(in: munich, limit: 10).map(\.fileId) == [12, 11])
        #expect(try await library.mapItems(in: munich).map(\.fileId) == [12, 11])
        #expect(try await library.mapItemCount(in: world, during: period) == 3)
        #expect(try await library.mapGridItems(in: world, during: period, limit: 10).map(\.fileId) == [13, 12, 11])

        // A cluster of cells (MapKit merged their markers): the photos of all of them, newest first, in pages.
        let cluster = try await library.mapGridItems(in: all, limit: 10)
        #expect(cluster.map(\.fileId) == [14, 13, 12, 11, 10])
        let first = try await library.mapGridItems(in: all, limit: 2)
        let rest = try await library.mapGridItems(in: all, limit: 10, offset: 2)
        #expect((first + rest).map(\.fileId) == cluster.map(\.fileId))
        #expect(try await library.mapGridItems(in: [MapCell](), limit: 10).isEmpty)
        // Markers stay while the map moves, so a cluster can hold cells of two queries of different regions.
        let west = try await library.mapCells(
            in: MapRegion(minLatitude: 30, maxLatitude: 60, minLongitude: -20, maxLongitude: 12), cellLatitude: 1, cellLongitude: 1)
        let east = try await library.mapCells(
            in: MapRegion(minLatitude: 30, maxLatitude: 60, minLongitude: 12, maxLongitude: 40), cellLatitude: 1, cellLongitude: 1)
        let mixed = [try #require(west.first { $0.cover.fileId == 14 }), try #require(east.first { $0.cover.fileId == 13 })]
        #expect(try await library.mapGridItems(in: mixed, limit: 10).map(\.fileId) == [14, 13])

        // Where and when: the map opens on this rectangle, the time slider spans these dates.
        let overview = try #require(try await library.mapOverview())
        #expect(overview.oldest == Date(timeIntervalSince1970: 1000))
        #expect(overview.newest == Date(timeIntervalSince1970: 5000))
        #expect(overview.region == MapRegion(minLatitude: 38.7, maxLatitude: 52.5, minLongitude: -9.1, maxLongitude: 13.4))
        #expect(try await LibraryStore(database: .temporary()).mapOverview() == nil)
    }
}
