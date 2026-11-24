// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosModel

/// What the TV app leaves for its Top Shelf and what the iPhone sends to the watch (SPEC §15.3).
@Suite struct CompanionContentTests {
    @Test func watchFileNamesAreSafeAndChangeWithTheVersion() {
        let name = WatchDigest.fileName(fileId: 42, etag: "\"5f3a-b\"/../x")
        #expect(name == "42-5f3abx.jpg")
        #expect(WatchDigest.isValidFileName(name))
        #expect(WatchDigest.fileName(fileId: 42, etag: "a") != WatchDigest.fileName(fileId: 42, etag: "b"))
        // An etag with letters of other scripts still gives a plain name.
        #expect(WatchDigest.isValidFileName(WatchDigest.fileName(fileId: 7, etag: "ünïcode")))
    }

    @Test func onlyPlainJPEGNamesAreAcceptedFromThePhone() {
        for bad in [
            "../evil.jpg", "a/b.jpg", ".jpg", ".hidden.jpg", "x.png", "digest.json", "", String(repeating: "a", count: 70) + ".jpg",
            "ä.jpg",
        ] {
            #expect(!WatchDigest.isValidFileName(bad), "\(bad)")
        }
        #expect(WatchDigest.isValidFileName("123-abc.jpg"))
    }

    @Test func yearsAreCountedInCalendarYears() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let day = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 24)))
        let taken = try #require(calendar.date(from: DateComponents(year: 2024, month: 11, day: 25, hour: 16)))
        #expect(WatchDigest.yearsAgo(taken, day: day, calendar: calendar) == 2)
        #expect(WatchDigest.yearsAgo(day, day: day, calendar: calendar) == 0)
    }

    @Test func digestRoundTripsAndFindsItsPhotoOfTheDay() throws {
        let photos = [
            WatchDigest.Photo(id: 1, section: .onThisDay, date: Date(timeIntervalSince1970: 0), place: "Rome", file: "1-a.jpg"),
            WatchDigest.Photo(id: 2, section: .favorites, date: Date(timeIntervalSince1970: 10), place: nil, file: "2-b.jpg"),
        ]
        let digest = WatchDigest(day: Date(timeIntervalSince1970: 86_400), onThisDayTitle: "2 years ago", photos: photos, photoOfTheDay: 2)
        let decoded = try JSONDecoder().decode(WatchDigest.self, from: JSONEncoder().encode(digest))
        #expect(decoded == digest)
        #expect(decoded.photoOfTheDayEntry?.file == "2-b.jpg")
        #expect(decoded.photos(in: .onThisDay).map(\.id) == [1])
        #expect(decoded.files == ["1-a.jpg", "2-b.jpg"])
        #expect(!decoded.isLocked)
    }

    @Test func topShelfManifestRoundTrips() throws {
        let item = TopShelfManifest.Item(
            id: "years-2", title: "2 years ago", subtitle: nil, imageFile: "3-c.jpg",
            link: URL(string: "nextcloudphotos://memories/years-2")!, playLink: URL(string: "nextcloudphotos://memories/years-2/play")!)
        let manifest = TopShelfManifest(generated: Date(timeIntervalSince1970: 5), items: [item])
        #expect(try JSONDecoder().decode(TopShelfManifest.self, from: JSONEncoder().encode(manifest)) == manifest)
    }
}
