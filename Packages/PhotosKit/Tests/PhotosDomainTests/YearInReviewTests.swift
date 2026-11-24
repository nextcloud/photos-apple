// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosDomain
@testable import PhotosModel

/// The year in review, the travel numbers it shares with the places features, and the beat detection of memory films
/// (SPEC §15.1).
@Suite struct YearInReviewTests {
    let lisbon = GeoPoint(latitude: 38.7223, longitude: -9.1393)
    let porto = GeoPoint(latitude: 41.1579, longitude: -8.6291)
    let madrid = GeoPoint(latitude: 40.4168, longitude: -3.7038)

    func item(
        _ id: FileID, _ date: Date, video: Bool = false, favorite: Bool = false, at location: GeoPoint? = nil, place: String? = nil,
        country: String? = nil, people: [String] = [], labels: Set<String> = []
    ) -> YearReviewItem {
        YearReviewItem(
            fileId: id, date: date, isVideo: video, isFavorite: favorite, location: location, place: place, country: country,
            people: people, labels: labels)
    }

    // MARK: Travel

    @Test func distancesAreGreatCircleKilometres() {
        #expect(abs(TravelRoute.distance(lisbon, porto) - 274) < 3)
        #expect(abs(TravelRoute.distance(lisbon, madrid) - 503) < 5)
        #expect(TravelRoute.distance(lisbon, lisbon) == 0)
        #expect(GeoPoint(latitude: 0.0 as Double?, longitude: 0.0 as Double?) == nil)
        #expect(GeoPoint(latitude: 91.0 as Double?, longitude: 0.5 as Double?) == nil)
        #expect(GeoPoint(latitude: nil, longitude: 3) == nil)
    }

    @Test func stopsFollowTheOrderOfTheDaysAndIgnoreAOnePhotoDetour() {
        let points = [
            TravelRoute.Point(location: lisbon, date: day(2025, 5, 1), name: "Lisbon"),
            TravelRoute.Point(location: lisbon, date: day(2025, 5, 2), name: "Lisbon"),
            // A wrong fix between two Lisbon photos.
            TravelRoute.Point(location: madrid, date: day(2025, 5, 2, 13)),
            TravelRoute.Point(location: lisbon, date: day(2025, 5, 2, 14), name: "Belém"),
            TravelRoute.Point(location: porto, date: day(2025, 5, 4), name: "Porto"),
            TravelRoute.Point(location: lisbon, date: day(2025, 5, 6), name: "Lisbon"),
        ]
        let stops = TravelRoute.stops(points.shuffled())
        #expect(stops.map(\.name) == ["Lisbon", "Porto", "Lisbon"], "\(stops.map { ($0.name, $0.members) })")
        #expect(stops[0].members.count == 3)
        #expect(abs(TravelRoute.kilometres(stops) - 2 * TravelRoute.distance(lisbon, porto)) < 1)
    }

    @Test func travelStatsCountPlacesAndCountriesMostPhotographedFirst() {
        let stats = TravelStats([
            .init(location: lisbon, date: day(2025, 5, 1), place: "Lisbon", country: "Portugal"),
            .init(location: lisbon, date: day(2025, 5, 1, 13), place: "Lisbon", country: "Portugal"),
            .init(location: madrid, date: day(2025, 6, 1), place: "Madrid", country: "Spain"),
            .init(location: nil, date: day(2025, 7, 1), place: " ", country: nil),
        ])
        #expect(stats.places == ["Lisbon", "Madrid"])
        #expect(stats.countries == ["Portugal", "Spain"])
        #expect(abs(stats.kilometres - TravelRoute.distance(lisbon, madrid)) < 1)
    }

    // MARK: Year in review

