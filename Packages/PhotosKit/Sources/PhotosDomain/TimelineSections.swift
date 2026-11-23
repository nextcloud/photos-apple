// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// A day within a month section.
public struct TimelineDay: Hashable, Sendable, Identifiable {
    /// `YYYYMMDD` in the local calendar.
    public var id: Int
    public var date: Date
    /// Range into the flat item array.
    public var range: Range<Int>
}

/// A month section of the timeline.
public struct TimelineMonth: Hashable, Sendable, Identifiable {
    /// `YYYYMM` in the local calendar.
    public var id: Int
    public var date: Date
    public var range: Range<Int>
    public var days: [TimelineDay]

    public var year: Int { id / 100 }
}

/// How finely the timeline is cut into sections: days at normal zoom, months and years when zoomed out.
public enum TimelineGranularity: Int, Sendable, Hashable, CaseIterable {
    case day, month, year
}

/// One section of the timeline at a given granularity.
public struct TimelineSection: Hashable, Sendable, Identifiable {
    /// `YYYYMMDD`, `YYYYMM` or `YYYY` in the local calendar, depending on the granularity.
    public var id: Int
    /// Start of the day, month, or of the newest month of the year.
    public var date: Date
    /// Range into the flat item array.
    public var range: Range<Int>
    public var granularity: TimelineGranularity
    /// Day sections: the newest day of its month (the header carries the month title).
    public var startsMonth: Bool
    public var year: Int
}

/// Groups items (sorted newest first) into months and local calendar days (SPEC §6.4, web: dayGrouping.ts).
public enum TimelineSections {
    public static func group(timestamps: [Date], calendar: Calendar = .current) -> [TimelineMonth] {
        group(timestamps, calendar: calendar) { $0 }
    }

    /// Groups any random-access collection without copying its timestamps out first.
    ///
    /// The calendar is only asked when an item falls outside the day of the item before it, so a library costs one
    /// calendar lookup per day rather than one per item.
    public static func group<Items: RandomAccessCollection>(
        _ items: Items, calendar: Calendar = .current, timestamp: (Items.Element) -> Date
    ) -> [TimelineMonth] {
        var months: [TimelineMonth] = []
        var currentMonthKey = -1
        var currentDayKey = -1
        var monthStart = 0
        var dayStart = 0
        var days: [TimelineDay] = []
        var monthDate = Date()
        var dayDate = Date()
        // The current day as a half-open interval of reference times.
        var dayLower = Double.infinity
        var dayUpper = -Double.infinity

        func closeDay(at end: Int) {
            guard currentDayKey >= 0, end > dayStart else { return }
            days.append(TimelineDay(id: currentDayKey, date: dayDate, range: dayStart..<end))
        }
        func closeMonth(at end: Int) {
            guard currentMonthKey >= 0, end > monthStart else { return }
            closeDay(at: end)
            months.append(TimelineMonth(id: currentMonthKey, date: monthDate, range: monthStart..<end, days: days))
            days = []
        }

        var index = 0
        for item in items {
            defer { index += 1 }
            let stamp = timestamp(item)
            let reference = stamp.timeIntervalSinceReferenceDate
            if reference >= dayLower && reference < dayUpper { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: stamp)
            let monthKey = (parts.year ?? 0) * 100 + (parts.month ?? 0)
            let dayKey = monthKey * 100 + (parts.day ?? 0)
            let startOfDay = calendar.startOfDay(for: stamp)
            if let next = calendar.date(byAdding: .day, value: 1, to: startOfDay), next > startOfDay {
                dayLower = startOfDay.timeIntervalSinceReferenceDate
                dayUpper = next.timeIntervalSinceReferenceDate
            } else {
                dayLower = .infinity
                dayUpper = -.infinity
            }
            if monthKey != currentMonthKey {
                closeMonth(at: index)
                currentMonthKey = monthKey
                monthStart = index
                monthDate = calendar.date(from: DateComponents(year: parts.year, month: parts.month, day: 1)) ?? stamp
                currentDayKey = dayKey
                dayStart = index
                dayDate = startOfDay
            } else if dayKey != currentDayKey {
                closeDay(at: index)
                currentDayKey = dayKey
                dayStart = index
                dayDate = startOfDay
            }
        }
        closeMonth(at: index)
        return months
    }

    /// Flattens months into the sections shown at a granularity. No strings are formatted here (see `DayLabel`).
    public static func sections(of months: [TimelineMonth], granularity: TimelineGranularity) -> [TimelineSection] {
        var result: [TimelineSection] = []
        switch granularity {
        case .day:
            result.reserveCapacity(months.reduce(0) { $0 + $1.days.count })
            for month in months {
                for (index, day) in month.days.enumerated() {
                    result.append(
                        TimelineSection(
                            id: day.id, date: day.date, range: day.range, granularity: .day, startsMonth: index == 0, year: month.year))
                }
            }
        case .month:
            result.reserveCapacity(months.count)
            for month in months {
                result.append(
                    TimelineSection(
                        id: month.id, date: month.date, range: month.range, granularity: .month, startsMonth: true, year: month.year))
            }
        case .year:
            for month in months {
                if let last = result.last, last.year == month.year, last.range.upperBound == month.range.lowerBound {
                    result[result.count - 1].range = last.range.lowerBound..<month.range.upperBound
                } else {
                    result.append(
                        TimelineSection(
                            id: month.year, date: month.date, range: month.range, granularity: .year, startsMonth: true,
                            year: month.year))
                }
            }
        }
        return result
    }

    /// Distinct years in newest-first order with the index of their first item (for the scrubber).
    public static func years(of months: [TimelineMonth]) -> [(year: Int, firstIndex: Int)] {
        var result: [(Int, Int)] = []
        for month in months where result.last?.0 != month.year {
            result.append((month.year, month.range.lowerBound))
        }
        return result
    }
}

/// Labels for day headers: "Today", "Yesterday", weekday within the last week, else a date.
public enum DayLabel {
    public static func label(for date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "Today", bundle: .module) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "Yesterday", bundle: .module)
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 99
        if days >= 0 && days < 7 {
            return date.formatted(Date.FormatStyle(locale: locale).weekday(.wide))
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let style =
            sameYear
            ? Date.FormatStyle(locale: locale).weekday(.abbreviated).day().month(.wide)
            : Date.FormatStyle(locale: locale).day().month(.wide).year()
        return date.formatted(style)
    }

    public static func monthLabel(for date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return date.formatted(
            sameYear ? Date.FormatStyle(locale: locale).month(.wide) : Date.FormatStyle(locale: locale).month(.wide).year())
    }

    /// Month with year, whatever the current year is (date scrubber).
    public static func monthYearLabel(for date: Date, locale: Locale = .current) -> String {
        date.formatted(Date.FormatStyle(locale: locale).month(.wide).year())
    }

    public static func yearLabel(for date: Date, locale: Locale = .current) -> String {
        date.formatted(Date.FormatStyle(locale: locale).year())
    }
}
