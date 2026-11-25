// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Dates in what people type (SPEC §16.2): "2019", "june 2023", "3 march 2021", "2021-03-03", "summer 2019",
/// "last summer", "christmas 2022", "easter", "the 90s", "2018 to 2020", "between 2018 and 2020", "last week",
/// "3 years ago", "past 10 days", "yesterday", "recently". Month names in English and the user's language.
///
/// Every range is half-open (`end` exclusive) in the user's calendar. Seasons follow the hemisphere of the user's region.
public enum SearchDates {
    /// A date range found in typed words.
    public struct Match: Equatable, Sendable {
        public var range: Range<Date>
        public var label: String
        /// How many words it took.
        public var length: Int

        public var filter: SearchFilter { .dateRange(start: range.lowerBound, end: range.upperBound, label: label) }
    }

    public enum Season: String, CaseIterable, Sendable {
        case spring, summer, autumn, winter
    }

    /// Regions in the southern hemisphere, where summer is December to February.
    static let southernRegions: Set<String> = [
        "AR", "AU", "BO", "BR", "BW", "CL", "FJ", "LS", "MG", "MU", "MZ", "NA", "NZ", "PE", "PY", "SZ", "UY", "ZA", "ZM", "ZW",
    ]

    /// The context the words are read in.
    public struct Context: Sendable {
        public var now: Date
        public var calendar: Calendar
        public var locale: Locale

        public init(now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) {
            self.now = now
            self.calendar = calendar
            self.locale = locale
        }

        var currentYear: Int { calendar.component(.year, from: now) }
        var isSouthern: Bool { locale.region.map { SearchDates.southernRegions.contains($0.identifier) } ?? false }
    }

    /// The longest date expression that starts at `index` of the folded `words`, nil when there is none.
    public static func match(_ words: [String], at index: Int, context: Context) -> Match? {
        let rest = Array(words[index...])
        let parsers: [([String], Context) -> Match?] = [
            between, yearSpan, relativeCount, relative, holiday, season, dayMonthYear, monthDayYear, monthYear, isoDate, decade, year,
        ]
        var best: Match?
        for parser in parsers {
            if let found = parser(rest, context), found.length > (best?.length ?? 0) { best = found }
        }
        return best
    }

    /// The same kind of period before (`by` -1) or after (+1) a date chip's range, with a label to match: a year moves
    /// by its length in years, a month by a month, a week by a week, anything else (a season, a holiday, a day) to the
    /// same days of another year. A label that ends with the year ("Summer 2019", "Christmas 2022") keeps its words.
    public static func shifted(_ range: Range<Date>, label: String, by step: Int, context: Context) -> SearchFilter? {
        let calendar = context.calendar
        let start = range.lowerBound
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: start, to: range.upperBound)
        let startsYear = calendar.dateComponents([.month, .day], from: start) == DateComponents(month: 1, day: 1)
        let startsMonth = calendar.component(.day, from: start) == 1
        let wholeDays = components.hour == 0 && components.minute == 0
        let (unit, amount): (Calendar.Component, Int)
        if startsYear, wholeDays, components.month == 0, components.day == 0, let years = components.year, years > 0 {
            (unit, amount) = (.year, years)
        } else if startsMonth, wholeDays, components.year == 0, components.month == 1, components.day == 0 {
            (unit, amount) = (.month, 1)
        } else if wholeDays, components.year == 0, components.month == 0, components.day == 7 {
            (unit, amount) = (.day, 7)
        } else {
            (unit, amount) = (.year, 1)
        }
        guard let newStart = calendar.date(byAdding: unit, value: step * amount, to: start),
            let newEnd = calendar.date(byAdding: unit, value: step * amount, to: range.upperBound), newEnd > newStart
        else { return nil }
        let newRange = newStart..<newEnd
        let newLabel: String
        if unit == .year, amount == 1, let match = label.range(of: #"\d{4}$"#, options: .regularExpression),
            let oldYear = Int(label[match])
        {
            newLabel = label.replacingCharacters(in: match, with: String(oldYear + step))
        } else {
            newLabel = describe(newRange, context: context)
        }
        return .dateRange(start: newStart, end: newEnd, label: newLabel)
    }

