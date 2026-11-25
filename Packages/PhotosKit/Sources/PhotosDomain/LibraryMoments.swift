// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

// Moments (SPEC §16.1): the Library's days grouped into named moments ("Sunday in Lisbon", "Anna's birthday", "Hike near
// Zermatt"). A moment is one day, or a run of days away from home at one place; it is titled on the device from its
// places, its named people and the labels the device recognised in its photos. Only titles that say more than the date
// are shown ("where it reads well"): a day at home with nobody named and nothing recognised has no moment title.

/// What moments need to know about one photo or video of the library.
public struct MomentItem: Hashable, Sendable {
    public var fileId: FileID
    public var timestamp: Date
    public var isFavorite: Bool
    /// Place name from the server's reverse geocoding ("Lisbon").
    public var place: String?
    public var country: String?
    public var location: GeoPoint?
    /// Named people (Recognize's unnamed clusters are left out by the store).
    public var people: [String]
    /// On-device labels (`visionLabel`, lower-case English words).
    public var labels: Set<String>

    public init(
        fileId: FileID, timestamp: Date, isFavorite: Bool = false, place: String? = nil, country: String? = nil,
        location: GeoPoint? = nil, people: [String] = [], labels: Set<String> = []
    ) {
        self.fileId = fileId
        self.timestamp = timestamp
        self.isFavorite = isFavorite
        self.place = place
        self.country = country
        self.location = location
        self.people = people
        self.labels = labels
    }
}

/// What a moment's photos show, recognised from the device's labels.
public enum MomentActivity: String, Hashable, Sendable, CaseIterable {
    case birthday, wedding, christmas, hike, mountains, beach, skiing, snow, concert, camping

    /// Label words that mean the activity (`ContentLabeler` stores the classifier's identifiers as words:
    /// "birthday_cake" is "birthday cake").
    public var labels: Set<String> {
        switch self {
        case .birthday: ["birthday"]
        case .wedding: ["wedding", "bride", "bridesmaid"]
        case .christmas: ["christmas"]
        case .hike: ["hiking"]
        case .mountains: ["mountain"]
        case .beach: ["beach"]
        case .skiing: ["skiing", "snowboarding"]
        case .snow: ["snow", "snowman", "snowball"]
        case .concert: ["concert"]
        case .camping: ["camping", "tent"]
        }
    }

    /// Activities in the order they win when several are recognised: events first, then what the day was spent doing.
    public static let priority: [MomentActivity] = [
        .birthday, .wedding, .christmas, .skiing, .hike, .concert, .camping, .beach, .snow, .mountains,
    ]

    /// Share of the moment's labelled photos that must show the activity (and at least `minimumPhotos` of them).
    /// Scenery (mountains) needs more than an event (one cake makes a birthday).
    var minimumShare: Double {
        switch self {
        case .birthday, .wedding, .christmas, .concert: 0.1
        case .hike, .skiing, .camping: 0.2
        case .beach, .snow: 0.25
        case .mountains: 0.4
        }
    }

    var minimumPhotos: Int {
        switch self {
        case .birthday, .wedding, .christmas, .concert: 1
        default: 2
        }
    }

    /// Words of all activities: the store only reads label rows that contain one of them.
    public static let allLabels: Set<String> = Set(allCases.flatMap(\.labels))
}

/// The title of a moment, before it is put into words (`text`), so that the rules can be tested in any language.
public enum MomentTitle: Hashable, Sendable {
    /// "Sunday in Lisbon": one day away from home.
    case dayIn(day: Date, place: String)
    /// "Weekend in Lisbon": a Saturday and Sunday (with the Friday or Monday) away.
    case weekendIn(place: String)
    /// "3 days in Lisbon".
    case daysIn(days: Int, place: String)
    /// "Lisbon & Porto": several days at two places.
    case places(String, String)
    /// "Hike near Zermatt", "Beach day", "Anna's birthday"…
    case activity(MomentActivity, place: String?, person: String?)
    /// "Sunday with Anna", "Sunday with Anna and Ben".
    case with(people: [String], day: Date)

