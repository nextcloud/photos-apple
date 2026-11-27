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

        func change(_ items: [GridMedia]) -> GridModel.Change {
            GridModel(items: items, sectioning: .timeline(.day), calendar: calendar).change(from: old)
        }
        // An upload of today: a new section at the top, and yesterday's header no longer starts the month.
        let added = [media(9, date(2026, 11, 23))] + sample
        #expect(change(added) == .sections(.init(inserted: [0], reloaded: [0])))
        // Into an existing day: only that section.
        let sameDay = [media(9, date(2026, 11, 22, 23))] + sample
        #expect(change(sameDay) == .sections(.init(reloaded: [0])))
        // The last day emptied.
        #expect(change(Array(sample.dropLast())) == .sections(.init(deleted: [3])))

        // Same count, another item in the place of one.
        var replaced = sample
        replaced[4] = media(6, date(2025, 1, 1))
        #expect(change(replaced) == .sections(.init(reloaded: [3])))

        // An item moved to another day: its old day goes, the new day comes; with a favourite elsewhere at the same time.
        var moved = sample
        moved[2] = media(3, date(2026, 11, 4))
        moved[0] = media(1, date(2026, 11, 22, 23), favorite: true)
        #expect(change(moved) == .sections(.init(deleted: [1], inserted: [1], content: [1])))

        #expect(old.resectioned(.timeline(.month), calendar: calendar).change(from: old) == .structure)
        let flat = GridModel(items: sample, sectioning: .flat)
        #expect(flat.change(from: GridModel(items: Array(sample.dropLast()), sectioning: .flat)) == .sections(.init(reloaded: [0])))
        #expect(GridModel(items: sample, sectioning: .flat).change(from: .empty) == .structure)
    }

    /// The first sync's skeleton (`TimelineSkeleton`): the loaded sections, the rest of the oldest loaded month as
    /// placeholder tiles, a section of placeholders for every older month, and a year index over all of it.
    @Test func theSkeletonCompletesTheTimelineDuringTheFirstSync() {
        // The server counts 3 in November 2026, 4 in October, 6 in March 2024 and 2 in July 2019.
        let skeleton = TimelineSkeleton(months: [202611: 3, 202610: 4, 202403: 6, 201907: 2])
        // The first page: November and one photo of October.
        let loaded = Array(sample.prefix(4))
        let days = GridModel(items: loaded, sectioning: .timeline(.day), skeleton: skeleton, calendar: calendar)
        #expect(days.sections.map(\.id) == [20261122, 20261103, 20261031, 20240300, 20190700])
        #expect(days.sections.map(\.kind) == [.day, .day, .day, .month, .month])
        #expect(days.sections.map(\.placeholders) == [0, 0, 3, 6, 2])
        #expect(days.sections.map(\.tileCount) == [2, 1, 4, 6, 2])
        #expect(days.sections[3].range == 4..<4)
        #expect(days.numberOfItems(inSection: 2) == 4)
        // Placeholder tiles have no item.
        #expect(days.item(section: 2, item: 0)?.fileId == 4)
        #expect(days.item(section: 2, item: 1) == nil)
        #expect(days.item(section: 3, item: 0) == nil)
        #expect(days.fileIdsArePositioned(loaded))
        #expect(days.yearStarts.map(\.year) == [2026, 2024, 2019])
        #expect(days.hasTiles)
        #expect(GridModel.idsDescend(days.sections))

        let years = days.resectioned(.timeline(.year), calendar: calendar)
        #expect(years.sections.map(\.id) == [2026, 2024, 2019])
        #expect(years.sections.map(\.placeholders) == [3, 6, 2])

        // Before the first page: only placeholders.
        let empty = GridModel(items: [], sectioning: .timeline(.month), skeleton: skeleton, calendar: calendar)
        #expect(empty.isEmpty)
        #expect(empty.hasTiles)
        #expect(empty.sections.map(\.id) == [202611, 202610, 202403, 201907])
        #expect(empty.sections.map(\.tileCount) == [3, 4, 6, 2])
        #expect(empty.position(ofIndex: 0) == nil)

        // More pages: the placeholders move back; the skeleton gone (the sync is through): just the items.
        let more = GridModel(items: sample, sectioning: .timeline(.day), skeleton: skeleton, calendar: calendar)
        #expect(more.sections.map(\.placeholders) == [0, 0, 0, 0, 6, 2])
        #expect(more.sections.map(\.id) == [20261122, 20261103, 20261031, 20250101, 20240300, 20190700])
        let done = more.resectioned(.timeline(.day), skeleton: nil, calendar: calendar)
        #expect(done.sections.map(\.placeholders) == [0, 0, 0, 0])
        #expect(GridModel(items: sample, sectioning: .flat, skeleton: skeleton).sections.map(\.placeholders) == [0])
    }

    /// A page of the first sync changes only the tail of the grid: a batch update, not a reload.
    @Test func aSyncPageUnderTheSkeletonIsABatchUpdate() {
        let skeleton = TimelineSkeleton(months: [202611: 3, 202610: 4, 202501: 1, 202403: 6])
        let first = GridModel(items: Array(sample.prefix(3)), sectioning: .timeline(.day), skeleton: skeleton, calendar: calendar)
        #expect(first.sections.map(\.id) == [20261122, 20261103, 20261000, 20250100, 20240300])
        let second = GridModel(items: sample, sectioning: .timeline(.day), skeleton: skeleton, calendar: calendar)
        #expect(second.sections.map(\.id) == [20261122, 20261103, 20261031, 20250101, 20240300])
        guard case .sections(let changes) = second.change(from: first) else {
            Issue.record("a sync page reloads the grid")
            return
        }
        #expect(changes.deleted == [2, 3])
        #expect(changes.inserted == [2, 3])
        #expect(changes.reloaded.isEmpty)
        // Only the placeholder count of a section changed: that section is reloaded.
        let fewer = GridModel(
            items: sample, sectioning: .timeline(.day), skeleton: TimelineSkeleton(months: [202403: 5]), calendar: calendar)
        #expect(fewer.change(from: second) == .sections(.init(reloaded: [4])))
    }

    /// A sync that changes much of the library reloads instead of batching hundreds of sections.
    @Test func manyChangedSectionsReload() {
        let days = (0..<400).map { media(FileID($0 + 1), date(2026, 1, 1).addingTimeInterval(-Double($0) * 86_400)) }
        let old = GridModel(items: days, sectioning: .timeline(.day), calendar: calendar)
        let everyOther = days.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        let thinned = GridModel(items: everyOther, sectioning: .timeline(.day), calendar: calendar)
        #expect(thinned.change(from: old) == .structure)
        let one = GridModel(items: Array(days.dropFirst()), sectioning: .timeline(.day), calendar: calendar)
        #expect(one.change(from: old) == .sections(.init(deleted: [0])))
    }

    /// SPEC §10: what one database change costs for a 100 000-item library — building the model (sections and index
    /// by id) and finding out what changed. Runs off the main actor in the app. Prints the times.
    @Test(
        .tags(.performance),
        .enabled(if: ProcessInfo.processInfo.environment["PHOTOS_SKIP_PERFORMANCE"] == nil, "PHOTOS_SKIP_PERFORMANCE is set"))
    func modelPerformance100k() {
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
        // An upload: one new photo of today.
        let uploaded = GridModel(items: [media(200_000, now)] + items, sectioning: .timeline(.day), calendar: calendar)
        var uploadChange = GridModel.Change.none
        var uploadDiff = Duration.seconds(1000)
        for _ in 0..<3 { uploadDiff = min(uploadDiff, clock.measure { uploadChange = uploaded.change(from: model) }) }
        print(
            "PERF GridModel 100k: build \(build), resection \(resection), change detection \(diff), upload diff \(uploadDiff), sections \(model.sections.count)"
        )
        #expect(change == .content([changed[50_000].fileId]))
        if case .sections(let sections) = uploadChange {
            #expect(sections.sectionCount <= 2)
        } else {
            Issue.record("an upload reloads the grid: \(uploadChange)")
        }
        #expect(model.sections.count > 2900)
        #expect(build < timingBudget(.milliseconds(1500)))
        #expect(resection < timingBudget(.milliseconds(250)))
        #expect(diff < timingBudget(.milliseconds(1500)))

        // The first sync's skeleton on top: only months are added, the budget is the same.
        var months: [Int: Int] = [:]
        for year in 1990...2026 { for month in 1...12 { months[year * 100 + month] = 300 } }
        let skeleton = TimelineSkeleton(months: months)
        let firstPage = Array(items.prefix(1000))
        var skeletonBuild = Duration.seconds(1000)
        var withSkeleton = GridModel.empty
        for _ in 0..<3 {
            skeletonBuild = min(
                skeletonBuild,
                clock.measure {
                    withSkeleton = GridModel(items: firstPage, sectioning: .timeline(.day), skeleton: skeleton, calendar: calendar)
                })
        }
        print("PERF GridModel skeleton: first page with \(months.count) months \(skeletonBuild), sections \(withSkeleton.sections.count)")
        #expect(skeletonBuild < timingBudget(.milliseconds(100)))
        #expect(withSkeleton.sections.reduce(0) { $0 + $1.tileCount } >= 300 * (months.count - 120))
    }
}

extension GridModel {
    /// Every item is found where the flat list has it (placeholders do not shift positions).
    fileprivate func fileIdsArePositioned(_ items: [GridMedia]) -> Bool {
        items.enumerated().allSatisfy { index, item in
            position(of: item.fileId).flatMap { flatIndex(section: $0.section, item: $0.item) } == index
        }
    }
}
