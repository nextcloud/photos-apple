// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosDomain
import PhotosModel
import PhotosStore
import Testing

@testable import PhotosAppUI

/// The slim, editable sidebar (SPEC §19.1): every destination keeps opening, filters and modes instead of rows.
@Suite struct SidebarTests {
    let all: (AppDestination) -> Bool = { _ in true }

    @Test func photosAndVideosAreFiltersOfTheLibrary() {
        #expect(SidebarLayout.entry(for: .photos, visible: all) == .init(destination: .library, libraryKind: .photos))
        #expect(SidebarLayout.entry(for: .videos, visible: all) == .init(destination: .library, libraryKind: .videos))
        #expect(SidebarLayout.entry(for: .library, visible: all) == .init(destination: .library, libraryKind: .all))
        #expect(SidebarLayout.row(for: .photos) == .library)
        #expect(!SidebarLayout.rows.contains(.photos) && !SidebarLayout.rows.contains(.videos))
        // Favorites stays a row of its own.
        #expect(SidebarLayout.pinnedByDefault.contains(.favorites))
    }

    @Test func mapIsAModeOfPlaces() {
        #expect(SidebarLayout.entry(for: .map, visible: all) == .init(destination: .places, placesMode: .map))
        #expect(SidebarLayout.entry(for: .places, visible: all) == .init(destination: .places))
        #expect(SidebarLayout.row(for: .map) == .places)
        // Places is there without the server's places: it is the map then.
        #expect(AppDestination.places.requiredFeature == nil)
    }