    /// The title in the user's language.
    public func text(locale: Locale = .current, calendar: Calendar = .current) -> String {
        switch self {
        case .dayIn(let day, let place):
            let weekday = Self.weekday(day, locale: locale, calendar: calendar)
            return String(
                localized: "\(weekday) in \(place)", bundle: .module,
                comment: "Title of a moment of the library: a day away from home. Weekday and place, e.g. Sunday in Lisbon.")
        case .weekendIn(let place):
            return String(
                localized: "Weekend in \(place)", bundle: .module,
                comment: "Title of a moment of the library: a weekend away from home, e.g. Weekend in Lisbon.")
        case .daysIn(let days, let place):
            return String(
                localized: "\(days) days in \(place)", bundle: .module,
                comment: "Title of a moment of the library: several days away, e.g. 3 days in Lisbon. Plural variations in the catalog.")
        case .places(let first, let second):
            return String(
                localized: "\(first) & \(second)", bundle: .module,
                comment: "Title of a moment of the library: two places of a few days away, e.g. Lisbon & Porto.")
        case .activity(let activity, let place, let person):
            return Self.activityText(activity, place: place, person: person)
        case .with(let people, let day):
            let weekday = Self.weekday(day, locale: locale, calendar: calendar)
            let names = people.formatted(.list(type: .and).locale(locale))
            return String(
                localized: "\(weekday) with \(names)", bundle: .module,
                comment: "Title of a moment of the library: a day with named people, e.g. Sunday with Anna and Ben.")
        }
    }

    static func weekday(_ day: Date, locale: Locale, calendar: Calendar) -> String {
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).weekday(.wide)
        style.capitalizationContext = .beginningOfSentence
        return day.formatted(style)
    }

    static func activityText(_ activity: MomentActivity, place: String?, person: String?) -> String {
        switch (activity, place) {
        case (.birthday, _):
            if let person {
                return String(
                    localized: "\(person)’s birthday", bundle: .module,
                    comment: "Title of a moment of the library: a birthday, with the name of the person seen most, e.g. Anna’s birthday.")
            }
            return String(localized: "Birthday", bundle: .module, comment: "Title of a moment of the library: a birthday.")
        case (.wedding, let place?):
            return String(localized: "Wedding in \(place)", bundle: .module, comment: "Title of a moment of the library.")
        case (.wedding, nil):
            return String(localized: "Wedding", bundle: .module, comment: "Title of a moment of the library.")
        case (.christmas, _):
            return String(localized: "Christmas", bundle: .module, comment: "Title of a moment of the library.")
        case (.hike, let place?):
            return String(
                localized: "Hike near \(place)", bundle: .module, comment: "Title of a moment of the library, e.g. Hike near Zermatt.")
        case (.hike, nil):
            return String(localized: "Hike", bundle: .module, comment: "Title of a moment of the library.")
        case (.mountains, let place?):
            return String(
                localized: "Mountains near \(place)", bundle: .module,
                comment: "Title of a moment of the library: photos of mountains, e.g. Mountains near Zermatt.")
        case (.mountains, nil):
            return String(localized: "In the mountains", bundle: .module, comment: "Title of a moment of the library.")
        case (.beach, let place?):
            return String(
                localized: "Beach day in \(place)", bundle: .module, comment: "Title of a moment of the library, e.g. Beach day in Nice.")
        case (.beach, nil):
            return String(localized: "Beach day", bundle: .module, comment: "Title of a moment of the library.")
        case (.skiing, let place?):
            return String(localized: "Skiing in \(place)", bundle: .module, comment: "Title of a moment of the library.")
        case (.skiing, nil):
            return String(localized: "Skiing", bundle: .module, comment: "Title of a moment of the library.")
        case (.snow, let place?):
            return String(localized: "Snow day in \(place)", bundle: .module, comment: "Title of a moment of the library.")
        case (.snow, nil):
            return String(localized: "Snow day", bundle: .module, comment: "Title of a moment of the library.")
        case (.concert, let place?):
            return String(localized: "Concert in \(place)", bundle: .module, comment: "Title of a moment of the library.")
        case (.concert, nil):
            return String(localized: "Concert", bundle: .module, comment: "Title of a moment of the library.")
        case (.camping, let place?):
            return String(localized: "Camping near \(place)", bundle: .module, comment: "Title of a moment of the library.")
        case (.camping, nil):
            return String(localized: "Camping", bundle: .module, comment: "Title of a moment of the library.")
        }
    }
}

/// What is known about a moment, for its title (and for a language model to word a nicer one).
public struct MomentFacts: Hashable, Sendable {
    /// Places by number of photos, most first (at most three).
    public var places: [String]
    public var country: String?
    /// Named people by number of photos, most first (at most three, each in a good share of the photos).
    public var people: [String]
    public var activities: [MomentActivity]
    public var days: Int
    public var isAway: Bool
    public var start: Date
    public var end: Date