    @Test func theNumbersOfAYear() {
        var items: [YearReviewItem] = []
        // 12 photos on 14 July, one each on 1–5 March (a five-day streak), a video, favourites, and last year's photo.
        for hour in 0..<12 { items.append(item(FileID(100 + hour), day(2025, 7, 14, 8, hour), favorite: hour == 3)) }
        for date in 1...5 { items.append(item(FileID(200 + date), day(2025, 3, date))) }
        items.append(item(300, day(2025, 3, 9), video: true))
        items.append(item(400, day(2024, 12, 31)))
        let review = YearInReview(year: 2025, items: items, calendar: utcCalendar)
        #expect(review.photos == 17)
        #expect(review.videos == 1)
        #expect(review.favorites == 1)
        #expect(review.activeDays == 7)
        #expect(review.busiestDay?.count == 12)
        #expect(review.busiestDay?.cover == 103)
        #expect(review.busiestDay?.date == utcCalendar.startOfDay(for: day(2025, 7, 14)))
        #expect(review.longestStreak?.days == 5)
        #expect(review.longestStreak?.start == utcCalendar.startOfDay(for: day(2025, 3, 1)))
        #expect(review.topMonth == YearInReview.Month(month: 7, count: 12))
        #expect(review.months[2] == 6 && review.months[6] == 12 && review.months.count == 12)
        #expect(review.bestOf.first == 103)
        #expect(review.bestOf.count == 9)
        #expect(!review.bestOf.contains(300))
        #expect(review.cards == [.intro, .busiestDay, .streak, .favorites, .bestOf])
    }

    @Test func peopleAreNamedOnlyAndHiddenPeopleStayHidden() {
        let items = [
            item(1, day(2025, 1, 1), people: ["Ada", "17"]), item(2, day(2025, 1, 2), people: ["Ada", "Ada"]),
            item(3, day(2025, 1, 3), people: ["Grace"]), item(4, day(2025, 1, 4), people: ["Secret"]),
            item(5, day(2025, 1, 5), people: ["Secret"]),
        ]
        let review = YearInReview(year: 2025, items: items, hiddenPeople: ["Secret"], calendar: utcCalendar)
        #expect(review.people.map(\.name) == ["Ada", "Grace"])
        #expect(review.people.first?.count == 2)
        #expect(review.cards.contains(.people))
    }

    @Test func petsSnowAndBeachComeFromTheDevicesLabels() {
        var items = (1...4).map { item(FileID($0), day(2025, 2, $0), labels: ["dog", "grass"]) }
        items.append(item(10, day(2025, 1, 20), labels: ["snow", "mountain"]))
        items.append(item(11, day(2025, 12, 1), labels: ["snow"]))
        items.append(item(12, day(2025, 8, 3), labels: ["beach", "sky"]))
        items.append(item(13, day(2025, 3, 3), labels: ["cat"]))
        let review = YearInReview(year: 2025, items: items, calendar: utcCalendar)
        #expect(review.pets.map(\.name) == ["dog", "cat"])
        #expect(review.pets.first?.count == 4)
        #expect(review.firstSnow?.fileId == 10)
        #expect(review.firstBeach?.fileId == 12)
        #expect(review.cards.contains(.pets) && review.cards.contains(.firstSnow) && review.cards.contains(.firstBeach))
        // Without labels (labelling off) none of these cards.
        let plain = YearInReview(
            year: 2025,
            items: items.map {
                var copy = $0; copy.labels = []; return copy
            }, calendar: utcCalendar)
        #expect(!plain.cards.contains(.pets) && !plain.cards.contains(.firstSnow))
    }

    @Test func travelNeedsMoreThanOnePlaceOrAJourney() {
        let home = [item(1, day(2025, 1, 1), at: lisbon, place: "Lisbon"), item(2, day(2025, 1, 2), at: lisbon, place: "Lisbon")]
        #expect(!YearInReview(year: 2025, items: home, calendar: utcCalendar).cards.contains(.travel))
        let away = home + [item(3, day(2025, 4, 1), at: porto, place: "Porto", country: "Portugal")]
        let review = YearInReview(year: 2025, items: away, calendar: utcCalendar)
        #expect(review.cards.contains(.travel))
        #expect(review.travel.places == ["Lisbon", "Porto"])
        #expect(review.travel.kilometres > 270)
    }

