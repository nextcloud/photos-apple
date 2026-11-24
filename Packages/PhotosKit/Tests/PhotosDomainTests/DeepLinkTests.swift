// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel
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
        #expect(link("nextcloudphotos://memories/extra") == nil)
    }

    @Test func theRequestFormRoundTrips() {
        let links: [DeepLink] = [
            .destination("places"), .album(id: "own:2024/25"), .album(id: "shared:Trip (alice)"), .photo(fileId: 9),
            .place(name: "Lisbon"), .person(name: "Anna Maria"), .tag(name: "a/b"), .folder(path: "/Photos/2024"),
            .search("dogs at the beach"),
        ]
        for link in links { #expect(DeepLink(request: link.request) == link) }
        #expect(DeepLink(request: "") == nil)
        // Notifications and intents hand over plain destination names.
        #expect(DeepLink(request: "memories") == .destination("memories"))
    }
}

/// The other routes of SPEC §4.8, named as in the web app.
@Suite struct DeepLinkRouteTests {
    private func link(_ string: String) -> DeepLink? { URL(string: string).flatMap(DeepLink.init(url:)) }

    @Test func webRoutesWithANameOpenThatCollection() {
        #expect(link("nextcloudphotos://albums/Lisbon%202025") == .album(id: "own:Lisbon 2025"))
        #expect(link("nextcloudphotos://sharedalbums/Trip%20(alice)") == .album(id: "shared:Trip (alice)"))
        #expect(link("nextcloudphotos://places/Lisboa") == .place(name: "Lisboa"))
        #expect(link("nextcloudphotos://faces/Anna") == .person(name: "Anna"))
        #expect(link("nextcloudphotos://tags/holiday") == .tag(name: "holiday"))
        #expect(link("nextcloudphotos://folders/Photos/2024") == .folder(path: "/Photos/2024"))
        #expect(link("nextcloudphotos://search/dogs") == .search("dogs"))
    }

    @Test func webRoutesWithoutANameOpenTheList() {
        #expect(link("nextcloudphotos://places") == .destination("places"))
        #expect(link("nextcloudphotos://faces") == .destination("people"))
        #expect(link("nextcloudphotos://faces/unassigned") == .destination("people"))
        #expect(link("nextcloudphotos://tags") == .destination("tags"))
        #expect(link("nextcloudphotos://folders") == .destination("folders"))
        #expect(link("nextcloudphotos://shared/Some/Folder") == .destination("sharedWithYou"))
        #expect(link("nextcloudphotos://maps") == .destination("map"))
        #expect(link("nextcloudphotos://search") == .destination("search"))
    }

    @Test func aLinkWithAnAccountIsNotAPlainLink() {
        #expect(link("nextcloudphotos://alice@cloud.example.com/albums/Trip") == nil)
    }

    @Test func emptyNamesAreRejected() {
        #expect(DeepLink(request: "place/") == nil)
        #expect(DeepLink(request: "person") == nil)
        #expect(DeepLink(request: "folder") == .folder(path: "/"))
    }

    /// The segments of a link for an account read back to the same route.
    @Test func routeSegmentsRoundTrip() {
        let links: [DeepLink] = [
            .destination("onThisDay"), .album(id: "own:2024/25"), .album(id: "shared:Trip (alice)"), .photo(fileId: 9),
            .place(name: "São Paulo"), .person(name: "Anna"), .tag(name: "x"), .folder(path: "/Photos/2024"), .search("cats"),
        ]
        for link in links { #expect(DeepLink(route: link.routeSegments) == link) }
    }
}

/// Links that name an account, and web links of an account's server (SPEC §4.8).
@Suite struct IncomingLinkTests {
    let alice = Account(serverURL: URL(string: "https://cloud.example.com")!, userId: "alice", loginName: "alice", displayName: "Alice")
    let bob = Account(serverURL: URL(string: "https://cloud.example.com")!, userId: "bob", loginName: "bob", displayName: "Bob")
    let subpath = Account(
        serverURL: URL(string: "https://example.org/nextcloud")!, userId: "a@b.c", loginName: "a@b.c", displayName: "Mail user")
    let local = Account(serverURL: URL(string: "http://localhost:8089")!, userId: "admin", loginName: "admin", displayName: "Admin")
    var accounts: [Account] { [alice, bob, subpath, local] }

    private func resolve(_ string: String, active: Account?) -> IncomingLink? {
        IncomingLink.resolve(URL(string: string)!, accounts: accounts, active: active?.id)
    }

    @Test func aPlainLinkOpensInTheAccountShown() {
        #expect(resolve("nextcloudphotos://albums/Trip", active: alice) == .open(.album(id: "own:Trip")))
    }

    @Test func theAccountShownOpensAtOnce() {
        #expect(resolve("nextcloudphotos://alice@cloud.example.com/albums/Trip", active: alice) == .open(.album(id: "own:Trip")))
        #expect(resolve("nextcloudphotos://admin@localhost:8089/faces/Anna", active: local) == .open(.person(name: "Anna")))
    }

    @Test func anotherLoggedInAccountAsksFirst() {
        #expect(
            resolve("nextcloudphotos://bob@cloud.example.com/places/Rome", active: alice) == .switchAccount([bob.id], .place(name: "Rome")))
    }

