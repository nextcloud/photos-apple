// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosDomain
@testable import PhotosModel

/// Geo helpers, "Then and now" and the travel history (SPEC §15.6).
@Suite struct PlacesDelightTests {
    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    let calendar = Self.utc

    func date(_ year: Int, _ month: Int = 6, _ day: Int = 1, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func item(
        _ id: FileID, _ latitude: Double, _ longitude: Double, _ time: Date, place: String? = nil, country: String? = nil,
        favorite: Bool = false
    ) -> LocatedItem {
        LocatedItem(
            fileId: id, timestamp: time, coordinate: GeoCoordinate(latitude: latitude, longitude: longitude), place: place,
            countryCode: country, isFavorite: favorite)
    }

    /// Metres north of a coordinate, in degrees of latitude.
    func north(_ metres: Double) -> Double { metres / 111_195 }

    // MARK: Geo

    @Test func distancesAreGreatCircles() {
        let lisbon = GeoCoordinate(latitude: 38.7223, longitude: -9.1393)
        let berlin = GeoCoordinate(latitude: 52.52, longitude: 13.405)
        #expect(abs(lisbon.distance(to: berlin) - 2_312_000) < 10_000)
        #expect(lisbon.distance(to: lisbon) == 0)
        // Across the antimeridian: two points 0.2° apart, not 359.8°.
        let west = GeoCoordinate(latitude: 0, longitude: 179.9)
        let east = GeoCoordinate(latitude: 0, longitude: -179.9)
        #expect(abs(west.distance(to: east) - 22_239) < 50)
        #expect(!GeoCoordinate(latitude: 0, longitude: 0).isValid)
        #expect(!GeoCoordinate(latitude: 91, longitude: 0).isValid)
        #expect(GeoCoordinate(latitude: -33.9, longitude: 151.2).isValid)
    }

    @Test func centroidWrapsAroundTheAntimeridian() throws {
        var centroid = GeoCentroid()
        centroid.add(GeoCoordinate(latitude: 10, longitude: 179))
        centroid.add(GeoCoordinate(latitude: 20, longitude: -179))
        let value = try #require(centroid.value)
        #expect(abs(value.latitude - 15) < 1e-9)
        #expect(abs(abs(value.longitude) - 180) < 1e-9)
    }

    @Test func gridFindsEverythingWithinItsRadius() {
        // Points within 100 m of a centre at many latitudes, including near the pole and at the antimeridian, are found.
        for latitude in [0.0, 45, 70, 85, 89.95, -60] {
            for longitude in [0.0, 179.9995, -179.9995] {
                let center = GeoCoordinate(latitude: latitude, longitude: longitude)
                var grid = GeoGrid<Int>(radius: 100)
                var expected = Set<Int>()
                for index in 0..<36 {
                    let angle = Double(index) * 10 * .pi / 180
                    let metres = 99.0
                    let latitudeOffset = metres * cos(angle) / 111_195
                    let longitudeOffset = metres * sin(angle) / (111_195 * max(cos(latitude * .pi / 180), 1e-6))
                    var pointLongitude = longitude + longitudeOffset
                    if pointLongitude > 180 { pointLongitude -= 360 } else if pointLongitude < -180 { pointLongitude += 360 }
                    let point = GeoCoordinate(latitude: min(90, latitude + latitudeOffset), longitude: pointLongitude)
                    guard point.distance(to: center) <= 100 else { continue }
                    grid.insert(index, at: point)
                    expected.insert(index)
                }
                #expect(Set(grid.candidates(near: center)).isSuperset(of: expected), "at \(latitude), \(longitude)")
            }
        }
    }

    // MARK: Then and now

    @Test func spotsNeedTwoYearsWithin100Metres() {
        let items = [
            // Lisbon viewpoint: 2014, 2019, 2025, within a few metres.
            item(1, 38.7139, -9.1334, date(2014), place: "Lisbon", country: "PT"),
            item(2, 38.7139 + north(30), -9.1334, date(2019), place: "Lisbon", country: "PT"),
            item(3, 38.7139 - north(40), -9.1334, date(2025), place: "Lisbon", country: "PT", favorite: true),
            item(4, 38.7139 + north(10), -9.1334, date(2025, 7), place: "Lisbon", country: "PT"),
            // 300 m away: not the same spot, and only one year.
            item(5, 38.7139 + north(300), -9.1334, date(2016), place: "Lisbon"),
            // Berlin, two photos of the same year: no spot.
            item(6, 52.52, 13.405, date(2020)), item(7, 52.52, 13.405, date(2020, 8)),
            // Rome: two years.
            item(8, 41.8902, 12.4922, date(2011), place: "Rome"), item(9, 41.8902, 12.4923, date(2022), place: "Rome"),
        ]
        let spots = ThenAndNow.spots(items.shuffled(), calendar: calendar)
        #expect(spots.count == 2)
        let lisbon = spots[0]
        #expect(lisbon.placeName == "Lisbon")
        #expect(lisbon.countryCode == "PT")
        #expect(lisbon.years.map(\.year) == [2014, 2019, 2025])
        // The favourite leads its year.
        #expect(lisbon.years[2].items == [3, 4])
        #expect(lisbon.covers == [1, 2, 3])
        #expect(ThenAndNow.title(lisbon, fallback: "?") == "Lisbon · 2014 · 2019 · 2025")
        // Rome has fewer years but a longer span: ranked after Lisbon (more years first).
        #expect(spots[1].placeName == "Rome")
        #expect(spots[1].years.map(\.year) == [2011, 2022])
    }

    @Test func titlesShortenLongYearLists() {
        let years = (2010...2016).map { ThenAndNowSpot.Year(year: $0, items: [FileID($0)]) }
        let spot = ThenAndNowSpot(id: "s", center: GeoCoordinate(latitude: 1, longitude: 1), placeName: nil, countryCode: nil, years: years)
        #expect(ThenAndNow.title(spot, fallback: "Here") == "Here · 2010 · 2011 · 2012 · … · 2016")
    }

    @Test func viewerSpotIsCentredOnThePhoto() throws {
        let photo = item(10, 48.8584, 2.2945, date(2024), place: "Paris")
        let nearby = [
            item(11, 48.8584 + north(80), 2.2945, date(2012), place: "Paris"),
            item(12, 48.8584 + north(150), 2.2945, date(2015), place: "Paris"),  // too far from this photo
            item(13, 48.8584 - north(20), 2.2945, date(2024, 9), place: "Paris", favorite: true),
        ]
        let spot = try #require(ThenAndNow.spot(around: photo, nearby: nearby + [photo], calendar: calendar))
        #expect(spot.years.map(\.year) == [2012, 2024])
        // The photo itself leads its year, before the favourite.
        #expect(spot.years[1].items == [10, 13])
        #expect(ThenAndNow.spot(around: photo, nearby: [nearby[1]], calendar: calendar) == nil)
    }

    @Test func distinctPlacesKeepOneSpotPerName() {
        func spot(_ id: String, _ name: String?) -> ThenAndNowSpot {
            ThenAndNowSpot(
                id: id, center: GeoCoordinate(latitude: 1, longitude: 1), placeName: name, countryCode: nil,
                years: [.init(year: 2000, items: [1]), .init(year: 2001, items: [2])])
        }
        let result = ThenAndNow.distinctPlaces(
            [spot("a", "Lisbon"), spot("b", "Lisbon"), spot("c", nil), spot("d", nil), spot("e", "Rome")], limit: 3)
        #expect(result.map(\.id) == ["a", "c", "d"])
    }

    @Test func comparedPhotosAreSpreadOverTheYear() {
        let year = ThenAndNowSpot.Year(year: 2020, items: (1...100).map { FileID($0) })
        let compared = ThenAndNow.compared(year, limit: 6)
        #expect(compared.count == 6)
        #expect(Array(compared.prefix(3)) == [1, 2, 3])
        #expect(Set(compared).count == 6)
        #expect(compared.last! > 60)
        #expect(ThenAndNow.compared(ThenAndNowSpot.Year(year: 2020, items: [5, 6]), limit: 6) == [5, 6])
    }

    @Test func alignedYearsLeadWithTheMatchingView() {
        // Photos 1x of 2015, 2x of 2020, 3x of 2025; the "view" of a photo is its last digit.
        let spot = ThenAndNowSpot(
            id: "s", center: GeoCoordinate(latitude: 1, longitude: 1), placeName: "X", countryCode: nil,
            years: [
                .init(year: 2015, items: [11, 12, 13]), .init(year: 2020, items: [21, 22, 23, 29]), .init(year: 2025, items: [31, 33]),
            ])
        func view(_ id: FileID) -> Double { Double(id % 10) }
        let aligned = ThenAndNow.alignedYears(spot) { a, b in abs(view(a) - view(b)) }
        // Anchor 31 (view 1) matches 11 and 21 exactly; anchor 33 also matches (13, 23): the first best is kept.
        #expect(aligned.covers == [11, 21, 31])
        // Anchored on 2020: 29 (view 9) is not the first, 21 is — nothing changes for 2020; others follow it.
        let anchored = ThenAndNow.alignedYears(spot, anchorYear: 2020, anchorCandidates: 1) { a, b in abs(view(a) - view(b)) }
        #expect(anchored.covers == [11, 21, 31])
        // A view seen only from the second photo of 2025 leads when only that one matches the others.
        let shifted = ThenAndNow.alignedYears(spot) { a, b in
            let match: Set<FileID> = [33, 13, 23]
            return match.contains(a) && match.contains(b) ? 0 : 5
        }
        #expect(shifted.covers == [13, 23, 33])
        #expect(shifted.years[2].items == [33, 31])
        // Nothing comparable: unchanged.
        #expect(ThenAndNow.alignedYears(spot) { _, _ in nil } == spot)
    }

    // MARK: Time-lapse

    @Test func timeLapseHoldsFadesAndStops() {
        let plan = TimeLapsePlan(count: 3, hold: 2, fade: 1, zoom: 1.1)
        #expect(plan.duration == 8)
        let start = plan.moment(at: 0)
        #expect(start.from == 0 && start.to == 1 && start.mix == 0)
        let fading = plan.moment(at: 2.5)
        #expect(fading.from == 0 && fading.to == 1 && abs(fading.mix - 0.5) < 1e-9)
        #expect(plan.moment(at: 2.4).captioned == 0)
        #expect(plan.moment(at: 2.6).captioned == 1)
        let second = plan.moment(at: 3.5)
        #expect(second.from == 1 && second.mix == 0)
        // The last photo is held, never fades out, and the plan stops on it.
        let end = plan.moment(at: 100)
        #expect(end.from == 2 && end.mix == 0)
        // Photos grow while shown, without a jump where one takes over from the other.
        let before = plan.moment(at: 2.999)
        let after = plan.moment(at: 3.0)
        #expect(abs(before.toScale - after.fromScale) < 0.01)
        #expect(plan.moment(at: 1).fromScale > 1 && plan.moment(at: 1).fromScale <= 1.1)
        #expect(plan.frameTimes(framesPerSecond: 10).count == 80)
    }

    @Test func playerLoopsAndRespectsReduceMotion() {
        let plan = TimeLapsePlan.player(count: 2, reduceMotion: true)
        #expect(plan.zoom == 1)
        #expect(plan.loops)
        let wrap = plan.moment(at: plan.segment + plan.hold + plan.fade / 2)
        #expect(wrap.from == 1 && wrap.to == 0 && wrap.mix > 0.4)
        #expect(plan.moment(at: plan.duration + 0.1).from == 0)
        #expect(TimeLapsePlan(count: 0).moment(at: 3).mix == 0)
    }

    // MARK: Travel

    /// Home in Berlin with photos on many days, a trip to Lisbon and Porto in 2019, Rome in 2023, a day trip to Potsdam.
    var library: [LocatedItem] {
        var items: [LocatedItem] = []
        var id: FileID = 1
        func add(_ latitude: Double, _ longitude: Double, _ time: Date, _ place: String?, _ country: String?) {
            items.append(item(id, latitude, longitude, time, place: place, country: country))
            id += 1
        }
        for day in stride(from: 1, through: 28, by: 3) { add(52.52, 13.405, date(2019, 3, day), "Berlin", "DE") }
        add(38.7223, -9.1393, date(2019, 5, 1), "Lisbon", "PT")
        add(38.7223, -9.1393, date(2019, 5, 2), "Lisbon", "PT")
        add(41.1579, -8.6291, date(2019, 5, 4), "Porto", "PT")
        for day in stride(from: 1, through: 28, by: 4) { add(52.52, 13.405, date(2019, 9, day), "Berlin", "DE") }
        add(52.39, 13.065, date(2020, 7, 1), "Potsdam", "DE")  // 27 km: still home
        add(41.9028, 12.4964, date(2023, 4, 1), "Rome", nil)  // no country on the server
        add(41.9028, 12.4964, date(2023, 4, 2), "Rome", nil)
        for day in 1...5 { add(52.52, 13.405, date(2023, 10, day * 5), "Berlin", "DE") }
        return items
    }

    @Test func historyFindsHomeTripsAndPlaces() throws {
        let history = TravelHistory(library.shuffled(), calendar: calendar)
        let home = try #require(history.home)
        #expect(history.places[home].name == "Berlin")
        #expect(Set(history.places.compactMap(\.name)) == ["Berlin", "Lisbon", "Porto", "Potsdam", "Rome"])
        // Potsdam is near home: not a trip. Lisbon + Porto is one trip, Rome another.
        #expect(history.trips.count == 2)
        let portugal = history.trips[0]
        #expect(portugal.placeNames == ["Lisbon", "Porto"])
        #expect(portugal.path.count == 4)  // home, Lisbon, Porto, home
        let expected = [
            GeoCoordinate(latitude: 52.52, longitude: 13.405), GeoCoordinate(latitude: 38.7223, longitude: -9.1393),
            GeoCoordinate(latitude: 41.1579, longitude: -8.6291), GeoCoordinate(latitude: 52.52, longitude: 13.405),
        ]
        let length = zip(expected, expected.dropFirst()).reduce(0.0) { $0 + $1.0.distance(to: $1.1) }
        #expect(abs(portugal.distance - length) < 100)
        #expect(history.trips[1].placeNames == ["Rome"])
        #expect(history.years == [2023, 2020, 2019])
    }

    @Test func statsAndCountriesPerYear() throws {
        var history = TravelHistory(library, calendar: calendar)
        let all = history.stats()
        // Rome has no country yet.
        #expect(all.countries == 2)
        #expect(all.trips == 2)
        #expect(all.places == 5)
        #expect(all.items == library.count)
        let farthest = try #require(all.farthest)
        #expect(history.places[farthest.place].name == "Lisbon")

        let rome = try #require(history.placesWithoutCountry.first)
        #expect(rome.name == "Rome")
        history = history.assigningCountries([rome.id: "it"])
        #expect(history.placesWithoutCountry.isEmpty)
        let countries = history.countries()
        #expect(countries.map(\.code) == ["DE", "PT", "IT"])
        #expect(countries[0].years == [2019, 2020, 2023])
        #expect(countries[1].places.count == 2)
        #expect(history.items(inCountry: "IT").count == 2)

        let year2019 = history.stats(in: 2019)
        #expect(year2019.countries == 2)
        #expect(year2019.trips == 1)
        #expect(year2019.distance == history.trips[0].distance)
        #expect(history.stats(in: 2023).countries == 2)
        #expect(history.countries(in: 2020).map(\.code) == ["DE"])
        #expect(history.places(in: 2023).first?.name == "Berlin")
        #expect(history.stats(in: 2021).items == 0)
    }

    @Test func legsAreDrawnOncePerPairOfPlaces() throws {
        // Two trips to Lisbon and one to Lisbon and Porto: home–Lisbon three times, Lisbon–Porto and Porto–home once.
        var items = library.filter { $0.place == "Berlin" }
        items.append(item(900, 38.7223, -9.1393, date(2024, 2, 1), place: "Lisbon"))
        items.append(item(901, 52.52, 13.405, date(2024, 3, 1), place: "Berlin"))
        items.append(item(902, 38.7223, -9.1393, date(2025, 2, 1), place: "Lisbon"))
        items.append(item(903, 41.1579, -8.6291, date(2025, 2, 3), place: "Porto"))
        items.append(item(904, 52.52, 13.405, date(2025, 3, 1), place: "Berlin"))
        items.append(item(905, 38.7223, -9.1393, date(2026, 2, 1), place: "Lisbon"))
        let history = TravelHistory(items, calendar: calendar)
        #expect(history.trips.count == 3)
        let legs = history.legs()
        #expect(legs.count == 3)
        func name(_ place: Int) -> String? { history.places[place].name }
        let homeLisbon = try #require(legs.first { Set([name($0.from), name($0.to)]) == ["Berlin", "Lisbon"] })
        #expect(homeLisbon.count == 3)
        #expect(homeLisbon.latest == date(2026, 2, 1))
        #expect(legs.last?.id == homeLisbon.id)
        #expect(history.legs(in: 2025).count == 3)
        #expect(history.legs(in: 2024).map(\.count) == [1])
        #expect(history.trips[1].stops.map(name) == ["Berlin", "Lisbon", "Porto", "Berlin"])
    }

    @Test func itemsOfPlacesAndTrips() throws {
        let history = TravelHistory(library, calendar: calendar)
        let lisbon = try #require(history.places.first { $0.name == "Lisbon" })
        #expect(history.items(ofPlace: lisbon.id).count == 2)
        #expect(history.items(ofTrip: history.trips[0]).count == 3)
        #expect(history.items(ofPlace: 999).isEmpty)
    }

    @Test func tripsSplitOnLongGapsAndWithoutHome() {
        // Only travel photos: the place with most days becomes home; two runs of visits far apart in time are two trips.
        let items = [
            item(1, 35.68, 139.69, date(2018, 1, 1)), item(2, 35.68, 139.69, date(2018, 1, 2)), item(3, 35.68, 139.69, date(2018, 1, 3)),
            item(4, -33.86, 151.2, date(2019, 2, 1)), item(5, -36.85, 174.76, date(2019, 2, 3)),
            item(6, -33.86, 151.2, date(2019, 6, 1)),
        ]
        let history = TravelHistory(items, calendar: calendar)
        #expect(history.home.map { history.places[$0].coordinate.latitude } == 35.68)
        #expect(history.trips.count == 2)
        #expect(history.trips[0].visits.count == 2)
        #expect(TravelHistory([], calendar: calendar).stats().distance == 0)
        #expect(TravelHistory([], calendar: calendar).home == nil)
    }

    @Test func flagsAndWorldShare() {
        #expect(TravelHistory.flag("pt") == "🇵🇹")
        #expect(TravelHistory.flag("PRT") == nil)
        #expect(TravelHistory.flag("1A") == nil)
        #expect(TravelHistory.worldShare(39) == 0.2)
        #expect(TravelHistory.worldShare(400) == 1)
    }
}
