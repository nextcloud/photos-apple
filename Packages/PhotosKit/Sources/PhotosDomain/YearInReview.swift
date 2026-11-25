// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// What the year in review needs to know about one photo or video (a few columns of the index, the named people in it
/// and the labels the device recognised in it).
public struct YearReviewItem: Hashable, Sendable {
    public var fileId: FileID
    public var date: Date
    public var isVideo: Bool
    public var isFavorite: Bool
    public var location: GeoPoint?
    public var place: String?
    public var country: String?
    /// Named people (Recognize's unnamed clusters are left out by the store).
    public var people: [String]
    /// On-device labels (`visionLabel`, English words).
    public var labels: Set<String>

    public init(
        fileId: FileID, date: Date, isVideo: Bool = false, isFavorite: Bool = false, location: GeoPoint? = nil, place: String? = nil,
        country: String? = nil, people: [String] = [], labels: Set<String> = []
    ) {
        self.fileId = fileId
        self.date = date
        self.isVideo = isVideo
        self.isFavorite = isFavorite
        self.location = location
        self.place = place
        self.country = country
        self.people = people
        self.labels = labels
    }
}

/// A year in numbers, "Wrapped" style (SPEC §15.1), computed on the device from the local index. Every number is true:
/// a card whose number would be zero or meaningless is left out rather than padded.
public struct YearInReview: Hashable, Sendable {
    public struct Count: Hashable, Sendable {
        public var name: String
        public var count: Int
        /// A photo of them (the favourite one, else the middle one).
        public var cover: FileID
    }

    public struct Day: Hashable, Sendable {
        public var date: Date
        public var count: Int
        public var cover: FileID
    }

    public struct Streak: Hashable, Sendable {
        public var days: Int
        public var start: Date
        public var end: Date
    }

    public struct First: Hashable, Sendable {
        public var date: Date
        public var fileId: FileID
    }

    /// One swipeable card.
    public enum Card: Hashable, Sendable {
        case intro
        case busiestDay
        case topMonth
        case streak
        case travel
        case people
        case pets
        case firstSnow
        case firstBeach
        case favorites
        case bestOf
    }

    public var year: Int
    public var photos: Int
    public var videos: Int
    public var favorites: Int
    /// Days with at least one photo.
    public var activeDays: Int
    public var busiestDay: Day?
    /// The month with the most photos.
    public var topMonth: Month?
    /// Items per month, January first (12 numbers).
    public var months: [Int]
    public var longestStreak: Streak?
    public var travel: TravelStats
    public var people: [Count]
    /// "dog", "cat": in how many photos.
    public var pets: [Count]
    public var firstSnow: First?
    public var firstBeach: First?
    /// Up to nine photos: favourites first, then spread over the year.
    public var bestOf: [FileID]
    public var cover: FileID?

    public struct Month: Hashable, Sendable {
        /// 1…12.
        public var month: Int
        public var count: Int
    }

    /// A year needs this many photos for a review.
    public static let minimumItems = Memories.recapMinimum
    public static let bestOfCount = 9
    public static let peopleShown = 5
    /// Labels of the on-device classifier that mean a pet, and what the card calls them.
    public static let petLabels = ["dog", "cat"]
    public static let snowLabels: Set<String> = ["snow", "snowman", "snowboarding", "skiing", "blizzard"]
    public static let beachLabels: Set<String> = ["beach", "seashore", "shore"]

    /// Computes the review of `year` from its items. `hiddenPeople` (hidden on this device) are not named.
    public init(year: Int, items: [YearReviewItem], hiddenPeople: Set<String> = [], calendar: Calendar = .current) {
        self.year = year
        let sorted = items.filter { calendar.component(.year, from: $0.date) == year }.sorted { $0.date < $1.date }
        photos = sorted.count { !$0.isVideo }
        videos = sorted.count { $0.isVideo }
        favorites = sorted.count { $0.isFavorite }

        // Days, the busiest one and the longest run of consecutive days.
        var byDay: [Date: [YearReviewItem]] = [:]
        for item in sorted { byDay[calendar.startOfDay(for: item.date), default: []].append(item) }
        activeDays = byDay.count
        busiestDay = byDay.max { $0.value.count != $1.value.count ? $0.value.count < $1.value.count : $0.key > $1.key }.map {
            Day(date: $0.key, count: $0.value.count, cover: Self.cover(of: $0.value))
        }
        longestStreak = Self.longestStreak(days: byDay.keys.sorted(), calendar: calendar)

        var byMonth: [Int: Int] = [:]
        for item in sorted { byMonth[calendar.component(.month, from: item.date), default: 0] += 1 }
        months = (1...12).map { byMonth[$0] ?? 0 }
        topMonth = byMonth.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }.map {
            Month(month: $0.key, count: $0.value)
        }

