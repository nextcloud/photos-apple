// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosDomain
import PhotosModel
import PhotosStore
import SwiftUI
import Testing

@testable import PhotosAppUI

/// Moves between the Library's zoom levels (SPEC §15.5).
@MainActor
@Suite struct LibraryZoomModelTests {
    let calendar = Calendar.current
    /// The grid's densest zoom step, and one in the middle, on this platform.
    let densest = GridColumns.options.max() ?? 13
    let middle = GridColumns.options[GridColumns.options.count / 2]

    func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    func media(_ id: FileID, _ date: Date) -> GridMedia {
        GridMedia(
            MediaItem(fileId: id, path: "/Photos/\(id).jpg", mimeType: "image/jpeg", etag: "e\(id)", modifiedAt: date, capturedAt: date))
    }

    func model() throws -> (LibraryZoomModel, UserDefaults) {
        let defaults = try #require(UserDefaults(suiteName: "zoom-\(UUID().uuidString)"))
        let model = LibraryZoomModel(defaults: defaults)
        model.summary = LibrarySummary(
            items: [
                media(1, date(2026, 11, 20)), media(2, date(2026, 11, 3)), media(3, date(2026, 10, 9)), media(4, date(2025, 5, 1)),
                media(5, date(2025, 5, 1)),
            ], calendar: calendar)
        return (model, defaults)
    }

    @Test func pinchingOutOfTheGridAndBackIn() throws {
        let (model, defaults) = try model()
        var step = 0
        model.setGridStep = { step = $0 }
        #expect(model.level == .all)
        // Out of the densest step on photo 3: its day, and the grid comes back at the default step later.
        model.leaveGrid(from: 3, at: .center, currentStep: densest)
        #expect(model.level == .days)
        #expect(model.focus[.days] == 2026_10_09)
        #expect(defaults.string(forKey: LibraryZoomLevel.storageKey) == "days")
        #expect(model.lastGridStep == GridColumns.default)
        // Out again: the month and the year of that day.
        let day = try #require(model.summary.days.first { $0.id == 2026_10_09 })
        model.move(from: .days, by: -1, bucket: day)
        #expect(model.level == .months)
        #expect(model.focus[.months] == 2026_10)
        let month = try #require(model.summary.months.first { $0.id == 2026_10 })
        model.move(from: .months, by: -1, bucket: month)
        #expect(model.level == .years)
        #expect(model.focus[.years] == 2026)
        // A fast pinch in on 2025 goes through months and days into the grid, at the year's first photo.
        let year = try #require(model.summary.years.first { $0.id == 2025 })
        model.move(from: .years, by: 3, bucket: year, at: UnitPoint(x: 0.5, y: 0.5))
        #expect(model.level == .all)
        #expect(step == GridColumns.default)
        #expect(model.gridPlacement?.fileId == 4)
        // A tapped photo of a day is the one the grid shows.
        model.select(.days, currentStep: middle)
        #expect(model.lastGridStep == middle)
        model.move(from: .days, by: 1, bucket: model.summary.days.last, photo: 5)
        #expect(model.gridPlacement?.fileId == 5)
        #expect(step == middle)
    }

    @Test func pickerAndKeysKeepWhatIsOnScreen() throws {
        let (model, _) = try model()
        model.gridTopItem = { 2 }
        model.select(.months, currentStep: 5)
        #expect(model.level == .months)
        #expect(model.focus[.months] == 2026_11)
        model.visible[.months] = 2025_05
        model.select(.years, currentStep: 5)
        #expect(model.focus[.years] == 2025)
        // ⌘+ on the years: the months of the year on screen.
        model.visible[.years] = 2025
        model.step(zoomIn: true, currentStep: 5)
        #expect(model.level == .months)
        #expect(model.focus[.months] == 2025_05)
        model.select(.all, currentStep: 5)
        #expect(model.level == .all)
        // ⌘− in the grid only comes here at the densest step: the days.
        model.step(zoomIn: false, currentStep: densest)
        #expect(model.level == .days)
        #expect(model.snaps == 5)
    }
}
