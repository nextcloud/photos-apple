// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosDomain
import PhotosModel

/// The years, months and days of a grid's items with the photos that stand for them (SPEC §15.5, Library zoom levels).
///
/// Built off the main actor from the same items the grid shows (newest first): one pass that groups them by local
/// calendar day (`TimelineSections`, one calendar lookup per day), one that scores every item (`KeyPhoto`), and one per
/// level that picks the best of each range. 100 000 items take well under the grid model's own budget.
public struct LibrarySummary: Sendable {
    /// A year, month or day.
    public struct Bucket: Sendable, Hashable, Identifiable {
        /// `YYYY`, `YYYYMM` or `YYYYMMDD` in the local calendar.
        public var id: Int
        /// Start of the day, month or year (of its newest month, for years).
        public var date: Date
        /// Range into `LibrarySummary.items`.
        public var range: Range<Int>
        /// The photo shown for it.
        public var key: GridMedia
        /// A few of its best photos in grid order, the key photo first (days).
        public var highlights: [GridMedia]
        public var year: Int

        public var count: Int { range.count }
    }

    public private(set) var items: [GridMedia]
    public private(set) var years: [Bucket] = []
    public private(set) var months: [Bucket] = []
    public private(set) var days: [Bucket] = []

    public static let empty = LibrarySummary(items: [])

    /// How many photos a day shows at most.
    public static let dayHighlights = 5

    /// - Parameters:
    ///   - items: the grid's items, newest first.
    ///   - quality: Vision's aesthetics score of the photos this device indexed (`SimilarityStore.qualities`).
    public init(
        items: [GridMedia], quality: [FileID: (quality: Float, isUtility: Bool)] = [:], calendar: Calendar = .current
    ) {
        self.items = items
        guard !items.isEmpty else { return }
        var scores = [Float](repeating: 0, count: items.count)
        for (index, item) in items.enumerated() {
            let rated = quality[item.fileId]
            scores[index] = KeyPhoto.score(
                KeyPhoto.Traits(
                    isFavorite: item.isFavorite, isVideo: item.kind == .video, hasPreview: item.hasPreview,
                    aspectRatio: item.aspectRatio, isPNG: item.mimeType == "image/png", quality: rated?.quality,
                    isUtility: rated?.isUtility ?? false, hasBlurhash: item.blurhash != nil))
        }
        let months = TimelineSections.group(items, calendar: calendar) { $0.timestamp }
        func bucket(id: Int, date: Date, range: Range<Int>, year: Int, highlights: Int) -> Bucket? {
            let picked = highlights > 1 ? KeyPhoto.highlights(in: range, scores: scores, count: highlights) : []
            guard let key = picked.first ?? KeyPhoto.best(in: range, scores: scores) else { return nil }
            return Bucket(id: id, date: date, range: range, key: items[key], highlights: picked.map { items[$0] }, year: year)
        }
        for section in TimelineSections.sections(of: months, granularity: .year) {
            if let year = bucket(id: section.id, date: section.date, range: section.range, year: section.year, highlights: 1) {
                years.append(year)
            }
        }
        self.months.reserveCapacity(months.count)
        for month in months {
            if let bucket = bucket(id: month.id, date: month.date, range: month.range, year: month.year, highlights: 1) {
                self.months.append(bucket)
            }
            for day in month.days {
                if let bucket = bucket(id: day.id, date: day.date, range: day.range, year: month.year, highlights: Self.dayHighlights) {
                    days.append(bucket)
                }
            }
        }
    }

    public func buckets(_ level: LibraryZoomLevel) -> [Bucket] {
        switch level {
        case .years: years
        case .months: months
        case .days, .all: days
        }
    }

    /// The bucket of `level` that holds the item at flat index `index`.
    public func bucket(_ level: LibraryZoomLevel, containing index: Int) -> Bucket? {
        let list = buckets(level)
        var low = 0
        var high = list.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let range = list[mid].range
            if range.contains(index) { return list[mid] }
            if range.lowerBound > index { high = mid - 1 } else { low = mid + 1 }
        }
        return nil
    }

    /// Where a bucket of one level is in a finer (or coarser) level: the bucket that holds its first item.
    public func bucket(_ level: LibraryZoomLevel, matching bucket: Bucket) -> Bucket? {
        self.bucket(level, containing: bucket.range.lowerBound)
    }

    /// The flat index of an item.
    public func index(of id: FileID) -> Int? {
        items.firstIndex { $0.fileId == id }
    }
}