        travel = TravelStats(
            sorted.map { TravelStats.Sample(location: $0.location, date: $0.date, place: $0.place, country: $0.country) })

        var byPerson: [String: [YearReviewItem]] = [:]
        for item in sorted {
            for name in Set(item.people) where !hiddenPeople.contains(name) && Int(name) == nil && !name.isEmpty {
                byPerson[name, default: []].append(item)
            }
        }
        people = Self.ranked(byPerson).prefix(Self.peopleShown).map { $0 }

        var byPet: [String: [YearReviewItem]] = [:]
        for item in sorted {
            for pet in Self.petLabels where item.labels.contains(pet) { byPet[pet, default: []].append(item) }
        }
        pets = Self.ranked(byPet)

        firstSnow = sorted.first { !$0.labels.isDisjoint(with: Self.snowLabels) }.map { First(date: $0.date, fileId: $0.fileId) }
        firstBeach = sorted.first { !$0.labels.isDisjoint(with: Self.beachLabels) }.map { First(date: $0.date, fileId: $0.fileId) }

        bestOf = Self.bestOf(sorted, count: Self.bestOfCount, calendar: calendar)
        cover = bestOf.first
    }

    /// The cards worth showing, in order. Cards whose numbers are too small to be interesting are left out.
    public var cards: [Card] {
        var result: [Card] = [.intro]
        if let busiestDay, busiestDay.count >= 5 { result.append(.busiestDay) }
        if topMonth != nil, activeDays >= 10 { result.append(.topMonth) }
        if let longestStreak, longestStreak.days >= 3 { result.append(.streak) }
        if travel.places.count >= 2 || travel.countries.count >= 2 || travel.kilometres >= 50 { result.append(.travel) }
        if !people.isEmpty { result.append(.people) }
        if pets.contains(where: { $0.count >= 3 }) { result.append(.pets) }
        if firstSnow != nil { result.append(.firstSnow) }
        if firstBeach != nil { result.append(.firstBeach) }
        if favorites > 0 { result.append(.favorites) }
        if bestOf.count >= 4 { result.append(.bestOf) }
        return result
    }

    /// The year whose review the library offers around New Year: in December the year that is ending, in January the
    /// one that just ended; nil otherwise (then the review is on the Memories screen).
    public static func seasonalYear(now: Date = Date(), calendar: Calendar = .current) -> Int? {
        let year = calendar.component(.year, from: now)
        switch calendar.component(.month, from: now) {
        case 12: return year
        case 1: return year - 1
        default: return nil
        }
    }

    // MARK: Helpers

    static func cover(of items: [YearReviewItem]) -> FileID {
        (items.first { $0.isFavorite && !$0.isVideo } ?? items.first { !$0.isVideo } ?? items[items.count / 2]).fileId
    }

    static func ranked(_ groups: [String: [YearReviewItem]]) -> [Count] {
        groups.map { Count(name: $0.key, count: $0.value.count, cover: cover(of: $0.value)) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    static func longestStreak(days: [Date], calendar: Calendar) -> Streak? {
        guard var start = days.first else { return nil }
        var best = Streak(days: 1, start: start, end: start)
        var length = 1
        for (previous, day) in zip(days, days.dropFirst()) {
            if calendar.dateComponents([.day], from: previous, to: day).day == 1 {
                length += 1
            } else {
                length = 1
                start = day
            }
            if length > best.days { best = Streak(days: length, start: start, end: day) }
        }
        return best
    }

    /// Favourite photos first (spread over the year), then photos spread evenly over the months.
    static func bestOf(_ items: [YearReviewItem], count: Int, calendar: Calendar) -> [FileID] {
        let stills = items.filter { !$0.isVideo }
        let favourites = stills.filter(\.isFavorite)
        var chosen = spread(favourites, count: count)
        guard chosen.count < count else { return chosen }
        let taken = Set(chosen)
        let rest = stills.filter { !taken.contains($0.fileId) }
        chosen += spread(rest, count: count - chosen.count)
        return chosen
    }

    static func spread(_ items: [YearReviewItem], count: Int) -> [FileID] {
        guard items.count > count else { return items.map(\.fileId) }
        return (0..<count).map { items[$0 * items.count / count].fileId }
    }
}