    @Test func aServerPathIsPartOfTheAccount() {
        #expect(
            resolve("nextcloudphotos://a%40b.c@example.org/nextcloud/tags/x", active: alice)
                == .switchAccount([subpath.id], .tag(name: "x")))
        #expect(resolve("nextcloudphotos://a%40b.c@example.org/nextcloud", active: subpath) == .open(.destination("library")))
    }

    @Test func anUnknownAccountIsExplained() {
        #expect(
            resolve("nextcloudphotos://carol@cloud.example.com/albums/Trip", active: alice) == .unknownAccount("carol@cloud.example.com"))
        #expect(
            resolve("nextcloudphotos://alice@other.example.com/albums/Trip", active: alice) == .unknownAccount("alice@other.example.com"))
        // The port is part of the server.
        #expect(resolve("nextcloudphotos://admin@localhost:8090/albums", active: local) == .unknownAccount("admin@localhost:8090"))
    }

    @Test func linksMadeForAnAccountReadBack() throws {
        for account in accounts {
            for link: DeepLink in [
                .album(id: "own:A/B c"), .album(id: "shared:Trip (bob)"), .person(name: "Anna"), .place(name: "São Paulo"),
            ] {
                let url = try #require(link.url(for: account))
                #expect(IncomingLink.resolve(url, accounts: accounts, active: account.id) == .open(link))
            }
        }
    }

    @Test func webLinksOfAnAccountsServerOpenTheSameRoute() {
        #expect(
            resolve("https://cloud.example.com/index.php/apps/photos/albums/Trip%202024", active: alice)
                == .open(.album(id: "own:Trip 2024")))
        #expect(resolve("https://cloud.example.com/apps/photos/", active: alice) == .open(.destination("library")))
        #expect(resolve("https://cloud.example.com/apps/photos/thisday", active: alice) == .open(.destination("onThisDay")))
        #expect(
            resolve("https://example.org/nextcloud/index.php/apps/photos/folders/Photos", active: subpath)
                == .open(.folder(path: "/Photos")))
    }

    @Test func aWebLinkOfAnotherServerAsksOrExplains() {
        // Both accounts of the server are offered.
        #expect(
            resolve("https://cloud.example.com/apps/photos/favorites", active: local)
                == .switchAccount([alice.id, bob.id], .destination("favorites")))
        #expect(resolve("https://photos.example.net/apps/photos/favorites", active: local) == .unknownAccount("photos.example.net"))
        #expect(resolve("https://example.org/apps/photos/favorites", active: local) == .unknownAccount("example.org"))
    }

    @Test func publicAlbumLinksNeedNoAccount() {
        #expect(
            resolve("https://share.example.net/index.php/apps/photos/public/AbC123", active: nil)
                == .publicAlbum(serverURL: URL(string: "https://share.example.net")!, token: "AbC123"))
        #expect(
            resolve("https://example.org/nextcloud/apps/photos/public/tok?x=1", active: nil)
                == .publicAlbum(serverURL: URL(string: "https://example.org/nextcloud")!, token: "tok"))
    }

    @Test func otherLinksAreNotOurs() {
        #expect(resolve("https://cloud.example.com/apps/files/", active: alice) == nil)
        #expect(resolve("mailto:alice@example.com", active: alice) == nil)
        #expect(
            resolve("https://cloud.example.com/apps/photos/albums/Trip/extra/photo/1", active: alice)
                == .open(.album(id: "own:Trip/extra/photo/1")))
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

    /// A photo link (ids are easy to guess, any app can send one) opens only what the library shows.
    @Test func photoLinksOnlyOpenWhatTheLibraryShows() {
        let photo = MediaItem(fileId: 7, path: "/Photos/a.jpg", mimeType: "image/jpeg")
        #expect(DeepLink.mayOpen(photo))
        #expect(!DeepLink.mayOpen(nil))
        var archived = photo
        archived.isArchived = true
        #expect(!DeepLink.mayOpen(archived))
        var motion = photo
        motion.isLivePhotoVideo = true
        #expect(!DeepLink.mayOpen(motion))
    }

    /// The stored place of a window names an album of one account: it is not restored for another one and is dropped when
    /// that account is removed.
    @Test func theStoredPlaceBelongsToAnAccount() throws {
        let snapshot = NavigationSnapshot(destination: "albums", routes: [.album(id: "own:Secret trip")], account: "alice@cloud")
        let stored = snapshot.stored
        #expect(NavigationSnapshot(stored: stored) == snapshot)
        #expect(snapshot.belongs(to: "alice@cloud"))
        #expect(!snapshot.belongs(to: "bob@cloud"))
        #expect(!NavigationSnapshot.isStale(stored, accounts: ["alice@cloud", "bob@cloud"]))
        #expect(NavigationSnapshot.isStale(stored, accounts: ["bob@cloud"]))
        #expect(!NavigationSnapshot.isStale("", accounts: []))
        // Written by an earlier version: whose it is is unknown, so it is not kept.
        let old = #"{"destination":"albums","routes":[{"album":{"id":"own:Secret trip"}}]}"#
        #expect(NavigationSnapshot(stored: old)?.account == nil)
        #expect(NavigationSnapshot.isStale(old, accounts: ["alice@cloud"]))
    }
}
