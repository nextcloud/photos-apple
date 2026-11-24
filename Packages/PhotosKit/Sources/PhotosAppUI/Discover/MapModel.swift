// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosStore

/// How the map's markers are made (SPEC MP-1). The database adds the located photos up into grid cells (never loading
/// them), and MapKit clusters the cells' markers where they overlap on screen (`MKClusterAnnotation`). The cells are much
/// smaller than a marker at the widest zoom, so the markers sit where the photos are and MapKit decides what merges;
/// MapKit alone over every photo is no option: 50 000 annotations take seconds to add (see `MapClusteringTests`).
enum MapGrid {
    /// About how many cells fit across the visible span. The cell sizes are powers of two degrees, so a cell is between a
    /// 16th and an 8th of the span: at most 32 × 32 cells for the loaded area (the visible region and half a screen around
    /// it), and the same cells (same ids) while the map is only moved or zoomed a little.
    static let cellsAcross = 16.0
    /// The smallest cell, about 10 m.
    static let minimumCell = 1.0 / 8192

    /// A cell size in degrees for a span: the power of two at or above `span / cellsAcross`.
    static func cellSize(span: Double) -> Double {
        let wanted = max(span / cellsAcross, minimumCell)
        return pow(2, (log2(wanted)).rounded(.up))
    }

    /// What to load for a camera region: the visible region and half a screen around it, cut along cell borders so that
    /// every cell is whole (a marker counts all of its photos, and its list shows the same ones).
    static func query(centerLatitude: Double, centerLongitude: Double, latitudeDelta: Double, longitudeDelta: Double)
        -> (region: MapRegion, cellLatitude: Double, cellLongitude: Double)
    {
        let cellLatitude = cellSize(span: latitudeDelta)
        let cellLongitude = cellSize(span: longitudeDelta)
        func snapped(_ value: Double, offset: Double, cell: Double, _ rule: FloatingPointRoundingRule) -> Double {
            ((value + offset) / cell).rounded(rule) * cell - offset
        }
        let region = MapRegion(
            minLatitude: snapped(centerLatitude - latitudeDelta, offset: 90, cell: cellLatitude, .down),
            maxLatitude: snapped(centerLatitude + latitudeDelta, offset: 90, cell: cellLatitude, .up),
            minLongitude: snapped(centerLongitude - longitudeDelta, offset: 180, cell: cellLongitude, .down),
            maxLongitude: snapped(centerLongitude + longitudeDelta, offset: 180, cell: cellLongitude, .up))
        return (region, cellLatitude, cellLongitude)
    }

    /// The marker of several cells that MapKit merged: their photos added up, the newest cover.
    static func merged(_ cells: [MapCell]) -> (count: Int, cover: MapCell?) {
        let cover = cells.max { a, b in
            a.cover.timestamp != b.cover.timestamp ? a.cover.timestamp < b.cover.timestamp : a.cover.fileId < b.cover.fileId
        }
        return (cells.reduce(0) { $0 + $1.count }, cover)
    }
}

/// The months of the map's time slider (SPEC MP-1): from the month of the oldest geotagged photo to that of the newest.
struct MapTimeline: Equatable {
    /// The first day of the oldest month.
    let start: Date
    /// The number of months, at least 1.
    let months: Int
    let calendar: Calendar

    init?(span: ClosedRange<Date>, calendar: Calendar = .current) {
        let first = calendar.dateInterval(of: .month, for: span.lowerBound)?.start ?? span.lowerBound
        let last = calendar.dateInterval(of: .month, for: span.upperBound)?.start ?? span.upperBound
        let between = calendar.dateComponents([.month], from: first, to: last).month ?? 0
        guard between >= 0 else { return nil }
        start = first
        months = between + 1
        self.calendar = calendar
    }

    /// The first day of a month (0 is the oldest).
    func monthStart(_ index: Int) -> Date {
        calendar.date(byAdding: .month, value: index, to: start) ?? start
    }

    /// From the first day of month `from` to the first day after month `to` (both counted).
    func period(from: Int, to: Int) -> Range<Date> {
        let lower = min(max(0, min(from, to)), months - 1)
        let upper = min(max(0, max(from, to)), months - 1)
        return monthStart(lower)..<monthStart(upper + 1)
    }

    /// "March 2021": a month of the slider.
    func monthTitle(_ index: Int) -> String {
        monthStart(index).formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).month(.wide).year())
    }

    /// "March 2021 – June 2023", or one month.
    func title(from: Int, to: Int) -> String {
        let lower = min(from, to)
        let upper = max(from, to)
        if lower == upper { return monthTitle(lower) }
        var style = Date.IntervalFormatStyle().month(.wide).year()
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return (monthStart(lower)..<monthStart(upper)).formatted(style)
    }
}
