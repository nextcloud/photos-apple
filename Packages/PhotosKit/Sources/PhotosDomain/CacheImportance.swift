// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// How much a photo matters for what the device keeps of it (SPEC §18.2): one score that smart offline ranks its
/// candidates by and that the preview cache evicts by (least important first).
///
/// Every reason that applies gives a score in 0…1; a photo's score is the highest of them:
/// - **On this day** in the next `upcomingDays` days (today included): 1.0, a bit less each day further away.
/// - **Recent**: taken in the last `recentMonths` months: 0.9, halving every `recentHalfLife` days (60 days old: 0.45).
/// - **Viewed**: shown in the viewer for a second within `viewedWindowDays` days: 0.7, halving every `viewedHalfLife`
///   days, plus 0.025 for every further view (up to 0.1).
/// - **Memory cover**: the cover of a memory the app shows (On this day, the year in review, trips): 0.65.
/// - **Album opened recently** (within `albumWindowDays` days): 0.6, halving every 7 days since it was opened.
/// - **Key photo** of a year, month or day of the Library: 0.5.
/// - **Cover** of an album, a place or a tag: 0.45.
/// - **Face**: the cover (face crop) of a person: 0.4.
/// - **Favourite**: 0.35 – 0.55, newer favourites a little higher (halving of the extra every two years).
///
/// Pure and deterministic, so the whole ranking is unit-tested; the stores feed it in batches.
public enum CacheImportance {
    public static let recentMonths = 12
    public static let recentHalfLife: Double = 60
    public static let upcomingDays = 7
    public static let albumWindowDays: Double = 30
    public static let viewedWindowDays: Double = 90
    public static let viewedHalfLife: Double = 14

    /// Why a photo matters: the reason with the highest score. Stored by smart offline (`rawValue`).
    public enum Reason: String, Sendable, Codable, Hashable, CaseIterable {
        /// Its "On this day" comes up in the next days.
        case onThisDay
        case favorite
        /// Taken in the last months.
        case recent
        /// In an album that was opened recently.
        case album
        /// Looked at in the viewer recently.
        case viewed
        case memoryCover
        /// The photo standing for a year, a month or a day in the Library.
        case keyPhoto
        /// The cover of an album, a place or a tag.
        case cover
        /// The face crop of a person.
        case face
    }

    /// Where else a photo is shown, apart from the grids: these places show it first, so its previews should be there.
    public struct Roles: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// Cover of an album, a place or a tag.
        public static let cover = Roles(rawValue: 1)
        /// Key photo of a year, a month or a day in the Library.
        public static let keyPhoto = Roles(rawValue: 2)
        /// Cover of a memory.
        public static let memoryCover = Roles(rawValue: 4)
        /// A person's face crop.
        public static let face = Roles(rawValue: 8)
    }

    /// What is known about a photo; cheap to collect in one query for every photo that has any reason at all.
    public struct Signals: Sendable, Hashable {
        /// When it was taken (nil: unknown, e.g. a cover of a photo that is not in the library index).
        public var timestamp: Date?
        public var isFavorite: Bool
        /// When an album that contains it was last opened.
        public var albumViewedAt: Date?
        /// When it was last looked at in the viewer, and how often.
        public var viewedAt: Date?
        public var viewCount: Int
        public var roles: Roles

        public init(
            timestamp: Date? = nil, isFavorite: Bool = false, albumViewedAt: Date? = nil, viewedAt: Date? = nil, viewCount: Int = 0,
            roles: Roles = []
        ) {
            self.timestamp = timestamp
            self.isFavorite = isFavorite
            self.albumViewedAt = albumViewedAt
            self.viewedAt = viewedAt
            self.viewCount = viewCount
            self.roles = roles
        }
    }

    /// The score and reason of a photo, or nil when no reason applies.
    public static func score(_ signals: Signals, now: Date, calendar: Calendar = .current) -> (score: Double, reason: Reason)? {
        var best: (score: Double, reason: Reason)?
        func consider(_ score: Double, _ reason: Reason) {
            if score > (best?.score ?? 0) { best = (score, reason) }
        }
        if let timestamp = signals.timestamp {
            if let days = daysUntilOnThisDay(timestamp, now: now, calendar: calendar) {
                consider(1.0 - 0.01 * Double(days), .onThisDay)
            }
            let age = now.timeIntervalSince(timestamp) / 86_400
            if let start = calendar.date(byAdding: .month, value: -recentMonths, to: now), timestamp >= start {
                consider(0.9 * pow(0.5, max(0, age) / recentHalfLife), .recent)
            }
            if signals.isFavorite {
                consider(0.35 + 0.2 * pow(0.5, max(0, age) / 730), .favorite)
            }
        } else if signals.isFavorite {
            consider(0.35, .favorite)
        }
        if let viewed = signals.viewedAt {
            let since = max(0, now.timeIntervalSince(viewed) / 86_400)
            if since <= viewedWindowDays {
                let again = min(0.1, 0.025 * Double(max(0, signals.viewCount - 1)))
                consider(0.7 * pow(0.5, since / viewedHalfLife) + again, .viewed)
            }
        }
        if let viewed = signals.albumViewedAt {
            let since = max(0, now.timeIntervalSince(viewed) / 86_400)
            if since <= albumWindowDays { consider(0.6 * pow(0.5, since / 7), .album) }
        }
        if signals.roles.contains(.memoryCover) { consider(0.65, .memoryCover) }
        if signals.roles.contains(.keyPhoto) { consider(0.5, .keyPhoto) }
        if signals.roles.contains(.cover) { consider(0.45, .cover) }
        if signals.roles.contains(.face) { consider(0.4, .face) }
        return best
    }

    /// In how many days (0 = today, up to `upcomingDays - 1`) the photo's month and day come round in a later year; nil when
    /// that is further away, or the photo is from this year.
    public static func daysUntilOnThisDay(_ date: Date, now: Date, calendar: Calendar = .current) -> Int? {
        let year = calendar.component(.year, from: now)
        guard calendar.component(.year, from: date) < year else { return nil }
        let today = calendar.startOfDay(for: now)
        let photo = calendar.dateComponents([.year, .month, .day], from: date)
        for offset in 0..<upcomingDays {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            if photo.month == parts.month && photo.day == parts.day && (photo.year ?? year) < (parts.year ?? year) {
                return offset
            }
        }
        return nil
    }

    // MARK: Tiers

    /// Importance in a few steps, for eviction: within a tier the least recently used file goes first. 0 is "no reason";
    /// 1…4 are quarters of the score (a photo of last year scores little but more than nothing).
    public static let tierCount = 5

    public static func tier(_ score: Double) -> UInt8 {
        guard score > 0 else { return 0 }
        return UInt8(min(Double(tierCount - 1), max(1, (score * Double(tierCount - 1)).rounded(.up))))
    }
}