    /// A label for a range: a year ("2019"), a month ("June 2023") or the first and last day.
    public static func describe(_ range: Range<Date>, context: Context) -> String {
        let calendar = context.calendar
        let start = range.lowerBound
        if let year = calendar.dateInterval(of: .year, for: start), year.start == start, year.end == range.upperBound {
            return String(calendar.component(.year, from: start))
        }
        if let month = calendar.dateInterval(of: .month, for: start), month.start == start, month.end == range.upperBound {
            return monthLabel(start, context: context)
        }
        return DateRangeLabel.string(for: range, locale: context.locale, calendar: calendar)
    }

    // MARK: Building blocks

    static func number(_ word: String) -> Int? {
        if let value = Int(word) { return value }
        let ordinal = word.replacingOccurrences(of: #"(st|nd|rd|th|\.)$"#, with: "", options: .regularExpression)
        if ordinal != word, let value = Int(ordinal) { return value }
        return [
            "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
            "eleven": 11, "twelve": 12, "a": 1, "an": 1,
        ][word]
    }

    /// A day of a month in digits: "3", "3rd", "3.".
    static func dayNumber(_ word: String) -> Int? {
        guard word.first?.isNumber == true, word.count <= 4, let value = number(word), (1...31).contains(value) else { return nil }
        return value
    }

    /// A year a photo can have been taken in: four digits, 1900 up to next year. "'19" is not read as a year.
    static func year(_ word: String, context: Context) -> Int? {
        guard word.count == 4, let value = Int(word), value >= 1900, value <= context.currentYear + 1 else { return nil }
        return value
    }

    /// 1…12 for a month name or its abbreviation (three letters or more), in English or the user's language.
    static func month(_ word: String, locale: Locale) -> Int? {
        guard word.count >= 3, Int(word) == nil else { return nil }
        let folded = FuzzyMatch.fold(word.replacingOccurrences(of: ".", with: ""))
        for symbolLocale in [locale, Locale(identifier: "en_US")] {
            let formatter = DateFormatter()
            formatter.locale = symbolLocale
            let full = (formatter.monthSymbols ?? []).map(FuzzyMatch.fold)
            if let index = full.firstIndex(of: folded) { return index + 1 }
            if folded.count >= 3, let index = full.firstIndex(where: { $0.hasPrefix(folded) }) { return index + 1 }
            let short = (formatter.shortMonthSymbols ?? []).map { FuzzyMatch.fold($0.replacingOccurrences(of: ".", with: "")) }
            if let index = short.firstIndex(of: folded) { return index + 1 }
        }
        // "sept" is the one abbreviation of four letters people use.
        return folded == "sept" ? 9 : nil
    }

    static func date(_ year: Int, _ month: Int, _ day: Int, _ calendar: Calendar) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    static func range(_ start: Date?, adding component: Calendar.Component, _ value: Int, calendar: Calendar) -> Range<Date>? {
        guard let start, let end = calendar.date(byAdding: component, value: value, to: start), end > start else { return nil }
        return start..<end
    }

    public static func yearRange(_ year: Int, context: Context) -> Range<Date>? {
        range(date(year, 1, 1, context.calendar), adding: .year, 1, calendar: context.calendar)
    }

    // In the calendar's time zone: with the device's, the first day of a month could be labelled with the month before.
    static func monthLabel(_ start: Date, context: Context) -> String {
        start.formatted(
            Date.FormatStyle(locale: context.locale, calendar: context.calendar, timeZone: context.calendar.timeZone).month(.wide).year())
    }

    static func dayLabel(_ start: Date, context: Context) -> String {
        start.formatted(
            Date.FormatStyle(locale: context.locale, calendar: context.calendar, timeZone: context.calendar.timeZone).day().month(.wide)
                .year())
    }

    // MARK: Parsers (each reads the start of the words)

    /// "2019".
    static func year(_ words: [String], _ context: Context) -> Match? {
        guard let first = words.first, let value = year(first, context: context), let range = yearRange(value, context: context) else {
            return nil
        }
        return Match(range: range, label: String(value), length: 1)
    }

    /// "2018-2020", "2018–2020", "2018 to 2020", "from 2018 to 2020", "2018 until 2020".
    static func yearSpan(_ words: [String], _ context: Context) -> Match? {
        var offset = 0
        if words.first == "from" || words.first == "since" { offset = 1 }
        guard words.count > offset else { return nil }
        let word = words[offset]
        for separator in ["-", "–", "—"] where word.contains(separator) {
            let parts = word.components(separatedBy: separator)
            if parts.count == 2, let from = year(parts[0], context: context), let to = year(parts[1], context: context) {
                return span(from, to, length: offset + 1, context: context)
            }
        }
        guard let from = year(word, context: context) else {
            // "since 2020": up to now.
            return nil
        }
        if words.count > offset + 2, ["to", "until", "till", "through", "-", "–"].contains(words[offset + 1]),
            let to = year(words[offset + 2], context: context)
        {
            return span(from, to, length: offset + 3, context: context)
        }
        if words.first == "since", let start = yearRange(from, context: context)?.lowerBound,
            let end = context.calendar.date(byAdding: .day, value: 1, to: context.calendar.startOfDay(for: context.now)), end > start
        {
            return Match(range: start..<end, label: String(localized: "Since \(String(from))", bundle: .module), length: 2)
        }
        return nil
    }

    /// "between 2018 and 2020", "between june 2020 and march 2021".
    static func between(_ words: [String], _ context: Context) -> Match? {
        guard words.first == "between", let and = words.firstIndex(of: "and"), and > 1 else { return nil }
        let first = Array(words[1..<and])
        let second = Array(words[(and + 1)...])
        guard let start = singleDate(first, context: context), start.length == first.count,
            let end = singleDate(second, context: context)
        else { return nil }
        return combined(start.range.lowerBound, end.range.upperBound, length: 2 + start.length + end.length, context: context)
    }

    static func singleDate(_ words: [String], context: Context) -> Match? {
        guard !words.isEmpty else { return nil }
        let parsers: [([String], Context) -> Match?] = [dayMonthYear, monthDayYear, monthYear, isoDate, season, holiday, year]
        return parsers.compactMap { $0(words, context) }.max { $0.length < $1.length }
    }

    static func span(_ from: Int, _ to: Int, length: Int, context: Context) -> Match? {
        let (low, high) = (min(from, to), max(from, to))
        guard let start = yearRange(low, context: context)?.lowerBound, let end = yearRange(high, context: context)?.upperBound else {
            return nil
        }
        return Match(range: start..<end, label: "\(low)–\(high)", length: length)
    }

    static func combined(_ start: Date, _ end: Date, length: Int, context: Context) -> Match? {
        guard end > start else { return nil }
        return Match(
            range: start..<end, label: DateRangeLabel.string(for: start..<end, locale: context.locale, calendar: context.calendar),
            length: length)
    }

    /// "90s", "1990s", "'90s", "the 90s" (the article is a filler word, left out before).
    static func decade(_ words: [String], _ context: Context) -> Match? {
        guard var word = words.first, word.hasSuffix("s") else { return nil }
        word.removeLast()
        word = word.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
        guard let value = Int(word), value % 10 == 0 else { return nil }
        let first: Int
        switch word.count {
        case 2: first = value >= 30 ? 1900 + value : 2000 + value
        case 4: first = value
        default: return nil
        }
        guard first >= 1900, first <= context.currentYear,
            let start = yearRange(first, context: context)?.lowerBound,
            let end = context.calendar.date(byAdding: .year, value: 10, to: start)
        else { return nil }
        return Match(range: start..<end, label: "\(first)s", length: 1)
    }

    /// "2021-03-03", "2021-03".
    static func isoDate(_ words: [String], _ context: Context) -> Match? {
        guard let word = words.first else { return nil }
        let parts = word.split(separator: "-").map(String.init)
        guard parts.count >= 2, let y = year(parts[0], context: context), let m = Int(parts[1]), (1...12).contains(m) else { return nil }
        if parts.count == 2 {
            guard let range = range(date(y, m, 1, context.calendar), adding: .month, 1, calendar: context.calendar) else { return nil }
            return Match(range: range, label: monthLabel(range.lowerBound, context: context), length: 1)
        }
        guard parts.count == 3, let d = Int(parts[2]), (1...31).contains(d),
            let range = range(date(y, m, d, context.calendar), adding: .day, 1, calendar: context.calendar),
            context.calendar.component(.month, from: range.lowerBound) == m
        else { return nil }
        return Match(range: range, label: dayLabel(range.lowerBound, context: context), length: 1)
    }

    /// "june 2023", "jun", "june of 2023" (a month without a year is the last one that has begun).
    static func monthYear(_ words: [String], _ context: Context) -> Match? {
        guard let first = words.first, let m = month(first, locale: context.locale) else { return nil }
        var length = 1
        var y: Int?
        if words.count > 1, let value = year(words[1], context: context) {
            y = value
            length = 2
        } else if words.count > 2, words[1] == "of", let value = year(words[2], context: context) {
            y = value
            length = 3
        }
        let resolved = y ?? lastStarted(month: m, context: context)
        guard let range = range(date(resolved, m, 1, context.calendar), adding: .month, 1, calendar: context.calendar) else { return nil }
        return Match(range: range, label: monthLabel(range.lowerBound, context: context), length: length)
    }

    /// The year of the last `month` that has begun.
    static func lastStarted(month: Int, context: Context) -> Int {
        let current = context.calendar.component(.month, from: context.now)
        return month <= current ? context.currentYear : context.currentYear - 1
    }

    /// "3 march 2021", "3rd of march", "3. märz 2021".
    static func dayMonthYear(_ words: [String], _ context: Context) -> Match? {
        guard words.count >= 2, let d = dayNumber(words[0]) else { return nil }
        var index = 1
        if words[index] == "of", words.count > 2 { index += 1 }
        guard let m = month(words[index], locale: context.locale) else { return nil }
        return day(d, month: m, words: words, yearAt: index + 1, context: context)
    }

    /// "march 3 2021", "march 3rd".
    static func monthDayYear(_ words: [String], _ context: Context) -> Match? {
        guard words.count >= 2, let m = month(words[0], locale: context.locale), let d = dayNumber(words[1]) else { return nil }
        return day(d, month: m, words: words, yearAt: 2, context: context)
    }

    static func day(_ d: Int, month m: Int, words: [String], yearAt index: Int, context: Context) -> Match? {
        var y: Int
        var length = index
        if words.count > index, let value = year(words[index], context: context) {
            y = value
            length += 1
        } else {
            // Without a year: the last time that day came.
            y = context.currentYear
            if let candidate = date(y, m, d, context.calendar), candidate > context.now { y -= 1 }
        }
        guard let range = range(date(y, m, d, context.calendar), adding: .day, 1, calendar: context.calendar),
            context.calendar.component(.month, from: range.lowerBound) == m
        else { return nil }
        return Match(range: range, label: dayLabel(range.lowerBound, context: context), length: length)
    }

    // MARK: Seasons

    static func season(_ word: String) -> Season? {
        switch word {
        case "spring", "springtime": .spring
        case "summer", "summertime": .summer
        case "autumn", "fall": .autumn
        case "winter", "wintertime": .winter
        default: nil
        }
    }

    /// The season named after `year`: summer 2019; winter 2019 is December 2019 to February 2020 (in the south, summer
    /// 2019 is December 2019 to February 2020).
    static func seasonRange(_ season: Season, year: Int, context: Context) -> Range<Date>? {
        var startMonth: Int
        switch season {
        case .spring: startMonth = 3
        case .summer: startMonth = 6
        case .autumn: startMonth = 9
        case .winter: startMonth = 12
        }
        if context.isSouthern { startMonth = (startMonth + 6 - 1) % 12 + 1 }
        return range(date(year, startMonth, 1, context.calendar), adding: .month, 3, calendar: context.calendar)
    }

    static func seasonLabel(_ season: Season, year: Int) -> String {
        let y = String(year)
        return switch season {
        case .spring: String(localized: "Spring \(y)", bundle: .module, comment: "A search for photos of a season, e.g. Spring 2019.")
        case .summer: String(localized: "Summer \(y)", bundle: .module, comment: "A search for photos of a season, e.g. Summer 2019.")
        case .autumn: String(localized: "Autumn \(y)", bundle: .module, comment: "A search for photos of a season, e.g. Autumn 2019.")
        case .winter: String(localized: "Winter \(y)", bundle: .module, comment: "A search for photos of a season, e.g. Winter 2019/20.")
        }
    }

    /// "summer 2019", "summer of 2019", "last summer", "this summer", "summer" (the last one that has begun).
    static func season(_ words: [String], _ context: Context) -> Match? {
        var index = 0
        var which: String?
        if let first = words.first, ["last", "this", "past", "previous"].contains(first) {
            which = first
            index = 1
        }
        guard words.count > index, let season = season(words[index]) else { return nil }
        var length = index + 1
        var named: Int?
        if which == nil {
            if words.count > index + 1, let value = year(words[index + 1], context: context) {
                named = value
                length += 1
            } else if words.count > index + 2, words[index + 1] == "of", let value = year(words[index + 2], context: context) {
                named = value
                length += 2
            }
        }
        let y: Int
        if let named {
            y = named
        } else {
            // The occurrences around now, newest first: this year's, last year's, the one before.
            let years = [context.currentYear, context.currentYear - 1, context.currentYear - 2]
            let started = years.filter { (seasonRange(season, year: $0, context: context)?.lowerBound ?? .distantFuture) <= context.now }
            switch which {
            case "last", "past", "previous":
                // The last one that is over.
                guard
                    let value = years.first(where: {
                        (seasonRange(season, year: $0, context: context)?.upperBound ?? .distantFuture) <= context.now
                    })
                else { return nil }
                y = value
            default:
                guard let value = started.first else { return nil }
                y = value
            }
        }
        guard let range = seasonRange(season, year: y, context: context) else { return nil }
        return Match(range: range, label: seasonLabel(season, year: y), length: length)
    }

    // MARK: Holidays

    /// Western Easter Sunday (Anonymous Gregorian algorithm).
    static func easter(_ year: Int) -> (month: Int, day: Int) {
        let a = year % 19
        let b = year / 100
        let c = year % 100
        let d = b / 4
        let e = b % 4
        let f = (b + 8) / 25
        let g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4
        let k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31
        let day = (h + l - 7 * m + 114) % 31 + 1
        return (month, day)
    }

    enum Holiday: CaseIterable {
        case christmasEve, christmas, newYearsEve, newYearsDay, halloween, valentines, easter

        /// The days of the holiday in `year`.
        func range(in year: Int, calendar: Calendar) -> Range<Date>? {
            let (month, day, count): (Int, Int, Int) =
                switch self {
                case .christmasEve: (12, 24, 1)
                // Christmas Eve to Boxing Day: the photos of Christmas.
                case .christmas: (12, 24, 3)
                case .newYearsEve: (12, 31, 1)
                case .newYearsDay: (1, 1, 1)
                case .halloween: (10, 31, 1)
                case .valentines: (2, 14, 1)
                case .easter: (SearchDates.easter(year).month, SearchDates.easter(year).day, 1)
                }
            guard var start = SearchDates.date(year, month, day, calendar) else { return nil }
            var days = count
            if self == .easter {
                // Good Friday to Easter Monday.
                guard let friday = calendar.date(byAdding: .day, value: -2, to: start) else { return nil }
                start = friday
                days = 4
            }
            return SearchDates.range(start, adding: .day, days, calendar: calendar)
        }

        var label: String {
            switch self {
            case .christmasEve: String(localized: "Christmas Eve", bundle: .module, comment: "A search for the photos of a holiday.")
            case .christmas: String(localized: "Christmas", bundle: .module, comment: "A search for the photos of a holiday.")
            case .newYearsEve: String(localized: "New Year’s Eve", bundle: .module, comment: "A search for the photos of a holiday.")
            case .newYearsDay: String(localized: "New Year’s Day", bundle: .module, comment: "A search for the photos of a holiday.")
            case .halloween: String(localized: "Halloween", bundle: .module, comment: "A search for the photos of a holiday.")
            case .valentines: String(localized: "Valentine’s Day", bundle: .module, comment: "A search for the photos of a holiday.")
            case .easter: String(localized: "Easter", bundle: .module, comment: "A search for the photos of a holiday.")
            }
        }

        /// The words that name it, and how many words they are.
        static func named(_ words: [String]) -> (Holiday, Int)? {
            let phrases: [([String], Holiday)] = [
                (["christmas", "eve"], .christmasEve), (["xmas", "eve"], .christmasEve), (["new", "year's", "eve"], .newYearsEve),
                (["new", "years", "eve"], .newYearsEve), (["new", "year", "eve"], .newYearsEve), (["new", "year's", "day"], .newYearsDay),
                (["new", "years", "day"], .newYearsDay), (["valentine's", "day"], .valentines), (["valentines", "day"], .valentines),
                (["christmas"], .christmas), (["xmas"], .christmas), (["nye"], .newYearsEve), (["silvester"], .newYearsEve),
                (["halloween"], .halloween), (["valentine's"], .valentines), (["valentines"], .valentines), (["easter"], .easter),
                (["weihnachten"], .christmas), (["ostern"], .easter),
            ]
            for (phrase, holiday) in phrases where words.starts(with: phrase) { return (holiday, phrase.count) }
            return nil
        }
    }

    /// "christmas 2022", "christmas", "easter 2019", "new year's eve".
    static func holiday(_ words: [String], _ context: Context) -> Match? {
        var index = 0
        var which: String?
        if let first = words.first, ["last", "this"].contains(first) {
            which = first
            index = 1
        }
        guard words.count > index, case let (holiday, count)? = Holiday.named(Array(words[index...])) else { return nil }
        var length = index + count
        var y: Int?
        if which == nil, words.count > length, let value = year(words[length], context: context) {
            y = value
            length += 1
        }
        func occurrence(_ year: Int) -> Range<Date>? { holiday.range(in: year, calendar: context.calendar) }
        let resolved: Int
        if let y {
            resolved = y
        } else {
            // The last one that has begun ("last": that is over).
            let mustBeOver = which == "last"
            guard
                let value = [context.currentYear, context.currentYear - 1].first(where: { year in
                    guard let range = occurrence(year) else { return false }
                    return mustBeOver ? range.upperBound <= context.now : range.lowerBound <= context.now
                })
            else { return nil }
            resolved = value
        }
        guard let range = occurrence(resolved) else { return nil }
        return Match(range: range, label: "\(holiday.label) \(resolved)", length: length)
    }

    // MARK: Relative

    static func unit(_ word: String) -> Calendar.Component? {
        switch word {
        case "day", "days": .day
        case "week", "weeks": .weekOfYear
        case "weekend", "weekends": nil
        case "month", "months": .month
        case "year", "years": .year
        default: nil
        }
    }

    /// "today", "yesterday", "this week", "last month", "this year", "last weekend", "recently".
    static func relative(_ words: [String], _ context: Context) -> Match? {
        let calendar = context.calendar
        let today = calendar.startOfDay(for: context.now)
        guard let first = words.first else { return nil }
        switch first {
        case "today":
            guard let range = range(today, adding: .day, 1, calendar: calendar) else { return nil }
            return Match(range: range, label: String(localized: "Today", bundle: .module, comment: "A search date: today."), length: 1)
        case "yesterday":
            guard let range = range(calendar.date(byAdding: .day, value: -1, to: today), adding: .day, 1, calendar: calendar) else {
                return nil
            }
            return Match(
                range: range, label: String(localized: "Yesterday", bundle: .module, comment: "A search date: yesterday."), length: 1)
        case "recent", "recently", "lately":
            guard let start = calendar.date(byAdding: .day, value: -30, to: today),
                let end = calendar.date(byAdding: .day, value: 1, to: today)
            else { return nil }
            return Match(
                range: start..<end, label: String(localized: "Last 30 days", bundle: .module, comment: "A search date: the last 30 days."),
                length: 1)
        case "this", "last", "past", "previous":
            guard words.count > 1 else { return nil }
            let isThis = first == "this"
            if words[1] == "weekend" || words[1] == "weekends" { return weekend(last: !isThis, context: context) }
            if !isThis, let m = month(words[1], locale: context.locale) {
                // "last june": the last June that is over.
                let current = calendar.component(.month, from: context.now)
                let y = m < current ? context.currentYear : context.currentYear - 1
                guard let range = range(date(y, m, 1, calendar), adding: .month, 1, calendar: calendar) else { return nil }
                return Match(range: range, label: monthLabel(range.lowerBound, context: context), length: 2)
            }
            guard let component = unit(words[1]), let interval = calendar.dateInterval(of: component, for: context.now) else { return nil }
            let start = isThis ? interval.start : calendar.date(byAdding: component, value: -1, to: interval.start)
            guard let range = range(start, adding: component, 1, calendar: calendar) else { return nil }
            return Match(range: range, label: relativeLabel(component, last: !isThis, range: range, context: context), length: 2)
        default:
            return nil
        }
    }

    static func relativeLabel(_ component: Calendar.Component, last: Bool, range: Range<Date>, context: Context) -> String {
        switch (component, last) {
        case (.day, _): DateRangeLabel.string(for: range, locale: context.locale, calendar: context.calendar)
        case (.weekOfYear, false): String(localized: "This week", bundle: .module, comment: "A search date.")
        case (.weekOfYear, true): String(localized: "Last week", bundle: .module, comment: "A search date.")
        case (.month, _): monthLabel(range.lowerBound, context: context)
        case (.year, _): String(context.calendar.component(.year, from: range.lowerBound))
        default: DateRangeLabel.string(for: range, locale: context.locale, calendar: context.calendar)
        }
    }

    /// "this weekend": the one on now, else the last one; "last weekend": the last one that is over (on a weekend, the
    /// one before it).
    static func weekend(last: Bool, context: Context) -> Match? {
        let calendar = context.calendar
        var interval: DateInterval
        if let current = calendar.dateIntervalOfWeekend(containing: context.now) {
            interval = current
            if last {
                guard let previous = calendar.nextWeekend(startingAfter: current.start, direction: .backward) else { return nil }
                interval = previous
            }
        } else if let previous = calendar.nextWeekend(startingAfter: context.now, direction: .backward) {
            interval = previous
        } else {
            return nil
        }
        let range = interval.start..<interval.end
        return Match(range: range, label: DateRangeLabel.string(for: range, locale: context.locale, calendar: calendar), length: 2)
    }

    /// "3 years ago", "two weeks ago", "a month ago"; "last 10 days", "past 2 weeks", "past three months".
    static func relativeCount(_ words: [String], _ context: Context) -> Match? {
        let calendar = context.calendar
        let today = calendar.startOfDay(for: context.now)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return nil }
        if words.count >= 3, ["last", "past", "previous"].contains(words[0]), let n = number(words[1]), n > 0, n <= 100,
            let component = unit(words[2]), let start = calendar.date(byAdding: component, value: -n, to: tomorrow)
        {
            return combined(start, tomorrow, length: 3, context: context)
        }
        if words.count >= 3, words[2] == "ago", let n = number(words[0]), n > 0, n <= 100, let component = unit(words[1]),
            let then = calendar.date(byAdding: component, value: -n, to: context.now),
            let interval = calendar.dateInterval(of: component, for: then)
        {
            let range = interval.start..<interval.end
            let label =
                component == .year
                ? String(calendar.component(.year, from: interval.start))
                : (component == .month
                    ? monthLabel(interval.start, context: context)
                    : DateRangeLabel.string(for: range, locale: context.locale, calendar: calendar))
            return Match(range: range, label: label, length: 3)
        }
        return nil
    }
}
