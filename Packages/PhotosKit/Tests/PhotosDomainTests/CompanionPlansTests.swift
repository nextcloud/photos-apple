// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel
import Testing

@testable import PhotosDomain

/// Apple TV shelves and links, the family slideshow and the watch's photos (SPEC §15.3).
@Suite struct CompanionPlansTests {
    func memory(_ id: String, _ kind: Memory.Kind, start: TimeInterval = 0) -> Memory {
        Memory(
            id: id, kind: kind, title: id, start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: start), cover: 1,
            items: [1])
    }

    @Test func memoriesShelfShowsThisDayFirstThenRecapThenNewestTrips() {
        let ordered = TVShelves.memories(
            onThisDay: [memory("years-5", .yearsAgo(5)), memory("years-1", .yearsAgo(1))], recap: memory("recap-2025", .yearRecap(2025)),
            trips: [memory("trip-old", .trip, start: 10), memory("trip-new", .trip, start: 20)])
        #expect(ordered.map(\.id) == ["years-1", "years-5", "recap-2025", "trip-new", "trip-old"])
        #expect(TVShelves.memories(onThisDay: [], recap: nil, trips: []).isEmpty)
    }

    @Test func tvLinksRoundTrip() throws {
        let routes: [TVRoute] = [
            .memory(id: "years-2", play: false), .memory(id: "trip-1700000000", play: true), .album(id: "own:Summer 2025", play: false),
            .album(id: "shared:Family (anna)", play: true), .familySlideshow,
        ]
        for route in routes {
            #expect(TVRoute(url: route.url) == route, "\(route.url)")
        }
        #expect(
            TVRoute(url: try #require(URL(string: "nextcloudphotos://memories/years-2/play")))?.url.absoluteString
                == "nextcloudphotos://memories/years-2/play")
    }

    @Test func otherLinksAreNotTVRoutes() throws {
        for link in [
            "nextcloudphotos://memories", "nextcloudphotos://memories/a/b/c", "nextcloudphotos://memories/a/stop", "https://memories/a",
            "nextcloudphotos://photo/12", "nextcloudphotos://slideshow/x",
        ] {
            #expect(TVRoute(url: try #require(URL(string: link))) == nil, "\(link)")
        }
    }

    @Test func familySlideshowShowsEveryPhotoOncePerRoundInAStableOrder() {
        let ids = Array(1...30).map(Int64.init)
        let first = FamilySlideshow.round(ids, seed: 7, round: 0)
        #expect(Set(first) == Set(ids) && first.count == ids.count)
        #expect(first != ids.sorted(), "shuffled")
        #expect(FamilySlideshow.round(ids, seed: 7, round: 0) == first, "the same seed gives the same order")
        #expect(FamilySlideshow.round(ids, seed: 8, round: 0) != first)
        #expect(FamilySlideshow.round(ids.reversed(), seed: 7, round: 0) == first, "the order of the album does not matter")
        for round in 1..<50 {
            let previous = FamilySlideshow.round(ids, seed: 7, round: round - 1)
            let next = FamilySlideshow.round(ids, seed: 7, round: round)
            #expect(Set(next) == Set(ids))
            #expect(previous.last != next.first, "no photo twice in a row across rounds")
        }
        #expect(FamilySlideshow.photo(ids, seed: 7, position: 31) == FamilySlideshow.round(ids, seed: 7, round: 1)[1])
    }

    @Test func familySlideshowOfFewPhotos() {
        #expect(FamilySlideshow.photo([Int64](), seed: 1, position: 0) == nil)
        #expect(FamilySlideshow.photo([5], seed: 1, position: 3) == 5)
        let two = (0..<6).compactMap { FamilySlideshow.photo([Int64(9), 4], seed: 3, position: $0) }
        #expect(two == [4, 9, 4, 9, 4, 9], "two photos take turns")
        #expect(FamilySlideshow.photo([1, 2, 3], seed: 1, position: -1) == nil)
    }

    func item(_ id: FileID, day: Int, favorite: Bool = false, video: Bool = false) -> MediaItem {
        MediaItem(
            fileId: id, path: "/p/\(id).\(video ? "mov" : "jpg")", mimeType: video ? "video/quicktime" : "image/jpeg", etag: "e\(id)",
            capturedAt: Date(timeIntervalSince1970: TimeInterval(day) * 86_400), isFavorite: favorite)
    }

    @Test func watchGetsThisDaysPhotosAndOtherFavourites() {
        let day = Date(timeIntervalSince1970: 20_000 * 86_400)
        let today = [item(1, day: 100), item(2, day: 500, favorite: true), item(3, day: 300, video: true)]
        let favorites = [item(2, day: 500, favorite: true), item(9, day: 900, favorite: true)]
        let selection = WatchDigestPlan.select(onThisDay: today, favorites: favorites, day: day)
        #expect(selection.onThisDay.map(\.fileId) == [2, 1], "photos only, newest first")
        #expect(selection.favorites.map(\.fileId) == [9], "not the same photo twice")
        #expect(selection.photoOfTheDay?.fileId == 2, "a favourite of this day wins")
    }

    @Test func withoutThisDayTheNewestMemoryFillsIn() {
        let day = Date(timeIntervalSince1970: 20_000 * 86_400)
        let selection = WatchDigestPlan.select(
            onThisDay: [], fallbackMemory: [item(5, day: 10), item(6, day: 11)], favorites: [item(9, day: 1, favorite: true)], day: day)
        #expect(selection.onThisDay.map(\.fileId) == [6, 5])
        #expect(selection.photoOfTheDay.map { [5, 6].contains($0.fileId) } == true)
        let nothing = WatchDigestPlan.select(onThisDay: [], favorites: [], day: day)
        #expect(nothing.photoOfTheDay == nil && nothing.onThisDay.isEmpty)
    }

    @Test func manyPhotosAreSpreadOverAllYearsAndThePhotoOfTheDayStaysAllDay() throws {
        let many = (1...100).map { item(FileID($0), day: $0 * 365) }
        let selection = WatchDigestPlan.select(onThisDay: many, favorites: [], day: Date(timeIntervalSince1970: 0))
        #expect(selection.onThisDay.count == WatchDigestPlan.onThisDayLimit)
        #expect(selection.onThisDay.first?.fileId == 100 && selection.onThisDay.last.map { $0.fileId < 20 } == true)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let morning = Date(timeIntervalSince1970: 20_000 * 86_400 + 3600)
        let evening = morning.addingTimeInterval(20 * 3600)
        let tomorrow = morning.addingTimeInterval(86_400)
        let pool = Array(many.prefix(10))
        let pick = { (date: Date) in WatchDigestPlan.photoOfTheDay(today: pool, favorites: [], day: date, calendar: calendar)?.fileId }
        #expect(pick(morning) == pick(evening))
        #expect(pick(morning) != pick(tomorrow))
    }
}