    @Test func smartAlbumsAndSharedWithYouOpenOnTopOfTheirRow() {
        #expect(SidebarLayout.entry(for: .smartAlbums, visible: all) == .init(destination: .albums, routes: [.destination("smartAlbums")]))
        #expect(
            SidebarLayout.entry(for: .sharedWithYou, visible: all)
                == .init(destination: .sharedAlbums, routes: [.destination("sharedWithYou")]))
        #expect(SidebarLayout.row(for: .sharedWithYou) == .sharedAlbums)
        #expect(SidebarLayout.entry(for: .onThisDay, visible: all) == .init(destination: .memories, routes: [.destination("onThisDay")]))
    }

    @Test func withoutSharedAlbumsSharedWithYouIsTheSharedRow() {
        let noAlbums: (AppDestination) -> Bool = { $0 != .albums && $0 != .sharedAlbums }
        #expect(SidebarLayout.albumRows(visible: noAlbums) == [.sharedWithYou])
        #expect(SidebarLayout.entry(for: .sharedWithYou, visible: noAlbums) == .init(destination: .sharedWithYou))
        #expect(SidebarLayout.row(for: .sharedWithYou, visible: noAlbums) == .sharedWithYou)
        #expect(SidebarLayout.albumRows(visible: all) == [.albums, .sharedAlbums])
    }

    @Test func duplicatesAndFreeSpaceOpenCleanUpAtTheirSection() {
        #expect(SidebarLayout.entry(for: .duplicates, visible: all) == .init(destination: .cleanUp, cleanUpSource: .duplicates))
        #expect(SidebarLayout.entry(for: .freeSpace, visible: all) == .init(destination: .cleanUp, cleanUpSource: .freeSpace))
        #expect(SidebarLayout.row(for: .freeSpace) == .cleanUp)
        #expect(SidebarLayout.utilities.contains(.cleanUp) && SidebarLayout.utilities.contains(.tags))
    }

    @Test func everyDestinationOpensARowOrHasATab() {
        for destination in AppDestination.allCases where ![.search, .settings, .collections, .backup].contains(destination) {
            let entry = SidebarLayout.entry(for: destination, visible: all)
            #expect(SidebarLayout.rows.contains(entry.destination), "\(destination) opens no row")
            #expect(SidebarLayout.row(for: destination) == entry.destination, "\(destination) highlights another row")
        }
    }

    @Test func aRequestRebuildsTheLibraryOnlyWhenItAsksForAFilter() {
        var request = DestinationRequest()
        request.apply(SidebarLayout.entry(for: .library, visible: all))
        #expect(request.librarySerial == 0)
        request.apply(SidebarLayout.entry(for: .photos, visible: all))
        #expect(request.libraryKind == .photos && request.librarySerial == 1)
        // Photos again (the user may have changed the filter in the meantime): asked again.
        request.apply(SidebarLayout.entry(for: .photos, visible: all))
        #expect(request.librarySerial == 2)
        request.apply(SidebarLayout.entry(for: .library, visible: all))
        #expect(request.libraryKind == .all && request.librarySerial == 3)
        request.apply(SidebarLayout.entry(for: .map, visible: all))
        #expect(request.placesMode == .map && request.placesSerial == 1)
        request.apply(SidebarLayout.entry(for: .places, visible: all))
        #expect(request.placesMode == nil && request.placesSerial == 1)
        request.apply(SidebarLayout.entry(for: .freeSpace, visible: all))
        #expect(request.cleanUpSource == .freeSpace && request.cleanUpSerial == 1)
        request.apply(SidebarLayout.entry(for: .cleanUp, visible: all))
        #expect(request.cleanUpSource == nil && request.cleanUpSerial == 2)
    }

    @Test func theStandardSidebarIsSlim() {
        let standard = SidebarCustomization.standard
        #expect(standard.pinned == [.library, .favorites, .memories, .people, .places])
        #expect(standard.utilities == SidebarLayout.utilities)
        #expect(standard.hidden.isEmpty && standard.isStandard)
        #expect(SidebarCustomization(stored: "") == .standard)
        #expect(SidebarCustomization(stored: "nonsense") == .standard)
    }

    @Test func pinUnpinHideAndReorder() {
        var value = SidebarCustomization.standard
        value.pin(.folders)
        #expect(value.pinned.last == .folders && !value.utilities.contains(.folders))
        value.unpin(.favorites)
        #expect(!value.pinned.contains(.favorites) && value.utilities.first == .favorites)
        // Library always stays: not unpinned, not hidden.
        value.unpin(.library)
        value.setHidden(.library, true)
        #expect(value.pinned.contains(.library) && !value.isHidden(.library))
        value.setHidden(.stickers, true)
        #expect(value.shownUtilities(visible: { _ in true }).contains(.stickers) == false)
        value.setHidden(.sharedAlbums, true)
        #expect(value.shownAlbumRows(visible: { _ in true }) == [.albums])
        value.movePinned(fromOffsets: IndexSet(integer: 0), toOffset: value.pinned.count)
        #expect(value.pinned.last == .library)
        // Albums and Shared stay in their group: they cannot be pinned.
        value.pin(.albums)
        #expect(!value.pinned.contains(.albums))
        #expect(!value.isStandard)
    }

    @Test func theCustomizationSurvivesStorageAndDropsUnknownRows() {
        var value = SidebarCustomization.standard
        value.pin(.insights)
        value.setHidden(.memories, true)
        #expect(SidebarCustomization(stored: value.stored) == value)
        let other = #"{"pinned":["places","photos","teleporter","places"],"hidden":["library","tags","teleporter"]}"#
        let read = SidebarCustomization(stored: other)
        // Photos is no row; Library comes back first; duplicates and unknown rows are dropped.
        #expect(read.pinned == [.library, .places])
        #expect(read.hidden == [.tags])
    }

    @Test func pinnedAlbumsComeFirstThenUsedAndRecent() {
        func album(_ name: String, modified: TimeInterval) -> Album {
            Album(kind: .own, name: name, lastModified: Date(timeIntervalSince1970: modified))
        }
        let albums = (1...12).map { album("A\($0)", modified: TimeInterval($0)) }
        let picked = SidebarAlbums.pick(albums, pinned: ["own:A1", "own:Gone"], used: ["own:A2"])
        #expect(picked.count == SidebarAlbums.limit)
        #expect(picked.prefix(3).map(\.name) == ["A1", "A2", "A12"])
        #expect(SidebarAlbums.toggling("x", in: ["a"]) == ["a", "x"])
        #expect(SidebarAlbums.toggling("a", in: ["a", "x"]) == ["x"])
        #expect(SidebarAlbums.decode(SidebarAlbums.encode(["a", "b"])) == ["a", "b"])
        #expect(SidebarAlbums.decode("garbage").isEmpty)
    }

    @Test func accountInitials() {
        #expect(AccountInitials.of("Frank Karlitschek") == "FK")
        #expect(AccountInitials.of("admin") == "A")
        #expect(AccountInitials.of("jane.doe@example.com") == "JD")
        #expect(AccountInitials.of("  ") == "?")
    }

    @MainActor @Test func goMenuKeepsItsShortcutsAndEveryPlace() {
        #expect(PhotosCommands.goShortcut(.library) == "1")
        #expect(PhotosCommands.goShortcut(.photos) == "2")
        #expect(PhotosCommands.goShortcut(.map) == "6")
        #expect(PhotosCommands.goShortcut(.smartAlbums) == "9")
        #expect(PhotosCommands.goShortcut(.people) == nil)
        for destination in SidebarLayout.rows + [.photos, .videos, .map, .smartAlbums, .sharedWithYou, .duplicates, .freeSpace] {
            #expect(PhotosCommands.goItems.contains(destination), "\(destination) is not in the Go menu")
        }
    }
}
