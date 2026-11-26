// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosModel
import PhotosStore
import SwiftUI
import Testing

@testable import PhotosAppUI

/// The Library's one filter menu, the account button and the upload status (SPEC §19.2).
@Suite struct LibraryToolbarTests {
    @Test func noFilterIsNoChipAndNoCount() {
        let filters = LibraryFilters()
        #expect(filters.chips.isEmpty)
        #expect(filters.activeCount == 0)
        #expect(!filters.isActive)
    }

    @Test func everyActiveFilterHasAChipInTheMenusOrder() {
        let filters = LibraryFilters(kind: .favorites, culling: .picks, hidesPartnerPhotos: true)
        #expect(filters.chips == [.kind(.favorites), .culling(.picks), .partners])
        #expect(filters.activeCount == 3)
        #expect(filters.isActive)
    }

    @Test func aChipClearsOnlyItsOwnFilter() {
        let filters = LibraryFilters(kind: .videos, culling: .rating(atLeast: 3), hidesPartnerPhotos: true)
        #expect(filters.clearing(.kind(.videos)) == LibraryFilters(kind: .all, culling: .rating(atLeast: 3), hidesPartnerPhotos: true))
        #expect(filters.clearing(.culling(.rating(atLeast: 3))) == LibraryFilters(kind: .videos, culling: .all, hidesPartnerPhotos: true))
        #expect(filters.clearing(.partners) == LibraryFilters(kind: .videos, culling: .rating(atLeast: 3), hidesPartnerPhotos: false))
        #expect(filters.clearingAll() == LibraryFilters())
    }

    @Test func theMenuOffersTheKindsTheSidebarRowsWere() {
        #expect(LibraryFilters.kinds == [.all, .photos, .videos, .favorites])
        // The culling choices of the old ratings menu, unchanged.
        #expect(LibraryFilterMenu.cullingChoices.flatMap { $0 }.count == 11)
        #expect(LibraryFilterMenu.cullingChoices.first == [.all])
    }

    @Test @MainActor func theLibraryOpensWithAKindAsAFilter() {
        // The contract with the sidebar: Photos, Videos and Favorites open the Library with that filter set.
        let photos = TimelineScreen(initialKind: .photos)
        #expect(photos.filter == .all)
        #expect(photos.initialKind == .photos)
        // A timeline of its own keeps working.
        let favorites = TimelineScreen(filter: .favorites)
        #expect(favorites.filter == .favorites)
        #expect(favorites.initialKind == .favorites)
        #expect(TimelineScreen().initialKind == .all)
    }

    @Test func uploadsShowOnlyWhileTheyRunOrWhenSomeFailed() {
        #expect(TransfersIndicatorState.state(activeCount: 0, hasFailures: false) == .hidden)
        #expect(TransfersIndicatorState.state(activeCount: 2, hasFailures: false) == .running)
        #expect(TransfersIndicatorState.state(activeCount: 2, hasFailures: true) == .running)
        #expect(TransfersIndicatorState.state(activeCount: 0, hasFailures: true) == .failed)
    }

    @Test func accountInitials() {
        #expect(AccountInitials.initials(of: "Frank Karlitschek") == "FK")
        #expect(AccountInitials.initials(of: "admin") == "A")
        #expect(AccountInitials.initials(of: "anna.maria schmidt") == "AM")
        #expect(AccountInitials.initials(of: "  ") == "")
        #expect(AccountInitials.initials(of: "Émile Zola") == "ÉZ")
    }

    @Test func settingsIsASheetNotATab() {
        #expect(!CompactNavigation.tabs.contains(.settings))
        #expect(CompactNavigation.sheets.contains(.settings))
        #expect(CompactNavigation.tabs.count == 3)
    }

    @Test @MainActor func theDeleteKeyReachesTheViewer() {
        // Delete left the viewer's toolbar for its More menu; ⌫ and ⌦ ask to delete the photo shown.
        for key in MediaViewer.deleteKeys {
            #expect(MediaViewer.hardwareKeys.contains(key))
            #expect(MediaViewer.viewerKey(key) == nil, "⌫ must not page or close the viewer")
        }
    }
}
