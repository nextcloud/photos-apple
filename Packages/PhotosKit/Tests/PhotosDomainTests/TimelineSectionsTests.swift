// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosDomain

@Suite struct TimelineSectionsTests {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    @Test func groupsByMonthAndLocalDay() {
        let stamps = [date(2026, 11, 22, 23), date(2026, 11, 22, 1), date(2026, 11, 3), date(2026, 10, 31), date(2025, 1, 1)]
        let months = TimelineSections.group(timestamps: stamps, calendar: calendar)
        #expect(months.map(\.id) == [202611, 202610, 202501])
        #expect(months[0].days.map(\.id) == [20261122, 20261103])
        #expect(months[0].days[0].range == 0..<2)
        #expect(months[0].range == 0..<3)
        #expect(months[2].range == 4..<5)
        #expect(TimelineSections.years(of: months).map(\.year) == [2026, 2025])
    }

    @Test func sectionsPerGranularity() {
        let stamps = [date(2026, 11, 22, 23), date(2026, 11, 22, 1), date(2026, 11, 3), date(2026, 10, 31), date(2025, 1, 1)]
        let months = TimelineSections.group(timestamps: stamps, calendar: calendar)
        let days = TimelineSections.sections(of: months, granularity: .day)
        #expect(days.map(\.id) == [20261122, 20261103, 20261031, 20250101])
        #expect(days.map(\.startsMonth) == [true, false, true, true])
        #expect(days.map(\.range) == [0..<2, 2..<3, 3..<4, 4..<5])
        let byMonth = TimelineSections.sections(of: months, granularity: .month)
        #expect(byMonth.map(\.id) == [202611, 202610, 202501])
        #expect(byMonth.map(\.range) == [0..<3, 3..<4, 4..<5])
        let byYear = TimelineSections.sections(of: months, granularity: .year)
        #expect(byYear.map(\.id) == [2026, 2025])
        #expect(byYear.map(\.range) == [0..<4, 4..<5])
        #expect(byYear.map(\.year) == [2026, 2025])
    }

    /// The calendar is only asked once per day; the result must be what asking it for every item gives, also across
    /// daylight saving changes, at midnight and for unsorted input.
    @Test func groupingMatchesPerItemCalendarLookups() {
        var generator = SeededGenerator(seed: 42)
        var stamps: [Date] = []
        // Around both DST changes of 2026 in Berlin, minute by minute across the nights.
        for (month, day) in [(3, 28), (3, 29), (10, 24), (10, 25), (12, 31)] {
            let start = date(2026, month, day, 21)
            for minute in stride(from: 0, to: 9 * 60, by: 7) { stamps.append(start.addingTimeInterval(Double(minute) * 60)) }
        }
        for _ in 0..<3000 {
            stamps.append(date(2020, 1, 1).addingTimeInterval(Double.random(in: 0...(7 * 365 * 86400), using: &generator)))
        }
        for sorted in [true, false] {
            let input = sorted ? stamps.sorted(by: >) : stamps
            let months = TimelineSections.group(timestamps: input, calendar: calendar)
            var expected: [Int] = []
            for stamp in input {
                let parts = calendar.dateComponents([.year, .month, .day], from: stamp)
                let key = parts.year! * 10000 + parts.month! * 100 + parts.day!
                if expected.last != key { expected.append(key) }
            }
            #expect(months.flatMap { $0.days.map(\.id) } == expected)
            #expect(months.last?.range.upperBound == input.count)
            for month in months {
                #expect(month.days.first?.range.lowerBound == month.range.lowerBound)
                #expect(month.days.last?.range.upperBound == month.range.upperBound)
                for day in month.days {
                    #expect(day.date == calendar.startOfDay(for: input[day.range.lowerBound]))
                    #expect(day.id / 100 == month.id)
                }
            }
        }
    }

    /// SPEC §10: sectioning a 100 000-item library. Prints the time; the bound is generous for slow CI machines.
    @Test func sectioningPerformance100k() {
        var generator = SeededGenerator(seed: 7)
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        let stamps = (0..<100_000).map { _ in now.addingTimeInterval(-Double.random(in: 0...(8 * 365 * 86400), using: &generator)) }
            .sorted(by: >)
        let clock = ContinuousClock()
        var best = Duration.seconds(1000)
        var sectionCount = 0
        for _ in 0..<5 {
            let elapsed = clock.measure {
                let months = TimelineSections.group(timestamps: stamps, calendar: calendar)
                sectionCount = TimelineSections.sections(of: months, granularity: .day).count
            }
            best = min(best, elapsed)
        }
        print("PERF sectioning 100k items into \(sectionCount) day sections: \(best)")
        #expect(sectionCount > 2900)
        #expect(best < .milliseconds(250))
    }

    @Test func emptyInput() {
        #expect(TimelineSections.group(timestamps: []).isEmpty)
    }

    @Test func dayLabels() {
        let now = date(2026, 11, 22, 15)
        #expect(DayLabel.label(for: date(2026, 11, 22, 9), now: now, calendar: calendar) == "Today")
        #expect(DayLabel.label(for: date(2026, 11, 21, 9), now: now, calendar: calendar) == "Yesterday")
    }

    @Test func captureOffsets() {
        #expect(CaptureTime.parseOffset("+09:00") == 9 * 3600)
        #expect(CaptureTime.parseOffset("-0530") == -(5 * 3600 + 30 * 60))
        #expect(CaptureTime.parseOffset("+15:00") == nil)
        #expect(CaptureTime.parseOffset("+01:60") == nil)
        #expect(CaptureTime.parseOffset("garbage") == nil)
    }
}

/// Deterministic random numbers for reproducible test data (SplitMix64).
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
