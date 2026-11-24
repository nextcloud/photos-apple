// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The shape of the whole timeline while the first sync is still loading it (SPEC §5.4.3 step 1, §6.4): how many photos
/// and videos each month holds, from the day counts of the extended Photos API (`timelineDays`).
///
/// The server counts by UTC day and only in the user's own storage, the app groups by local day and also shows shared
/// folders: the counts are an estimate. The first sync loads newest first, so every month newer than the oldest one
/// loaded so far is complete; only that month and the older ones get placeholder tiles (`placeholders(…)`). The
/// estimate therefore only ever concerns the tail of the grid and is replaced by the real items as they arrive.
public struct TimelineSkeleton: Sendable, Hashable {
    /// Items per month, keyed `YYYYMM`.
    public private(set) var months: [Int: Int]

    public init(months: [Int: Int]) {
        self.months = months.filter { $0.value > 0 }
    }

    /// From the server's day list (`"YYYY-MM-DD"`, count). Malformed days are skipped.
    public init(days: [(day: String, count: Int)]) {
        var months: [Int: Int] = [:]
        for (day, count) in days where count > 0 {
            let parts = day.split(separator: "-")
            guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), (1...12).contains(month), year > 0 else {
                continue
            }
            months[year * 100 + month, default: 0] += count
        }
        self.init(months: months)
    }

    public var total: Int { months.values.reduce(0, +) }
    public var isEmpty: Bool { months.isEmpty }

    /// The buckets the sections of a granularity fall into, newest first: months for day and month sections (the
    /// server's days are UTC days, so the app does not cut them into its local days), years for year sections.
    public func buckets(for granularity: TimelineGranularity) -> [Bucket] {
        let counts: [Int: Int]
        switch granularity {
        case .day, .month: counts = months
        case .year: counts = months.reduce(into: [:]) { $0[$1.key / 100, default: 0] += $1.value }
        }
        return counts.sorted { $0.key > $1.key }.map { Bucket(key: $0.key, count: $0.value) }
    }

    /// The bucket (`YYYYMM` or `YYYY`) a timeline section id belongs to.
    public static func bucket(ofSectionId id: Int, granularity: TimelineGranularity) -> Int {
        switch granularity {
        case .day: id / 100
        case .month, .year: id
        }
    }

    /// A month (`YYYYMM`) or year (`YYYY`) with its count.
    public struct Bucket: Sendable, Hashable {
        public var key: Int
        public var count: Int

        public init(key: Int, count: Int) {
            self.key = key
            self.count = count
        }
    }

    /// What the loaded sections are missing, by the skeleton.
    public struct Placeholders: Sendable, Equatable {
        /// Placeholder tiles after the items of the last loaded section: the rest of the oldest month loaded so far.
        public var trailing: Int
        /// Buckets older than everything loaded, newest first, each one section of placeholder tiles.
        public var older: [Bucket]
    }

    /// - Parameters:
    ///   - lastBucket: bucket of the oldest loaded section, nil when nothing is loaded yet.
    ///   - loadedInLastBucket: items loaded so far in that bucket.
    public func placeholders(granularity: TimelineGranularity, lastBucket: Int?, loadedInLastBucket: Int) -> Placeholders {
        let buckets = buckets(for: granularity)
        guard let lastBucket else { return Placeholders(trailing: 0, older: buckets) }
        let expected = buckets.first { $0.key == lastBucket }?.count ?? 0
        return Placeholders(trailing: max(0, expected - loadedInLastBucket), older: buckets.filter { $0.key < lastBucket })
    }
}
