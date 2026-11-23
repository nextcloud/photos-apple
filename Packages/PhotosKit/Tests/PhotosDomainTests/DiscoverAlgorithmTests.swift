// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosDomain
@testable import PhotosModel

let utcCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ s: Int = 0) -> Date {
    utcCalendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, second: s))!
}

func photo(
    _ id: FileID, _ date: Date, place: String? = nil, favorite: Bool = false, name: String? = nil, size: Int64 = 100, dims: Int? = 10
)
    -> MediaItem
{
    MediaItem(
        fileId: id, path: "/Photos/\(name ?? "p\(id).jpg")", mimeType: "image/jpeg", size: size, modifiedAt: date, capturedAt: date,
        width: dims,
        height: dims, place: place, isFavorite: favorite)
}

@Suite struct MemoriesTests {
    @Test func onThisDayGroupsByYearsAgo() {
        let now = day(2026, 11, 22)
        let items = [
            photo(1, day(2025, 11, 21)), photo(2, day(2025, 11, 25), favorite: true), photo(3, day(2020, 11, 19)),
            photo(4, day(2025, 11, 30)),
        ]
        let memories = Memories.onThisDay(items, now: now, calendar: utcCalendar)
        #expect(memories.map(\.kind) == [.yearsAgo(1), .yearsAgo(6)])
        #expect(memories[0].items == [1, 2])
        #expect(memories[0].cover == 2)  // favourite
    }

    @Test func tripsNeedEightPhotosWithoutTwoDayGaps() {
        var items: [MediaItem] = []
        for i in 0..<8 { items.append(photo(FileID(i), day(2026, 6, 1 + i / 4, 10 + i), place: i < 5 ? "Lisbon" : "Porto")) }
        items.append(photo(100, day(2026, 6, 10)))  // gap > 2 days: own cluster, too small
        let trips = Memories.trips(items)
        #expect(trips.count == 1)
        #expect(trips[0].title == "Lisbon & Porto")
        #expect(trips[0].items.count == 8)
    }

    /// The catalog's plural variations reach the code (string catalog of the module, `bundle: .module`).
    @Test func yearsAgoTitlesUsePluralForms() {
        #expect(Memories.yearsAgoTitle(1) == "1 year ago")
        #expect(Memories.yearsAgoTitle(3) == "3 years ago")
        let memories = Memories.onThisDay([photo(1, day(2025, 11, 21))], now: day(2026, 11, 22), calendar: utcCalendar)
        #expect(memories.map(\.title) == ["1 year ago"])
    }

    /// A trip without places is titled by its dates; the card must not show the same date again below the title
    /// ("22. Nov 2026, 22. Nov 2026").
    @Test func dateLineIsLeftOutWhenTheTitleIsTheDate() {
        let locale = Locale(identifier: "de_DE")
        let undated = (0..<8).map { photo(FileID($0), day(2026, 11, 22, 8 + $0)) }
        let trip = Memories.trips(undated, locale: locale)[0]
        #expect(trip.title == DateRangeLabel.string(from: trip.start, to: trip.end, locale: locale))
        #expect(Memories.dateLine(for: trip, locale: locale) == nil)

        let placed = (0..<8).map { photo(FileID($0), day(2026, 11, 22, 8 + $0), place: "Lisbon") }
        let named = Memories.trips(placed, locale: locale)[0]
        #expect(named.title == "Lisbon")
        #expect(Memories.dateLine(for: named, locale: locale) == DateRangeLabel.string(from: named.start, to: named.end, locale: locale))
    }

    @Test func recapPicksNewestYearWithThirtyPhotos() {
        var items: [MediaItem] = []
        for i in 0..<40 { items.append(photo(FileID(i), day(2025, 1 + i % 12, 1 + i % 28), favorite: i == 5)) }
        for i in 0..<10 { items.append(photo(FileID(100 + i), day(2026, 1, 1 + i))) }
        let recap = Memories.yearRecap(items, calendar: utcCalendar)
        #expect(recap?.kind == .yearRecap(2025))
        #expect(recap?.items.contains(5) == true)
        #expect((recap?.items.count ?? 0) <= Memories.recapHighlights)
    }
}

