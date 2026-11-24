// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// What the Apple TV app shows and leaves for the Top Shelf (SPEC §15.3).
public enum TVShelves {
    /// Memories in the order of the TV's Memories shelf and the Top Shelf: On this day (nearest year first), then the year
    /// in review, then trips, newest first.
    public static func memories(onThisDay: [Memory], recap: Memory?, trips: [Memory]) -> [Memory] {
        let years = onThisDay.sorted { lhs, rhs in
            yearsAgo(lhs) == yearsAgo(rhs) ? lhs.id < rhs.id : yearsAgo(lhs) < yearsAgo(rhs)
        }
        let newestTrips = trips.sorted { lhs, rhs in lhs.start == rhs.start ? lhs.id < rhs.id : lhs.start > rhs.start }
        return years + (recap.map { [$0] } ?? []) + newestTrips
    }

    /// The Top Shelf shows a few large images; more than this is never seen.
    public static let topShelfLimit = 8

    static func yearsAgo(_ memory: Memory) -> Int {
        if case .yearsAgo(let years) = memory.kind { return years }
        return .max
    }
}

/// Links into the Apple TV app: from the Top Shelf and from the TV app's own state restoration.
/// `nextcloudphotos://memories/<id>[/play]`, `nextcloudphotos://albums/<album id>[/play]`, `nextcloudphotos://slideshow`.
public enum TVRoute: Hashable, Sendable {
    case memory(id: String, play: Bool)
    case album(id: String, play: Bool)
    /// The family slideshow of the chosen album.
    case familySlideshow

    public static let scheme = "nextcloudphotos"

    public init?(url: URL) {
        guard url.scheme == Self.scheme, let host = url.host(percentEncoded: false) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        let play = parts.count == 2 && parts[1] == "play"
        guard parts.count == 1 || play || (host == "slideshow" && parts.isEmpty) else { return nil }
        switch host {
        case "memories" where !parts.isEmpty: self = .memory(id: parts[0], play: play)
        case "albums" where !parts.isEmpty: self = .album(id: parts[0], play: play)
        case "slideshow" where parts.isEmpty: self = .familySlideshow
        default: return nil
        }
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .memory(let id, let play):
            components.host = "memories"
            components.path = "/" + id + (play ? "/play" : "")
        case .album(let id, let play):
            components.host = "albums"
            components.path = "/" + id + (play ? "/play" : "")
        case .familySlideshow:
            components.host = "slideshow"
        }
        // The path is percent-encoded by `URLComponents` (album ids contain ":" and spaces).
        return components.url!
    }
}

/// The order of a slideshow that runs for hours (the family slideshow on the TV, SPEC §15.3): every photo once in a shuffled
/// order before any comes again, the same order for the same seed (so it can go on after a restart), and never the same
/// photo twice in a row across rounds.
public enum FamilySlideshow {
    /// The order of one round.
    public static func round<ID: Hashable & Comparable>(_ ids: [ID], seed: UInt64, round: Int) -> [ID] {
        var order = shuffled(ids, seed: seed, round: round)
        // Two photos simply take turns; with more, the first of a round is not the last of the previous one. Only the
        // first two change places, so the last of a round is always that of its shuffle.
        if order.count > 2, round > 0, order.first == shuffled(ids, seed: seed, round: round - 1).last { order.swapAt(0, 1) }
        return order
    }

    static func shuffled<ID: Hashable & Comparable>(_ ids: [ID], seed: UInt64, round: Int) -> [ID] {
        var order = Array(Set(ids)).sorted()
        guard order.count > 2 else { return order }
        var generator = SplitMix64(seed: seed &+ UInt64(truncatingIfNeeded: round) &* 0x9E37_79B9_7F4A_7C15)
        order.shuffle(using: &generator)
        return order
    }

    /// The photo at a position counted from the start of the slideshow, and where it is in its round.
    public static func photo<ID: Hashable & Comparable>(_ ids: [ID], seed: UInt64, position: Int) -> ID? {
        let count = Set(ids).count
        guard count > 0, position >= 0 else { return nil }
        return round(ids, seed: seed, round: position / count)[position % count]
    }
}

/// A small, fast, seedable random number generator (SplitMix64): the same seed gives the same sequence on every device.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Which photos the iPhone sends to the Apple Watch for a day (SPEC §15.3).
public enum WatchDigestPlan {
    /// At most this many per section: the watch shows a handful, and every photo costs a transfer over Bluetooth.
    public static let onThisDayLimit = 12
    public static let favoritesLimit = 12

    public struct Selection: Equatable, Sendable {
        public var onThisDay: [MediaItem]
        public var favorites: [MediaItem]
        public var photoOfTheDay: MediaItem?
    }

    /// - Parameters:
    ///   - onThisDay: today's "On this day" photos (any order); when empty, `fallbackMemory` fills the section.
    ///   - fallbackMemory: the photos of the newest memory, for days without "On this day".
    ///   - favorites: favourites, newest first.
    public static func select(
        onThisDay: [MediaItem], fallbackMemory: [MediaItem] = [], favorites: [MediaItem], day: Date, calendar: Calendar = .current
    ) -> Selection {
        let source = onThisDay.isEmpty ? fallbackMemory : onThisDay
        let today = spread(source.filter { $0.kind == .image }.sorted(by: newestFirst), limit: onThisDayLimit)
        let todayIds = Set(today.map(\.fileId))
        let favs = Array(favorites.filter { $0.kind == .image && !todayIds.contains($0.fileId) }.prefix(favoritesLimit))
        return Selection(
            onThisDay: today, favorites: favs, photoOfTheDay: photoOfTheDay(today: today, favorites: favs, day: day, calendar: calendar))
    }

    /// One photo a day for the watch face: a favourite of this day in earlier years if there is one, else any of this day's,
    /// else a favourite; the same all day, another the next day.
    public static func photoOfTheDay(today: [MediaItem], favorites: [MediaItem], day: Date, calendar: Calendar = .current) -> MediaItem? {
        let todayFavorites = today.filter(\.isFavorite)
        let pool = !todayFavorites.isEmpty ? todayFavorites : (!today.isEmpty ? today : favorites)
        guard !pool.isEmpty else { return nil }
        let ordered = pool.sorted { $0.fileId < $1.fileId }
        let dayNumber = calendar.ordinality(of: .day, in: .era, for: day) ?? 0
        return ordered[dayNumber % ordered.count]
    }

    /// Up to `limit` items spread over the whole list (all years of "On this day", not only the newest).
    static func spread(_ items: [MediaItem], limit: Int) -> [MediaItem] {
        guard items.count > limit, limit > 0 else { return items }
        let step = Double(items.count) / Double(limit)
        return (0..<limit).map { items[Int(Double($0) * step)] }
    }

    static func newestFirst(_ lhs: MediaItem, _ rhs: MediaItem) -> Bool {
        lhs.timestamp == rhs.timestamp ? lhs.fileId > rhs.fileId : lhs.timestamp > rhs.timestamp
    }
}
