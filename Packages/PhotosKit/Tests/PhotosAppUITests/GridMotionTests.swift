// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import PhotosDomain
import PhotosModel
import PhotosStore
import Testing

@testable import PhotosAppUI

/// The decisions behind the grid's glass and motion (SPEC §17.2).
@MainActor
@Suite struct GridMotionTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()
    let locale = Locale(identifier: "en_US")

    func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    func media(_ id: FileID, _ date: Date) -> GridMedia {
        GridMedia(
            MediaItem(
                fileId: id, path: "/Photos/\(id).jpg", mimeType: "image/jpeg", etag: "e\(id)", modifiedAt: date, capturedAt: date))
    }

    /// 24, 23 and 22 November (a trip to Lisbon from the 22nd to the 23rd), 3 November, 31 October.
    var model: GridModel {
        let items =
            [media(1, date(2026, 11, 24))] + (2...3).map { media($0, date(2026, 11, 23)) } + (4...5).map { media($0, date(2026, 11, 22)) }
            + [media(6, date(2026, 11, 3)), media(7, date(2026, 10, 31))]
        return GridModel(items: items, sectioning: .timeline(.day), calendar: calendar)
    }

    var lisbon: MomentHeaders {
        MomentHeaders(entries: [
            20_261_123: .init(momentId: "moment-20261122-20261123", title: "Weekend in Lisbon", oldestDay: 20_261_122, place: "Lisbon")
        ])
    }

    // MARK: Date pill

    @Test func thePillNamesTheMonthAndTheMomentOnEveryDayOfIt() {
        let sections = model.sections
        #expect(sections.map(\.id) == [20_261_124, 20_261_123, 20_261_122, 20_261_103, 20_261_031])
        let pill = { (index: Int) in GridDatePill.make(sections: sections, index: index, moments: lisbon, locale: locale) }
        #expect(pill(0)?.text == "November 2026")
        // The moment's newest day and the one below it.
        #expect(pill(1)?.text == "November 2026 · Lisbon")
        #expect(pill(2)?.text == "November 2026 · Lisbon")
        #expect(pill(2)?.accessibilityLabel == "November 2026, Lisbon")
        // Below the moment's oldest day: only the month.
        #expect(pill(3)?.text == "November 2026")
        #expect(pill(4)?.text == "October 2026")
        #expect(pill(5) == nil)
        // Without a place the title is the detail.
        let birthday = MomentHeaders(entries: [20_261_103: .init(momentId: "m", title: "Anna's birthday", oldestDay: 20_261_103)])
        #expect(GridDatePill.make(sections: sections, index: 3, moments: birthday, locale: locale)?.detail == "Anna's birthday")
        // An entry without its oldest day only covers its own day.
        let old = MomentHeaders(entries: [20_261_123: .init(momentId: "m", title: "Weekend in Lisbon")])
        #expect(GridDatePill.make(sections: sections, index: 2, moments: old, locale: locale)?.detail == nil)
    }

    @Test func thePillShowsTheYearOrNothingWhereThereAreNoDays() {
        let years = model.resectioned(.timeline(.year), calendar: calendar)
        #expect(GridDatePill.make(sections: years.sections, index: 0, moments: .none, locale: locale)?.text == "2026")
        let flat = GridModel(items: model.items, sectioning: .flat)
        #expect(GridDatePill.make(sections: flat.sections, index: 0, moments: .none, locale: locale) == nil)
    }

    @Test func theTextHandsOverInTheScrollingDirection() {
        #expect(GridDatePill.handover(from: nil, to: 3) == .none)
        #expect(GridDatePill.handover(from: 3, to: 3) == .none)
        #expect(GridDatePill.handover(from: 3, to: 4) == .older)
        #expect(GridDatePill.handover(from: 4, to: 1) == .newer)
    }

    @Test func momentTitlesKnowTheirPlace() {
        #expect(MomentTitle.dayIn(day: date(2026, 11, 22), place: "Lisbon").place == "Lisbon")
        #expect(MomentTitle.places("Lisbon", "Porto").place == "Lisbon & Porto")
        #expect(MomentTitle.with(people: ["Anna"], day: date(2026, 11, 22)).place == nil)
        #expect(MomentTitle.activity(.beach, place: nil, person: nil).place == nil)
    }

    // MARK: Arrival

    @Test func onlyPicturesThatArriveLaterAnimate() {
        // From memory while the tile is configured (scrolling): at once.
        #expect(GridTileArrival.transition(from: .nothing, isAsync: false, reduceMotion: false) == .instant)
        #expect(GridTileArrival.transition(from: .blur, isAsync: false, reduceMotion: false) == .instant)
        // Loaded: from the BlurHash with a settle, a sharper one over the picture with a fade only.
        #expect(GridTileArrival.transition(from: .blur, isAsync: true, reduceMotion: false) == .fadeAndSettle)
        #expect(GridTileArrival.transition(from: .nothing, isAsync: true, reduceMotion: false) == .fadeAndSettle)
        #expect(GridTileArrival.transition(from: .picture, isAsync: true, reduceMotion: false) == .fade)
        // Reduce Motion: no movement.
        #expect(GridTileArrival.transition(from: .blur, isAsync: true, reduceMotion: true) == .fade)
        let rect = GridTileArrival.settleContentsRect
        #expect(abs(rect.width - 1 / 1.04) < 0.0001)
        #expect(abs(rect.midX - 0.5) < 0.0001 && abs(rect.midY - 0.5) < 0.0001)
    }

    @Test func videoCapsulesShrinkWithTheTiles() {
        #expect(GridVideoPillLayout.layout(tileWidth: 130) == .duration)
        #expect(GridVideoPillLayout.layout(tileWidth: 64) == .duration)
        #expect(GridVideoPillLayout.layout(tileWidth: 40) == .icon)
        #expect(GridVideoPillLayout.layout(tileWidth: 28) == .hidden)
    }

    @Test func selectedCornersStayAHint() {
        #expect(GridSelectionLook.cornerRadius(tileSide: 20) == 3)
        #expect(GridSelectionLook.cornerRadius(tileSide: 78) == 5)
        #expect(GridSelectionLook.cornerRadius(tileSide: 400) == 10)
    }

    // MARK: Action feedback

    @Test func expectedRemovalsAnimateAndComeBackTheSameWayOnUndo() {
        var expectations = GridActionExpectations()
        // A sync removed something nobody asked for: no animation.
        #expect(expectations.style(gone: [9], back: [], now: 0) == nil)
        expectations.expectLeaving([1, 2], style: .collapse, now: 10)
        expectations.expectLeaving([3], style: .slide, now: 10)
        #expect(expectations.style(gone: [1, 2], back: [], now: 11) == .collapse)
        // The delete is undone a minute later: the tiles return the way they left.
        #expect(expectations.style(gone: [], back: [2], now: 70) == .collapse)
        // Returned once: a second return is not expected any more.
        #expect(expectations.style(gone: [], back: [2], now: 71) == nil)
        // Too late: the archive's change never came in time, and the delete is no longer undone.
        #expect(expectations.style(gone: [3], back: [], now: 30) == nil)
        #expect(expectations.style(gone: [], back: [1], now: 200) == nil)
        #expect(expectations.isEmpty)
    }

    @Test func itemChangesFindTheTilesThatLeaveAndCome() throws {
        let old = model
        // Photo 4 deleted (22 November keeps 5), photo 6 (all of 3 November) deleted, a new photo on 23 November.
        var items = old.items.filter { $0.fileId != 4 && $0.fileId != 6 }
        items.insert(media(8, date(2026, 11, 23).addingTimeInterval(3600)), at: 1)
        let new = GridModel(items: items, sectioning: .timeline(.day), calendar: calendar)
        guard case .sections(let changes) = new.change(from: old) else {
            Issue.record("expected section changes")
            return
        }
        let result = try #require(GridItemChanges.make(old: old, new: new, changes: changes))
        #expect(result.deletedSections == [3])
        #expect(result.insertedSections.isEmpty)
        #expect(Set(result.gone) == [4, 6])
        #expect(result.back == [8])
        #expect(result.deletedItems == [IndexPath(item: 0, section: 2)])
        #expect(result.insertedItems == [IndexPath(item: 0, section: 1)])
    }

    @Test func itemChangesGiveUpOnMovesAndLargeChanges() {
        let old = GridModel(items: (1...5).map { media($0, date(2026, 11, 22)) }, sectioning: .flat)
        // The same photos in another order: not a leave.
        let reordered = GridModel(items: [2, 1, 3, 4, 5].map { media($0, date(2026, 11, 22)) }, sectioning: .flat)
        let changes = GridModel.SectionChanges(reloaded: [0])
        #expect(GridItemChanges.make(old: old, new: reordered, changes: changes) == nil)
        // Removing two of five is fine, but not above the limit.
        let fewer = GridModel(items: [1, 3, 5].map { media($0, date(2026, 11, 22)) }, sectioning: .flat)
        #expect(GridItemChanges.make(old: old, new: fewer, changes: changes)?.deletedItems.map(\.item) == [1, 3])
        #expect(GridItemChanges.make(old: old, new: fewer, changes: changes, limit: 1) == nil)
    }

    /// A month's newest day is deleted: the next day now starts the month, and its header says so.
    @Test func aHeaderThatChangesIsNoted() throws {
        let old = model
        let new = GridModel(items: old.items.filter { $0.fileId != 1 }, sectioning: .timeline(.day), calendar: calendar)
        guard case .sections(let changes) = new.change(from: old) else {
            Issue.record("expected section changes")
            return
        }
        let result = try #require(GridItemChanges.make(old: old, new: new, changes: changes))
        #expect(result.deletedSections == [0])
        #expect(result.headerChanges == [0])
        #expect(result.gone == [1])
    }
}
