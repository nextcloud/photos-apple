// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel
import Testing

@testable import PhotosAppUI
@testable import PhotosStore

/// The map's cells and time slider (SPEC MP-1).
@MainActor
@Suite struct MapGridTests {
    // MARK: Map cells

    @Test func cellsArePowersOfTwoBetweenASixteenthAndAnEighthOfTheSpan() {
        for span in [0.003, 0.02, 0.7, 3.3, 30, 120, 360] {
            let cell = MapGrid.cellSize(span: span)
            #expect(log2(cell) == log2(cell).rounded())
            #expect(cell >= span / 16 && cell < span / 8 + 1e-12)
        }
        // A small move or zoom keeps the cells (and the markers' identities).
        #expect(MapGrid.cellSize(span: 10) == MapGrid.cellSize(span: 11))
        #expect(MapGrid.cellSize(span: 0) == MapGrid.minimumCell)
    }

    @Test func theLoadedAreaIsCutAlongCellBorders() {
        let query = MapGrid.query(centerLatitude: 48.13, centerLongitude: 11.57, latitudeDelta: 0.5, longitudeDelta: 0.8)
        #expect(query.cellLatitude == 1.0 / 32)
        #expect(query.cellLongitude == 1.0 / 16)
        let region = query.region
        // The visible span and half a screen around it, at least.
        #expect(region.minLatitude <= 48.13 - 0.5 && region.maxLatitude >= 48.13 + 0.5)
        #expect(region.minLongitude <= 11.57 - 0.8 && region.maxLongitude >= 11.57 + 0.8)
        // Whole cells: the borders are multiples of the cell size (from -90 and -180, as the cell rows and columns are).
        for (value, offset, cell) in [
            (region.minLatitude, 90.0, query.cellLatitude), (region.maxLatitude, 90, query.cellLatitude),
            (region.minLongitude, 180, query.cellLongitude), (region.maxLongitude, 180, query.cellLongitude),
        ] {
            let steps = (value + offset) / cell
            #expect(abs(steps - steps.rounded()) < 1e-9)
        }
        // At most 32 × 32 cells.
        #expect((region.maxLatitude - region.minLatitude) / query.cellLatitude <= 33)
        #expect((region.maxLongitude - region.minLongitude) / query.cellLongitude <= 33)
        // The world stays within the world.
        let world = MapGrid.query(centerLatitude: 0, centerLongitude: 0, latitudeDelta: 170, longitudeDelta: 360).region
        #expect(world.minLatitude == -90 && world.maxLatitude == 90 && world.minLongitude == -180 && world.maxLongitude == 180)
    }

    func cell(_ id: FileID, count: Int, time: Double) -> MapCell {
        let date = Date(timeIntervalSince1970: time)
        return MapCell(
            row: Int(id), column: 0, count: count,
            cover: GridMedia(MediaItem(fileId: id, path: "/\(id).jpg", mimeType: "image/jpeg", modifiedAt: date, capturedAt: date)),
            latitude: 0, longitude: 0, place: nil, region: MapRegion(minLatitude: 0, maxLatitude: 1, minLongitude: 0, maxLongitude: 1),
            cellLatitude: 1, cellLongitude: 1)
    }

    @Test func aClusterShowsItsNewestPhotoAndAllItsPhotos() {
        let merged = MapGrid.merged([cell(1, count: 3, time: 100), cell(2, count: 5, time: 300), cell(3, count: 1, time: 200)])
        #expect(merged.count == 9)
        #expect(merged.cover?.cover.fileId == 2)
        #expect(MapGrid.merged([]).cover == nil)
    }

    // MARK: Time slider

    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    @Test func theSliderCountsMonthsFromTheOldestToTheNewestPhoto() throws {
        let timeline = try #require(MapTimeline(span: date(2021, 3, 15)...date(2023, 6, 2), calendar: utc))
        #expect(timeline.months == 28)
        #expect(timeline.monthStart(0) == utc.date(from: DateComponents(year: 2021, month: 3, day: 1)))
        // Both months counted: from the first day of the one to the first day after the other.
        let period = timeline.period(from: 1, to: 2)
        #expect(period.lowerBound == utc.date(from: DateComponents(year: 2021, month: 4, day: 1)))
        #expect(period.upperBound == utc.date(from: DateComponents(year: 2021, month: 6, day: 1)))
        // Crossed thumbs and values beyond the ends are put in order.
        #expect(timeline.period(from: 2, to: 1) == period)
        #expect(timeline.period(from: -4, to: 99).upperBound == utc.date(from: DateComponents(year: 2023, month: 7, day: 1)))
        #expect(timeline.monthTitle(0).contains("2021"))
        #expect(timeline.title(from: 3, to: 3) == timeline.monthTitle(3))
        #expect(timeline.title(from: 0, to: 27).contains("2021") && timeline.title(from: 0, to: 27).contains("2023"))

        let single = try #require(MapTimeline(span: date(2024, 1, 2)...date(2024, 1, 30), calendar: utc))
        #expect(single.months == 1)
    }
}
