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