    /// A stable description: a title worded from these facts stays valid while they are the same.
    public var key: String {
        [
            places.joined(separator: "|"), country ?? "", people.joined(separator: "|"), activities.map(\.rawValue).joined(separator: "|"),
            String(days), isAway ? "away" : "home", String(Int(start.timeIntervalSince1970 / 86_400)),
        ].joined(separator: ";")
    }
}

/// One moment of the library.
public struct LibraryMoment: Hashable, Sendable, Identifiable {
    /// `moment-<oldest day>-<newest day>` (`YYYYMMDD`): stable while the moment keeps its days.
    public var id: String
    /// Its days, `YYYYMMDD` in the local calendar, newest first (the grid's day section ids).
    public var days: [Int]
    public var start: Date
    public var end: Date
    /// Its items, oldest first.
    public var items: [FileID]
    /// A favourite, else the photo nearest the middle of the moment.
    public var cover: FileID
    /// Nil when nothing better than the date can be said: the grid keeps its plain day header.
    public var title: MomentTitle?
    public var facts: MomentFacts

    public var count: Int { items.count }
    /// The newest day: its header carries the moment's title.
    public var headerDay: Int { days.first ?? 0 }

    /// The moment as a memory, for the memory's screen, slideshow, film and actions. A moment is a stay like a trip
    /// (its film flies between its places).
    public func memory(title: String) -> Memory {
        Memory(id: id, kind: .trip, title: title, start: start, end: end, cover: cover, items: items)
    }
}

/// Builds the moments of a library.
public enum LibraryMoments {
    /// Days away at places this close to each other (kilometres) are one stay ("Lisbon & Sintra").
    public static let nearbyDistance = 50.0
    /// Days away at one place are one moment when no more than this lies between their photos.
    public static let maximumGap: TimeInterval = 36 * 3600
    /// A moment is at most this many days long (a longer stay is cut into weeks).
    public static let maximumDays = 7
    /// Fewer photos than this get no title (a single snapshot is not a moment).
    public static let minimumTitledItems = 3
    /// A named person must be in this share of the moment's photos (or in `minimumPersonPhotos` of them) to name it.
    public static let personShare = 0.3
    public static let minimumPersonPhotos = 3
    /// Home: the place photographed on the most days, if on at least this many.
    public static let minimumHomeDays = 3

    /// One local day of the library.
    struct Day {
        var key: Int
        var date: Date
        /// Range into the sorted items (newest first).
        var range: Range<Int>
        var first: Date
        var last: Date
        var place: String?
        var country: String?
        /// Where the first located photo of the day's main place was taken.
        var location: GeoPoint?
    }

    /// The moments of `items`, newest first.
    /// - Parameter home: the user's home place; nil finds it from the items (the place on the most days).
    public static func build(_ items: [MomentItem], home: String? = nil, calendar: Calendar = .current) -> [LibraryMoment] {
        let sorted = isNewestFirst(items) ? items : items.sorted { ($0.timestamp, $0.fileId) > ($1.timestamp, $1.fileId) }
        let days = Self.days(sorted, calendar: calendar)
        guard !days.isEmpty else { return [] }
        let home = home ?? Self.home(days)
        let homeCountry = home.flatMap { home in days.first { $0.place == home }?.country }
        let groups = group(days, home: home, homeCountry: homeCountry, calendar: calendar)
        return groups.map { moment(of: $0, days: days, items: sorted, home: home, homeCountry: homeCountry, calendar: calendar) }
    }

    static func isNewestFirst(_ items: [MomentItem]) -> Bool {
        zip(items, items.dropFirst()).allSatisfy { ($0.timestamp, $0.fileId) >= ($1.timestamp, $1.fileId) }
    }

    /// Local calendar days of items sorted newest first; the calendar is asked once per day, not per item.
    static func days(_ items: [MomentItem], calendar: Calendar) -> [Day] {
        var result: [Day] = []
        var lower = Double.infinity
        var upper = -Double.infinity
        var start = 0
        var key = 0
        var date = Date()
        func close(at end: Int) {
            guard end > start else { return }
            let places = topCounts(items[start..<end].lazy.compactMap { $0.place.nonEmpty }, limit: 1)
            let countries = topCounts(items[start..<end].lazy.compactMap { $0.country.nonEmpty }, limit: 1)
            let location = items[start..<end].first { $0.location != nil && $0.place == places.first }?.location
            result.append(
                Day(
                    key: key, date: date, range: start..<end, first: items[end - 1].timestamp, last: items[start].timestamp,
                    place: places.first, country: countries.first, location: location))
        }
        for (index, item) in items.enumerated() {
            let reference = item.timestamp.timeIntervalSinceReferenceDate
            if reference >= lower && reference < upper { continue }
            close(at: index)
            start = index
            let parts = calendar.dateComponents([.year, .month, .day], from: item.timestamp)
            key = ((parts.year ?? 0) * 100 + (parts.month ?? 0)) * 100 + (parts.day ?? 0)
            date = calendar.startOfDay(for: item.timestamp)
            let next = calendar.date(byAdding: .day, value: 1, to: date) ?? date
            lower = date.timeIntervalSinceReferenceDate
            upper = next > date ? next.timeIntervalSinceReferenceDate : -Double.infinity
        }
        close(at: items.count)
        return result
    }

