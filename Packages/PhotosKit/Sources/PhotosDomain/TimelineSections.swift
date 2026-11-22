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

/// Groups items (sorted newest first) into months and local calendar days (SPEC §6.4, web: dayGrouping.ts).
public enum TimelineSections {
    public static func group(timestamps: [Date], calendar: Calendar = .current) -> [TimelineMonth] {
        var months: [TimelineMonth] = []
        var currentMonthKey = -1
        var currentDayKey = -1
        var monthStart = 0
        var dayStart = 0
        var days: [TimelineDay] = []
        var monthDate = Date()
        var dayDate = Date()

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

        for (index, timestamp) in timestamps.enumerated() {
            let parts = calendar.dateComponents([.year, .month, .day], from: timestamp)
            let monthKey = (parts.year ?? 0) * 100 + (parts.month ?? 0)
            let dayKey = monthKey * 100 + (parts.day ?? 0)
            if monthKey != currentMonthKey {
                closeMonth(at: index)
                currentMonthKey = monthKey
                monthStart = index
                monthDate = calendar.date(from: DateComponents(year: parts.year, month: parts.month, day: 1)) ?? timestamp
                currentDayKey = dayKey
                dayStart = index
                dayDate = calendar.startOfDay(for: timestamp)
            } else if dayKey != currentDayKey {
                closeDay(at: index)
                currentDayKey = dayKey
                dayStart = index
                dayDate = calendar.startOfDay(for: timestamp)
            }
        }
        closeMonth(at: timestamps.count)
        return months
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
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "Today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "Yesterday")
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
}