    @Test func theReviewIsOfferedAroundNewYear() {
        #expect(YearInReview.seasonalYear(now: day(2025, 12, 2), calendar: utcCalendar) == 2025)
        #expect(YearInReview.seasonalYear(now: day(2026, 1, 20), calendar: utcCalendar) == 2025)
        #expect(YearInReview.seasonalYear(now: day(2026, 2, 1), calendar: utcCalendar) == nil)
        #expect(YearInReview.seasonalYear(now: day(2026, 11, 30), calendar: utcCalendar) == nil)
    }

    @Test func aPastYearsRecapCanBeAskedFor() {
        let items =
            (0..<40).map { MemoryItem(fileId: FileID($0), timestamp: day(2023, 1 + $0 % 12, 1 + $0 % 27)) }
            + (0..<40).map { MemoryItem(fileId: FileID(100 + $0), timestamp: day(2025, 1 + $0 % 12, 2)) }
        #expect(Memories.yearRecap(items, calendar: utcCalendar)?.kind == .yearRecap(2025))
        #expect(Memories.yearRecap(items, year: 2023, calendar: utcCalendar)?.kind == .yearRecap(2023))
        #expect(Memories.yearRecap(items, year: 2024, calendar: utcCalendar) == nil)
    }

    // MARK: Beat detection

    /// Clicks (short decaying noise bursts) at `tempo` from `offset`, over a quiet hum, at 11 025 Hz.
    func clickTrack(tempo: Double, offset: Double, seconds: Double, rate: Double = 11_025) -> [Float] {
        var samples = [Float](repeating: 0, count: Int(seconds * rate))
        var generator = SeededRandom(seed: 7)
        for index in samples.indices { samples[index] = 0.02 * Float(sin(Double(index) * 2 * .pi * 110 / rate)) }
        var beat = offset
        while beat < seconds {
            let start = Int(beat * rate)
            for step in 0..<Int(0.03 * rate) where start + step < samples.count {
                let decay = Float(exp(-Double(step) / (0.008 * rate)))
                samples[start + step] += 0.8 * decay * Float.random(in: -1...1, using: &generator)
            }
            beat += 60 / tempo
        }
        return samples
    }

    @Test(arguments: [(100.0, 0.25), (128.0, 0.6), (75.0, 0.1)])
    func theBeatOfAClickTrackIsFound(tempo: Double, offset: Double) throws {
        let rhythm = try #require(BeatDetection.rhythm(samples: clickTrack(tempo: tempo, offset: offset, seconds: 30), sampleRate: 11_025))
        #expect(rhythm.isMusical)
        #expect(abs(rhythm.tempo - tempo) < 2, "tempo \(rhythm.tempo)")
        // The grid lands on the clicks (within a window or two).
        let period = 60 / tempo
        let distance = (rhythm.phase - offset).truncatingRemainder(dividingBy: period)
        let wrapped = min(abs(distance), period - abs(distance))
        #expect(wrapped < 0.05, "phase \(rhythm.phase) beat \(rhythm.beat)")
    }

    @Test func noiseAndSilenceHaveNoBeat() {
        var generator = SeededRandom(seed: 7)
        let noise = (0..<(11_025 * 20)).map { _ in Float.random(in: -0.3...0.3, using: &generator) }
        #expect(BeatDetection.rhythm(samples: noise, sampleRate: 11_025) == nil)
        #expect(BeatDetection.rhythm(samples: [Float](repeating: 0, count: 11_025 * 20), sampleRate: 11_025) == nil)
        #expect(BeatDetection.rhythm(samples: [0.5, -0.5], sampleRate: 11_025) == nil)
    }
}

/// A repeatable random sequence (SplitMix64), so the signal tests do not depend on luck.
struct SeededRandom: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
