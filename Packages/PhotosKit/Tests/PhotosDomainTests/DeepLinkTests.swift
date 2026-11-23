// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosDomain

@Suite struct DeepLinkTests {
    private func link(_ string: String) -> DeepLink? { URL(string: string).flatMap(DeepLink.init(url:)) }

    @Test func aHostAloneIsADestination() {
        #expect(link("nextcloudphotos://albums") == .destination("albums"))
        #expect(link("nextcloudphotos://onThisDay") == .destination("onThisDay"))
        #expect(link("NextcloudPhotos://memories") == .destination("memories"))
    }

    @Test func webRouteNamesAreMappedToDestinations() {
        #expect(link("nextcloudphotos://timeline") == .destination("library"))
        #expect(link("nextcloudphotos://thisday") == .destination("onThisDay"))
        #expect(link("nextcloudphotos://sharedalbums") == .destination("sharedAlbums"))
    }

    @Test func albumLinksCarryTheAlbumId() {
        #expect(link("nextcloudphotos://album/Lisbon%202025") == .album(id: "own:Lisbon 2025"))
        #expect(link("nextcloudphotos://album/own:Lisbon%202025") == .album(id: "own:Lisbon 2025"))
        #expect(link("nextcloudphotos://album/shared:Trip%20(alice)") == .album(id: "shared:Trip (alice)"))
        #expect(link("nextcloudphotos://album/shared/Trip%20(alice)") == .album(id: "shared:Trip (alice)"))
    }

    @Test func anAlbumNameMayContainASlash() {
        #expect(link("nextcloudphotos://album/2024%2F25") == .album(id: "own:2024/25"))
        #expect(link("nextcloudphotos://album/2024/25") == .album(id: "own:2024/25"))
    }

    @Test func photoLinksCarryTheFileId() {
        #expect(link("nextcloudphotos://photo/4711") == .photo(fileId: 4711))
    }

    @Test func malformedLinksAreRejected() {
        #expect(link("https://photo/4711") == nil)
        #expect(link("nextcloudphotos://") == nil)
        #expect(link("nextcloudphotos://album") == nil)
        #expect(link("nextcloudphotos://album/own:") == nil)
        #expect(link("nextcloudphotos://photo") == nil)
        #expect(link("nextcloudphotos://photo/abc") == nil)
        #expect(link("nextcloudphotos://photo/-3") == nil)
        #expect(link("nextcloudphotos://photo/1/2") == nil)
        #expect(link("nextcloudphotos://albums/extra") == nil)
    }

    @Test func theRequestFormRoundTrips() {
        let links: [DeepLink] = [.destination("places"), .album(id: "own:2024/25"), .album(id: "shared:Trip (alice)"), .photo(fileId: 9)]
        for link in links { #expect(DeepLink(request: link.request) == link) }
        #expect(DeepLink(request: "") == nil)
        // Notifications and intents hand over plain destination names.
        #expect(DeepLink(request: "memories") == .destination("memories"))
    }
}

@Suite struct NavigationSnapshotTests {
    @Test func theSelectedDestinationAndOpenAlbumSurviveARoundTrip() {
        let snapshot = NavigationSnapshot(destination: "albums", routes: [.album(id: "own:Rome 2021")])
        #expect(NavigationSnapshot(stored: snapshot.stored) == snapshot)
    }

    @Test func aSinglePhotoIsNotRestored() {
        let snapshot = NavigationSnapshot(destination: "library", routes: [.photo(fileId: 5)])
        #expect(snapshot.routes.isEmpty)
        #expect(NavigationSnapshot(stored: snapshot.stored)?.destination == "library")
    }

    @Test func garbageIsIgnored() {
        #expect(NavigationSnapshot(stored: "") == nil)
        #expect(NavigationSnapshot(stored: "{not json") == nil)
    }
}

@Suite struct DateRangeLabelTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    /// English with German formats: Foundation's interval style gave "Nov 25 – 26, 2024" next to "24. Nov 2013".
    @Test func singleDatesAndRangesUseTheSameFormat() {
        let locale = Locale(identifier: "en_US@rg=dezzzz")
        let single = DateRangeLabel.string(from: date(2013, 11, 24), to: date(2013, 11, 24), locale: locale, calendar: utc)
        let range = DateRangeLabel.string(from: date(2024, 11, 25), to: date(2024, 11, 26), locale: locale, calendar: utc)
        #expect(single == "24. Nov 2013")
        #expect(range == "25. Nov – 26. Nov 2024")
    }

    @Test func usEnglish() {
        let locale = Locale(identifier: "en_US")
        #expect(DateRangeLabel.string(from: date(2024, 11, 25), to: date(2024, 11, 25), locale: locale, calendar: utc) == "Nov 25, 2024")
        #expect(
            DateRangeLabel.string(from: date(2024, 11, 25), to: date(2024, 11, 26), locale: locale, calendar: utc)
                == "Nov 25 – Nov 26, 2024")
    }

    @Test func aRangeOverNewYearNamesBothYears() {
        let locale = Locale(identifier: "en_GB")
        #expect(
            DateRangeLabel.string(from: date(2024, 12, 30), to: date(2025, 1, 2), locale: locale, calendar: utc)
                == "30 Dec 2024 – 2 Jan 2025")
    }

    @Test func aHalfOpenRangeEndsOnItsLastDay() {
        let start = utc.date(from: DateComponents(year: 2023, month: 6, day: 1))!
        let end = utc.date(from: DateComponents(year: 2023, month: 7, day: 1))!
        #expect(DateRangeLabel.string(for: start..<end, locale: Locale(identifier: "en_GB"), calendar: utc) == "1 Jun – 30 Jun 2023")
    }

    @Test func anEndBeforeTheStartIsTreatedAsOneDay() {
        let locale = Locale(identifier: "en_GB")
        #expect(DateRangeLabel.string(from: date(2024, 5, 2), to: date(2024, 5, 1), locale: locale, calendar: utc) == "2 May 2024")
    }
}
