// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosDomain

/// Moments of the Library (SPEC §16.1): days grouped by stays away from home, titled from places, people and labels.
@Suite struct LibraryMomentsTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }()
    let locale = Locale(identifier: "en_US")

    /// `count` photos on a day (2026-`month`-`day`), an hour apart from 10:00.
    func photos(
        _ count: Int, month: Int = 11, day: Int, place: String? = nil, country: String? = "Germany", people: [String] = [],
        labels: Set<String> = [], startId: Int64
    ) -> [MomentItem] {
        (0..<count).map { offset in
            let date = calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 10 + offset % 12, minute: offset / 12))!
            return MomentItem(
                fileId: startId + Int64(offset), timestamp: date, place: place, country: place == nil ? nil : country, people: people,
                labels: labels)
        }
    }

    /// Home is Berlin: photographed there on many days.
    func homeDays(startId: Int64 = 10_000) -> [MomentItem] {
        (1...6).flatMap { day in photos(2, month: 10, day: day, place: "Berlin", startId: startId + Int64(day * 10)) }
    }

    func titles(_ moments: [LibraryMoment]) -> [String?] {
        moments.map { $0.title?.text(locale: locale, calendar: calendar) }
    }

    @Test func aDayAwayIsNamedAfterItsWeekdayAndPlace() {
        // 2026-11-22 is a Sunday.
        let items = homeDays() + photos(5, day: 22, place: "Lisbon", country: "Portugal", startId: 1)
        let moments = LibraryMoments.build(items, calendar: calendar)
        #expect(moments.first?.days == [20_261_122])
        #expect(moments.first?.title == .dayIn(day: moments.first!.end, place: "Lisbon"))
        #expect(titles(moments).first == "Sunday in Lisbon")
        #expect(moments.first?.facts.isAway == true)
    }

    @Test func daysAtHomeWithoutAnythingToSayHaveNoTitle() {
        let moments = LibraryMoments.build(homeDays(), calendar: calendar)
        #expect(moments.count == 6)
        #expect(moments.allSatisfy { $0.title == nil })
        #expect(LibraryMoments.headers(moments, locale: locale, calendar: calendar).entries.isEmpty)
    }

    @Test func consecutiveDaysAwayAtOnePlaceAreOneMoment() {
        // Saturday 21 and Sunday 22 November in Lisbon, then Monday at home.
        let trip =
            photos(4, day: 21, place: "Lisbon", country: "Portugal", startId: 1)
            + photos(4, day: 22, place: "Lisbon", country: "Portugal", startId: 100)
        let monday = photos(3, day: 23, place: "Berlin", startId: 200)
        let moments = LibraryMoments.build(homeDays() + trip + monday, calendar: calendar)
        #expect(moments[0].days == [20_261_123])
        #expect(moments[0].title == nil)
        #expect(moments[1].days == [20_261_122, 20_261_121])
        #expect(moments[1].count == 8)
        #expect(titles(moments)[1] == "Weekend in Lisbon")
        // Items oldest first, the header on the newest day.
        #expect(moments[1].items.first == 1)
        #expect(moments[1].headerDay == 20_261_122)
        #expect(moments[1].id == "moment-20261121-20261122")
    }

    @Test func aLongerStayCountsItsDaysAndTwoPlacesAreBothNamed() {
        let stay = (16...19).flatMap { photos(3, day: $0, place: "Lisbon", country: "Portugal", startId: Int64($0 * 100)) }
        let moments = LibraryMoments.build(homeDays() + stay, calendar: calendar)
        #expect(titles(moments).first == "4 days in Lisbon")
        // The catalog's plural variations (SPEC §20.3): never "1 days".
        #expect(MomentTitle.daysIn(days: 1, place: "Lisbon").text(locale: locale, calendar: calendar) == "1 day in Lisbon")

        let twoPlaces =
            photos(4, day: 16, place: "Lisbon", country: "Portugal", startId: 1)
            + photos(3, day: 17, place: "Porto", country: "Portugal", startId: 50)
        let both = LibraryMoments.build(homeDays() + twoPlaces, calendar: calendar)
        #expect(both.first?.days.count == 2)
        #expect(titles(both).first == "Lisbon & Porto")
    }

    @Test func nearbyPlacesWithoutACountryAreOneStay() {
        let lisbon = GeoPoint(latitude: 38.72, longitude: -9.14)
        let sintra = GeoPoint(latitude: 38.80, longitude: -9.38)
        var stay = photos(4, day: 6, place: "Lisbon", country: nil, startId: 1).map { item in
            var item = item
            item.country = nil
            item.location = lisbon
            return item
        }
        stay += photos(3, day: 7, place: "Sintra", startId: 50).map { item in
            var item = item
            item.country = nil
            item.location = sintra
            return item
        }
        let moments = LibraryMoments.build(homeDays() + stay, calendar: calendar)
        #expect(moments.first?.days == [20_261_107, 20_261_106])
        #expect(titles(moments).first == "Lisbon & Sintra")
        // Far apart (Lisbon and Porto, 270 km) without a country: two moments.
        stay = stay.map { item in
            var item = item
            if item.place == "Sintra" {
                item.place = "Porto"
                item.location = GeoPoint(latitude: 41.15, longitude: -8.61)
            }
            return item
        }
        #expect(LibraryMoments.build(homeDays() + stay, calendar: calendar).first?.days == [20_261_107])
    }

    @Test func aDayWithoutPlacesInTheMiddleOfAStayBelongsToIt() {
        let stay =
            photos(3, day: 16, place: "Lisbon", country: "Portugal", startId: 1) + photos(3, day: 17, place: nil, startId: 50)
            + photos(3, day: 18, place: "Lisbon", country: "Portugal", startId: 100)
        let moments = LibraryMoments.build(homeDays() + stay, calendar: calendar)
        #expect(moments.first?.days == [20_261_118, 20_261_117, 20_261_116])
        // At the end of a stay it does not: that may be the day back home.
        let ending = photos(3, day: 16, place: "Lisbon", country: "Portugal", startId: 1) + photos(3, day: 17, place: nil, startId: 50)
        let split = LibraryMoments.build(homeDays() + ending, calendar: calendar)
        #expect(split[0].days == [20_261_117])
        #expect(split[1].days == [20_261_116])
    }

    @Test func aGapBetweenStaysSplitsThem() {
        let first = photos(3, day: 10, place: "Lisbon", country: "Portugal", startId: 1)
        let second = photos(3, day: 14, place: "Lisbon", country: "Portugal", startId: 50)
        let moments = LibraryMoments.build(homeDays() + first + second, calendar: calendar)
        #expect(moments[0].days == [20_261_114])
        #expect(moments[1].days == [20_261_110])
    }

    @Test func activitiesWinOverPlaces() {
        let hike = photos(5, day: 22, place: "Zermatt", country: "Switzerland", labels: ["hiking", "mountain"], startId: 1)
        #expect(titles(LibraryMoments.build(homeDays() + hike, calendar: calendar)).first == "Hike near Zermatt")
        // At home the place is not named.
        let beach = photos(4, day: 22, place: "Berlin", labels: ["beach"], startId: 1)
        #expect(titles(LibraryMoments.build(homeDays() + beach, calendar: calendar)).first == "Beach day")
    }

    @Test func aBirthdayIsNamedAfterThePersonSeenMost() {
        let party =
            photos(4, day: 22, place: "Berlin", people: ["Anna"], startId: 1)
            + photos(2, day: 22, place: "Berlin", people: ["Ben"], labels: ["birthday", "cake"], startId: 50)
        let moments = LibraryMoments.build(homeDays() + party, calendar: calendar)
        #expect(titles(moments).first == "Anna’s birthday")
        // Without named people it is just a birthday.
        let anonymous = photos(3, day: 22, place: "Berlin", labels: ["birthday"], startId: 1)
        #expect(titles(LibraryMoments.build(homeDays() + anonymous, calendar: calendar)).first == "Birthday")
    }

    @Test func christmasOnlyInDecemberAndJanuary() {
        let july = photos(3, month: 7, day: 12, place: "Berlin", labels: ["christmas"], startId: 1)
        #expect(LibraryMoments.build(homeDays() + july, calendar: calendar).first?.title == nil)
        let december = photos(3, month: 12, day: 24, place: "Berlin", labels: ["christmas"], startId: 1)
        #expect(titles(LibraryMoments.build(homeDays() + december, calendar: calendar)).first == "Christmas")
    }

    @Test func aDayWithNamedPeopleAtHome() {
        let day = photos(4, day: 22, place: "Berlin", people: ["Anna", "Ben"], startId: 1)
        #expect(titles(LibraryMoments.build(homeDays() + day, calendar: calendar)).first == "Sunday with Anna and Ben")
        // Someone in one photo of many does not name the moment.
        let crowd = photos(10, day: 22, place: "Berlin", startId: 1) + photos(1, day: 22, place: "Berlin", people: ["Cleo"], startId: 50)
        #expect(LibraryMoments.build(homeDays() + crowd, calendar: calendar).first?.title == nil)
    }

    @Test func tooFewPhotosGetNoTitle() {
        let snapshot = photos(2, day: 22, place: "Lisbon", country: "Portugal", startId: 1)
        #expect(LibraryMoments.build(homeDays() + snapshot, calendar: calendar).first?.title == nil)
    }

    @Test func theCoverIsAFavouriteElseTheMiddle() {
        var day = photos(5, day: 22, place: "Lisbon", country: "Portugal", startId: 1)
        let moment = LibraryMoments.build(day, home: "Berlin", calendar: calendar)[0]
        #expect(moment.cover == 3)
        day[4].isFavorite = true
        #expect(LibraryMoments.build(day, home: "Berlin", calendar: calendar)[0].cover == 5)
    }

    @Test func headersAreOnTheNewestDayAndTakeNicerTitles() {
        let trip =
            photos(4, day: 21, place: "Lisbon", country: "Portugal", startId: 1)
            + photos(4, day: 22, place: "Lisbon", country: "Portugal", startId: 100)
        let moments = LibraryMoments.build(homeDays() + trip, calendar: calendar)
        let headers = LibraryMoments.headers(moments, locale: locale, calendar: calendar)
        #expect(headers[20_261_122]?.title == "Weekend in Lisbon")
        #expect(headers[20_261_121] == nil)
        let nicer = headers.replacingTitles(["moment-20261121-20261122": "Pastéis in Lisbon"])
        #expect(nicer[20_261_122]?.title == "Pastéis in Lisbon")
        #expect(nicer[20_261_122]?.momentId == "moment-20261121-20261122")
    }

    @Test func factsKeyChangesWithWhatTheTitleIsMadeOf() {
        let day = photos(4, day: 22, place: "Lisbon", country: "Portugal", startId: 1)
        let before = LibraryMoments.build(day, home: "Berlin", calendar: calendar)[0].facts.key
        let more = day + photos(1, day: 22, place: "Lisbon", country: "Portugal", startId: 9)
        #expect(LibraryMoments.build(more, home: "Berlin", calendar: calendar)[0].facts.key == before)
        let withAnna = photos(4, day: 22, place: "Lisbon", country: "Portugal", people: ["Anna"], startId: 1)
        #expect(LibraryMoments.build(withAnna, home: "Berlin", calendar: calendar)[0].facts.key != before)
    }

    @Test func dayKeysMatchTheTimelineSections() {
        // Late evening and early morning in Berlin's time zone: the same split as the grid's day sections.
        let late = calendar.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 23, minute: 50))!
        let early = calendar.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 0, minute: 10))!
        let items = [MomentItem(fileId: 2, timestamp: early), MomentItem(fileId: 1, timestamp: late)]
        let moments = LibraryMoments.build(items, calendar: calendar)
        let sections = TimelineSections.group(timestamps: items.map(\.timestamp), calendar: calendar).flatMap(\.days).map(\.id)
        #expect(moments.flatMap(\.days) == sections)
    }

    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["PHOTOS_SKIP_PERFORMANCE"] == nil, "PHOTOS_SKIP_PERFORMANCE is set"))
    func aHundredThousandItemsAreQuick() {
        // Ten years, about 27 photos a day, trips every few weeks.
        let start = calendar.date(from: DateComponents(year: 2016, month: 1, day: 1))!
        var items: [MomentItem] = []
        items.reserveCapacity(100_000)
        for index in 0..<100_000 {
            let date = start.addingTimeInterval(Double(index) * 3_150)
            let day = index / 27
            let away = (day / 3) % 9 == 0
            items.append(
                MomentItem(
                    fileId: Int64(index), timestamp: date, place: away ? "Place \(day / 27)" : "Home", country: away ? "Elsewhere" : "Here",
                    people: index % 7 == 0 ? ["Anna"] : [], labels: index % 50 == 0 ? ["beach"] : []))
        }
        items.reverse()
        let clock = ContinuousClock()
        var moments: [LibraryMoment] = []
        let elapsed = clock.measure { moments = LibraryMoments.build(items, calendar: calendar) }
        print("PERF moments of 100 000 items: \(elapsed)")
        #expect(moments.reduce(0) { $0 + $1.count } == 100_000)
        #expect(elapsed < .seconds(3))
    }
}
