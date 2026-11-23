// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosDomain
import PhotosModel
import Testing

@testable import PhotosStore

@Suite struct GridModelTests {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    func media(_ id: FileID, _ date: Date, favorite: Bool = false, etag: String? = nil) -> GridMedia {
        GridMedia(
            MediaItem(
                fileId: id, path: "/Photos/\(id).jpg", mimeType: "image/jpeg", etag: etag ?? "e\(id)", modifiedAt: date, capturedAt: date,
                isFavorite: favorite))
    }

    var sample: [GridMedia] {
        [
            media(1, date(2026, 11, 22, 23)), media(2, date(2026, 11, 22, 1)), media(3, date(2026, 11, 3)), media(4, date(2026, 10, 31)),
            media(5, date(2025, 1, 1)),
        ]
    }

    @Test func daySectionsAndLookups() {
        let model = GridModel(items: sample, sectioning: .timeline(.day), calendar: calendar)
        #expect(model.sections.map(\.id) == [20261122, 20261103, 20261031, 20250101])
        #expect(model.sections.map(\.kind) == [.day, .day, .day, .day])
        #expect(model.sections.map(\.startsMonth) == [true, false, true, true])
        #expect(model.numberOfItems(inSection: 0) == 2)
        #expect(model.numberOfItems(inSection: 9) == 0)
        #expect(model.item(section: 0, item: 1)?.fileId == 2)
        #expect(model.item(section: 0, item: 2) == nil)
        #expect(model.item(section: 4, item: 0) == nil)
        #expect(model[4]?.fileId == 4)
        #expect(model[99] == nil)
        for (index, item) in sample.enumerated() {
            let position = model.position(of: item.fileId)
            #expect(position != nil)
            if let position {
                #expect(model.flatIndex(section: position.section, item: position.item) == index)
                #expect(model.item(section: position.section, item: position.item)?.fileId == item.fileId)
            }
        }
        #expect(model.position(of: 99) == nil)
        #expect(model.yearStarts.map(\.year) == [2026, 2025])
        #expect(model.yearStarts.map(\.section) == [0, 3])
        #expect(model.ids == [1, 2, 3, 4, 5])
    }

    @Test func monthsYearsAndFlat() {
        let days = GridModel(items: sample, sectioning: .timeline(.day), calendar: calendar)
        let months = days.resectioned(.timeline(.month), calendar: calendar)
        #expect(months.sections.map(\.id) == [202611, 202610, 202501])
        #expect(months.sections.map(\.kind) == [.month, .month, .month])
        #expect(months.position(of: 3)?.section == 0)
        #expect(months.position(of: 3)?.item == 2)
        let years = days.resectioned(.timeline(.year), calendar: calendar)
        #expect(years.sections.map(\.id) == [2026, 2025])
        #expect(years.sections.map(\.range) == [0..<4, 4..<5])
        let flat = GridModel(items: sample, sectioning: .flat)
        #expect(flat.sections.count == 1)
        #expect(!flat.hasHeaders)
        #expect(flat.position(of: 5)?.item == 4)
        #expect(GridModel(items: [], sectioning: .flat).sections.isEmpty)
        #expect(GridModel.empty.position(of: 1) == nil)
    }

    /// A favourite toggled or a preview regenerated must not reload the grid; only that tile is reconfigured.
    @Test func changesBetweenModels() {
        let old = GridModel(items: sample, sectioning: .timeline(.day), calendar: calendar)
        #expect(GridModel(items: sample, sectioning: .timeline(.day), calendar: calendar).change(from: old) == .none)

        var favourite = sample
        favourite[2] = media(3, date(2026, 11, 3), favorite: true)
        favourite[4] = media(5, date(2025, 1, 1), etag: "new")
        #expect(GridModel(items: favourite, sectioning: .timeline(.day), calendar: calendar).change(from: old) == .content([3, 5]))

        let added = [media(9, date(2026, 11, 23))] + sample
        #expect(GridModel(items: added, sectioning: .timeline(.day), calendar: calendar).change(from: old) == .structure)
        #expect(GridModel(items: Array(sample.dropLast()), sectioning: .timeline(.day), calendar: calendar).change(from: old) == .structure)

        // Same count, another item in the place of one.
        var replaced = sample
        replaced[4] = media(6, date(2025, 1, 1))
        #expect(GridModel(items: replaced, sectioning: .timeline(.day), calendar: calendar).change(from: old) == .structure)

        // An item moved to another day keeps the count but not the sections.
        var moved = sample
        moved[2] = media(3, date(2026, 11, 4))
        #expect(GridModel(items: moved, sectioning: .timeline(.day), calendar: calendar).change(from: old) == .structure)

        #expect(old.resectioned(.timeline(.month), calendar: calendar).change(from: old) == .structure)
    }

    /// SPEC §10: what one database change costs for a 100 000-item library — building the model (sections and index
    /// by id) and finding out what changed. Runs off the main actor in the app. Prints the times.
    @Test func modelPerformance100k() {
        var seed: UInt64 = 7
        func random() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(1 << 53)
        }
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        let items = (0..<100_000).map { index in
            media(FileID(index + 1), now.addingTimeInterval(-random() * 8 * 365 * 86400))
        }.sorted { $0.timestamp > $1.timestamp }
        let clock = ContinuousClock()
        var build = Duration.seconds(1000)
        var resection = Duration.seconds(1000)
        var diff = Duration.seconds(1000)
        var model = GridModel.empty
        for _ in 0..<3 {
            build = min(build, clock.measure { model = GridModel(items: items, sectioning: .timeline(.day), calendar: calendar) })
            resection = min(resection, clock.measure { _ = model.resectioned(.timeline(.month), calendar: calendar) })
        }
        var changed = items
        changed[50_000].isFavorite = true
        let next = GridModel(items: changed, sectioning: .timeline(.day), calendar: calendar)
        var change = GridModel.Change.none
        for _ in 0..<3 { diff = min(diff, clock.measure { change = next.change(from: model) }) }
        print("PERF GridModel 100k: build \(build), resection \(resection), change detection \(diff), sections \(model.sections.count)")
        #expect(change == .content([changed[50_000].fileId]))
        #expect(model.sections.count > 2900)
        #expect(build < .milliseconds(1500))
        #expect(resection < .milliseconds(250))
        #expect(diff < .milliseconds(1500))
    }
}