    /// The place that is the main place of the most days.
    static func home(_ days: [Day]) -> String? {
        var counts: [String: Int] = [:]
        for day in days { if let place = day.place { counts[place, default: 0] += 1 } }
        guard let best = counts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }), best.value >= minimumHomeDays else { return nil }
        return best.key
    }

    /// Days (newest first) cut into moments: consecutive days away at the same place (or nearby, or in the same foreign country)
    /// are one moment; a day without any place between two days of one such moment belongs to it. Everything else is a
    /// moment of its own day.
    static func group(_ days: [Day], home: String?, homeCountry: String?, calendar: Calendar) -> [[Int]] {
        func isAway(_ day: Day) -> Bool { day.place != nil && day.place != home }
        func sameStay(_ newer: Day, _ older: Day) -> Bool {
            guard isAway(newer), isAway(older) else { return false }
            if newer.place == older.place { return true }
            if let a = newer.location, let b = older.location, TravelRoute.distance(a, b) <= nearbyDistance { return true }
            guard let country = newer.country, country == older.country else { return false }
            return homeCountry != nil && country != homeCountry
        }
        func adjacent(_ newer: Day, _ older: Day) -> Bool {
            newer.first.timeIntervalSince(older.last) <= maximumGap
        }
        var groups: [[Int]] = []
        var index = 0
        while index < days.count {
            var group = [index]
            var last = index
            var next = index + 1
            while next < days.count, group.count < maximumDays {
                let older = days[next]
                let newer = days[last]
                if adjacent(newer, older), sameStay(newer, older) {
                    group.append(next)
                    last = next
                    next += 1
                } else if older.place == nil, next + 1 < days.count, adjacent(newer, older), adjacent(older, days[next + 1]),
                    sameStay(newer, days[next + 1]), group.count + 2 <= maximumDays
                {
                    // A day without places in the middle of a stay (a camera without GPS that day).
                    group.append(next)
                    group.append(next + 1)
                    last = next + 1
                    next += 2
                } else {
                    break
                }
            }
            groups.append(group)
            index = next
        }
        return groups
    }

    static func moment(
        of group: [Int], days: [Day], items: [MomentItem], home: String?, homeCountry: String?, calendar: Calendar
    ) -> LibraryMoment {
        let newest = days[group[0]]
        let oldest = days[group[group.count - 1]]
        let range = newest.range.lowerBound..<oldest.range.upperBound
        let members = items[range]
        var placeCounts: [String: Int] = [:]
        var countryCounts: [String: Int] = [:]
        var personCounts: [String: Int] = [:]
        var activityCounts: [MomentActivity: Int] = [:]
        var labelled = 0
        for item in members {
            if let place = item.place.nonEmpty { placeCounts[place, default: 0] += 1 }
            if let country = item.country.nonEmpty { countryCounts[country, default: 0] += 1 }
            for person in Set(item.people) { personCounts[person, default: 0] += 1 }
            if !item.labels.isEmpty {
                labelled += 1
                for activity in MomentActivity.allCases where !item.labels.isDisjoint(with: activity.labels) {
                    activityCounts[activity, default: 0] += 1
                }
            }
        }
        let places = ranked(placeCounts, limit: 3)
        let people = ranked(personCounts, limit: 3).filter { person in
            let count = personCounts[person] ?? 0
            return count >= minimumPersonPhotos || Double(count) >= personShare * Double(members.count)
        }
        let month = calendar.component(.month, from: newest.date)
        let activities = MomentActivity.priority.filter { activity in
            let count = activityCounts[activity] ?? 0
            guard count >= activity.minimumPhotos, labelled > 0, Double(count) >= activity.minimumShare * Double(labelled) else {
                return false
            }
            // A Christmas tree in July is a decoration shop, not Christmas.
            return activity != .christmas || month == 12 || month == 1
        }
        let mainPlace = places.first
        let isAway = mainPlace != nil && mainPlace != home
        let facts = MomentFacts(
            places: places, country: ranked(countryCounts, limit: 1).first, people: people, activities: activities, days: group.count,
            isAway: isAway, start: oldest.first, end: newest.last)
        let ordered = Array(members.reversed())
        let middle = oldest.first.addingTimeInterval(newest.last.timeIntervalSince(oldest.first) / 2)
        let cover =
            ordered.first(where: \.isFavorite)
            ?? ordered.min { abs($0.timestamp.timeIntervalSince(middle)) < abs($1.timestamp.timeIntervalSince(middle)) }!
        return LibraryMoment(
            id: "moment-\(oldest.key)-\(newest.key)", days: group.map { days[$0].key }, start: oldest.first, end: newest.last,
            items: ordered.map(\.fileId), cover: cover.fileId,
            title: members.count >= minimumTitledItems ? title(facts, placeCounts: placeCounts, calendar: calendar) : nil,
            facts: facts)
    }

    /// The rules, in order: an event (birthday, wedding, Christmas), what the day was spent doing, a day or a stay away,
    /// a day with named people. Nil when none applies.
    public static func title(_ facts: MomentFacts, placeCounts: [String: Int] = [:], calendar: Calendar = .current) -> MomentTitle? {
        let place = facts.places.first
        let awayPlace = facts.isAway ? place : nil
        if let activity = facts.activities.first {
            switch activity {
            case .birthday: return .activity(.birthday, place: nil, person: facts.people.first)
            case .christmas: return .activity(.christmas, place: nil, person: nil)
            default: return .activity(activity, place: awayPlace, person: nil)
            }
        }
        if let place = awayPlace {
            if facts.days == 1 { return .dayIn(day: facts.end, place: place) }
            if facts.places.count > 1, let second = facts.places.dropFirst().first,
                let firstCount = placeCounts[place], let secondCount = placeCounts[second], secondCount * 2 >= firstCount
            {
                return .places(place, second)
            }
            if isWeekend(start: facts.start, end: facts.end, days: facts.days, calendar: calendar) { return .weekendIn(place: place) }
            return .daysIn(days: facts.days, place: place)
        }
        if !facts.people.isEmpty { return .with(people: Array(facts.people.prefix(2)), day: facts.end) }
        return nil
    }

    /// Two to three days that take in a Saturday and a Sunday.
    static func isWeekend(start: Date, end: Date, days: Int, calendar: Calendar) -> Bool {
        guard (2...3).contains(days) else { return false }
        var weekend = 0
        var day = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        while day <= last {
            if calendar.isDateInWeekend(day) { weekend += 1 }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return weekend >= 2
    }

    static func ranked(_ counts: [String: Int], limit: Int) -> [String] {
        counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(limit).map(\.key)
    }

    static func topCounts<S: Sequence<String>>(_ values: S, limit: Int) -> [String] {
        var counts: [String: Int] = [:]
        for value in values { counts[value, default: 0] += 1 }
        return ranked(counts, limit: limit)
    }

    // MARK: Headers

    /// The titled moments by the day whose header carries the title (their newest day).
    public static func headers(_ moments: [LibraryMoment], locale: Locale = .current, calendar: Calendar = .current) -> MomentHeaders {
        var titles: [Int: MomentHeaders.Entry] = [:]
        for moment in moments {
            guard let title = moment.title else { continue }
            titles[moment.headerDay] = MomentHeaders.Entry(momentId: moment.id, title: title.text(locale: locale, calendar: calendar))
        }
        return MomentHeaders(entries: titles)
    }
}

/// The moment titles the grid's day headers show, by day (`YYYYMMDD`).
public struct MomentHeaders: Hashable, Sendable {
    public struct Entry: Hashable, Sendable {
        public var momentId: String
        public var title: String

        public init(momentId: String, title: String) {
            self.momentId = momentId
            self.title = title
        }
    }

    public var entries: [Int: Entry]

    public init(entries: [Int: Entry] = [:]) {
        self.entries = entries
    }

    public static let none = MomentHeaders()

    public subscript(day: Int) -> Entry? { entries[day] }

    /// The same headers with nicer titles (a language model's) where there are some.
    public func replacingTitles(_ titles: [String: String]) -> MomentHeaders {
        guard !titles.isEmpty else { return self }
        var copy = self
        for (day, entry) in entries {
            if let title = titles[entry.momentId] { copy.entries[day]?.title = title }
        }
        return copy
    }
}

extension Optional where Wrapped == String {
    /// The string unless it is nil or empty.
    fileprivate var nonEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}
