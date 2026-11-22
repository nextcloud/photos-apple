// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosModel

@Suite struct ModelTests {
    @Test func serverVersionParsing() {
        #expect(ServerVersion(parsing: "36.0.0 dev")?.major == 36)
        #expect(ServerVersion(parsing: "33.0.1.2")?.micro == 1)
        #expect(ServerVersion(parsing: "32.0.0")?.isSupported == false)
        #expect(ServerVersion(major: 33) < ServerVersion(major: 33, minor: 1))
    }

    @Test func sharedAlbumTitleSuffix() {
        #expect(Album.titleWithoutOwnerSuffix("Lisbon (bob)", ownerId: "bob") == "Lisbon")
        #expect(Album.titleWithoutOwnerSuffix("Trip (2) (bob)", ownerId: nil) == "Trip (2)")
        #expect(Album.titleWithoutOwnerSuffix("Plain", ownerId: "bob") == "Plain")
    }

    @Test func userConfigRoundTrip() {
        var config = PhotosUserConfig()
        config.apply(key: "photosSourceFolders", rawValue: #"["/A","/B"]"#)
        config.apply(key: "croppedLayout", rawValue: "true")
        config.apply(key: "photosLocation", rawValue: "relative")  // ignored: must be absolute
        #expect(config.photosSourceFolders == ["/A", "/B"])
        #expect(config.croppedLayout)
        #expect(config.photosLocation == "/Photos")
        #expect(
            config.rawValue(for: .photosSourceFolders) == #"["\/A","\/B"]"# || config.rawValue(for: .photosSourceFolders) == #"["/A","/B"]"#
        )
    }

    @Test func albumFiltersJSON() throws {
        let json = #"{"date-range":[{"start":1735689600000,"end":1738281600000}],"places":["Lisbon"],"name":["beach"]}"#
        let filters = try JSONDecoder().decode(AlbumFilters.self, from: Data(json.utf8))
        #expect(filters.dateRanges.first?.start == 1_735_689_600_000)
        #expect(filters.places == ["Lisbon"])
        #expect(filters.names == ["beach"])
        #expect(filters.tags.isEmpty)
        let encoded = String(decoding: try JSONEncoder().encode(filters), as: UTF8.self)
        #expect(!encoded.contains("tags"))  // older servers ignore unknown ids; don't send empty ones
    }

    @Test func accountStorageKeyIsStable() {
        let id = AccountID(userId: "alice", serverURL: URL(string: "https://cloud.example.com")!)
        #expect(id.rawValue == "alice https://cloud.example.com")
        #expect(id.storageKey.count == 24)
        #expect(id.storageKey == AccountID(rawValue: "alice https://cloud.example.com").storageKey)
    }
}
