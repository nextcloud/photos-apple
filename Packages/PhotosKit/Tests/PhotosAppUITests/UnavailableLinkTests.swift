// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosDomain
import PhotosModel
import Testing

@testable import PhotosAppUI

/// Links to a screen the server cannot fill explain themselves instead of doing nothing (SPEC §20.2).
@Suite struct UnavailableLinkTests {
    /// What a stock Photos server without Recognize, tags or trash bin offers.
    let stock: (ServerFeature) -> Bool = { $0 == .photosDAV || $0 == .places }
    let everything: (ServerFeature) -> Bool = { _ in true }

    func link(_ string: String) throws -> DeepLink {
        let url = try #require(URL(string: string))
        return try #require(DeepLink(url: url))
    }

    @Test func screensThatNeedAMissingFeatureAreReported() throws {
        #expect(AppDestination.unavailableScreen(of: try link("nextcloudphotos://people"), has: stock) == .people)
        #expect(AppDestination.unavailableScreen(of: try link("nextcloudphotos://faces/Anna"), has: stock) == .people)
        #expect(AppDestination.unavailableScreen(of: try link("nextcloudphotos://tags/Beach"), has: stock) == .tags)
        #expect(AppDestination.unavailableScreen(of: try link("nextcloudphotos://recentlyDeleted"), has: stock) == .recentlyDeleted)
    }

    @Test func availableScreensAndOtherLinksOpen() throws {
        for url in [
            "nextcloudphotos://albums", "nextcloudphotos://places", "nextcloudphotos://map", "nextcloudphotos://memories",
            "nextcloudphotos://photo/42", "nextcloudphotos://places/Lisbon", "nextcloudphotos://search/dog",
        ] {
            #expect(AppDestination.unavailableScreen(of: try link(url), has: stock) == nil, "\(url)")
        }
        for url in ["nextcloudphotos://people", "nextcloudphotos://tags/Beach", "nextcloudphotos://recentlyDeleted"] {
            #expect(AppDestination.unavailableScreen(of: try link(url), has: everything) == nil, "\(url)")
        }
        // Albums need Photos' WebDAV, which every Photos version has; a server without the Photos app has none.
        #expect(AppDestination.unavailableScreen(of: try link("nextcloudphotos://albums"), has: { _ in false }) == .albums)
    }
}
