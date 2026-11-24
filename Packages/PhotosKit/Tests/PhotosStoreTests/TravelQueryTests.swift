// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosDomain
@testable import PhotosModel
@testable import PhotosStore

/// The located rows for the travel globe and "Then and now" (SPEC §15.6).
@Suite struct TravelQueryTests {
    let library: LibraryStore

    init() throws {
        library = LibraryStore(database: try AccountDatabase.temporary())
    }

    func located(
        _ id: FileID, _ latitude: Double?, _ longitude: Double?, year: Int, place: String? = nil, country: String? = nil,
        archived: Bool = false
    ) -> MediaItem {
        let time = Date(timeIntervalSince1970: Double(year - 1970) * 365.25 * 86_400 + 180 * 86_400)
        return MediaItem(
            fileId: id, path: "/Photos/\(id).jpg", mimeType: "image/jpeg", etag: "e\(id)", modifiedAt: time, capturedAt: time,
            latitude: latitude, longitude: longitude, place: place, placeCountry: country, isArchived: archived)
    }

    @Test func locatedItemsCarryPlaceAndCountry() async throws {
        try library.upsert([
            located(1, 38.7139, -9.1334, year: 2014, place: "Lisbon", country: "PT"),
            located(2, nil, nil, year: 2015),
            located(3, 0, 0, year: 2016),  // broken GPS tag
            located(4, 52.52, 13.405, year: 2017, archived: true),
        ])
        let items = try await library.locatedItems()
        #expect(items.map(\.fileId) == [1])
        #expect(items.first?.place == "Lisbon")
        #expect(items.first?.countryCode == "PT")
    }

    @Test func spotAroundAPhotoNeedsAnotherYearNearby() throws {
        let metre = 1 / 111_195.0
        try library.upsert([
            located(10, 38.7139, -9.1334, year: 2025, place: "Lisbon"),
            located(11, 38.7139 + 60 * metre, -9.1334, year: 2014, place: "Lisbon"),
            located(12, 38.7139 + 500 * metre, -9.1334, year: 2010, place: "Lisbon"),
            located(13, 52.52, 13.405, year: 2020),
        ])
        let spot = try #require(try library.thenAndNowSpot(around: 10))
        #expect(spot.years.map(\.items) == [[11], [10]])
        #expect(spot.placeName == "Lisbon")
        #expect(try library.thenAndNowSpot(around: 13) == nil)
        #expect(try library.thenAndNowSpot(around: 999) == nil)
    }

    @Test func nearQueryCrossesTheAntimeridian() throws {
        let metre = 1 / 111_195.0
        try library.upsert([
            located(20, -16.5, 179.9999, year: 2012), located(21, -16.5, -179.9999, year: 2022), located(22, -16.5, 179.5, year: 2019),
        ])
        let near = try library.locatedItems(near: GeoCoordinate(latitude: -16.5, longitude: 179.9999), radius: 100 + metre)
        #expect(Set(near.map(\.fileId)) == [20, 21])
        let spot = try #require(try library.thenAndNowSpot(around: 21))
        #expect(spot.years.map(\.year).count == 2)
    }
}