@Suite struct StacksTests {
    func input(_ id: FileID, _ name: String, _ date: Date, mime: String = "image/jpeg", video: Bool = false, dir: String = "/Photos")
        -> StackInput
    {
        StackInput(fileId: id, name: name, directory: dir, timestamp: date, mimeType: mime, isVideo: video)
    }

    @Test func shotNames() {
        #expect(Stacks.shotName("IMG_E1234.HEIC") == "img_1234")
        #expect(Stacks.shotName("Beach (edited).jpg") == "beach")
        #expect(Stacks.shotName("beach-bearbeitet~2.jpg") == "beach")
        #expect(Stacks.shotName("Strand.JPG") == "strand")
    }

    @Test func variantsAndBursts() {
        let t = day(2026, 7, 1)
        let items = [
            input(1, "IMG_1000.DNG", t, mime: "image/x-dcraw"), input(2, "IMG_1000.JPG", t),  // RAW + JPEG
            input(3, "IMG_1001.HEIC", t.addingTimeInterval(-10), mime: "image/heic"),
            input(4, "IMG_1002.HEIC", t.addingTimeInterval(-12), mime: "image/heic"),  // burst with 3
            input(5, "IMG_1003.HEIC", t.addingTimeInterval(-60), mime: "image/heic"),  // alone
            input(6, "IMG_1000.JPG", t, dir: "/Other"),  // other folder: not a variant
        ]
        let stacks = Stacks.stacks(items)
        let variant = stacks.first { Set($0.members) == [1, 2] }
        #expect(variant?.leader == 2)  // JPEG preferred over RAW
        #expect(stacks.contains { Set($0.members) == [3, 4] })
        #expect(!stacks.contains { $0.members.contains(5) })
    }

    @Test func duplicatesBySizeTimeAndDimensions() {
        let t = day(2026, 1, 1)
        let items = [photo(1, t, name: "a.jpg"), photo(2, t, name: "copy/a.jpg"), photo(3, t, size: 101), photo(4, t, dims: nil)]
        let groups = Duplicates.groups(items)
        #expect(groups.count == 1)
        #expect(Set(groups[0].items) == [1, 2])
        #expect(groups[0].wastedBytes == 100)
    }
}

@Suite struct SearchSuggestionTests {
    let english = Locale(identifier: "en_US")

    @Test func groupsPrefixFirst() {
        let vocabulary = SearchSuggestions.Vocabulary(places: ["Paris", "Lisbon", "São Paulo"], people: ["Anna"], tags: [(1, "beach")])
        let result = SearchSuggestions.suggestions(
            for: "pa", vocabulary: vocabulary, now: day(2026, 11, 22), calendar: utcCalendar, locale: english)
        #expect(result.prefix(2).map(\.label) == ["Paris", "São Paulo"])
        #expect(result.last == .text("pa"))
        #expect(
            SearchSuggestions.suggestions(
                for: "sao", vocabulary: vocabulary, now: day(2026, 11, 22), calendar: utcCalendar, locale: english
            ).first == .place("São Paulo"))
    }

    @Test func dates() {
        let now = day(2026, 3, 15)
        let year = SearchSuggestions.dateFilters("2023", now: now, calendar: utcCalendar, locale: english)
        #expect(year.count == 1)
        let june = SearchSuggestions.dateFilters("june", now: now, calendar: utcCalendar, locale: english)
        // June hasn't started in 2026 yet: 2025, 2024, 2023.
        #expect(june.map(\.label) == ["June 2025", "June 2024", "June 2023"])
        #expect(SearchSuggestions.dateFilters("jun 2021", now: now, calendar: utcCalendar, locale: english).map(\.label) == ["June 2021"])
    }
}
