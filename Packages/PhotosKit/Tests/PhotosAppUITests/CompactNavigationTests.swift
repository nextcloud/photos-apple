// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosBackup
import PhotosDomain
import PhotosModel
import PhotosStore
import Testing

@testable import PhotosAppUI

/// Navigation with a tab bar only (iPhone, narrow iPad windows; SPEC §6.2): every place must be reachable.
@Suite struct CompactNavigationTests {
    @Test func iPhoneAlwaysAndNarrowWindowsUseTheCollectionsTab() {
        #expect(CompactNavigation.usesCollectionsTab(isPhone: true, isCompact: true))
        // A large iPhone in landscape is "regular", and still has no sidebar.
        #expect(CompactNavigation.usesCollectionsTab(isPhone: true, isCompact: false))
        #expect(CompactNavigation.usesCollectionsTab(isPhone: false, isCompact: true))
        #expect(!CompactNavigation.usesCollectionsTab(isPhone: false, isCompact: false))
    }

    @Test func everyDestinationIsATabOrReachedFromCollections() {
        let visible: (AppDestination) -> Bool = { _ in true }
        // With Advanced features on, every row is there.
        let listed = CompactNavigation.reachable(visible: visible, listed: visible)
        for destination in AppDestination.allCases {
            if CompactNavigation.tabs.contains(destination) {
                #expect(!listed.contains(destination), "\(destination) has a tab of its own")
            } else if CompactNavigation.sheets.contains(destination) {
                // Settings: a sheet from the account button (SPEC §19.2).
                #expect(!listed.contains(destination), "\(destination) is a sheet")
            } else if destination == .onThisDay {
                // The first section of Memories; reached by links, notifications and widgets.
                #expect(CompactNavigation.tab(for: destination) == .collections)
            } else {
                // Places without a row (Photos, Map, Smart albums…) open the row they belong to (SPEC §19.1).
                let row = SidebarLayout.entry(for: destination, visible: visible).destination
                #expect(listed.contains(row) || CompactNavigation.tabs.contains(row), "\(destination) cannot be reached on iPhone")
            }
        }
    }

    @Test func shelvesComeFirstThenTheUtilitiesWithBackup() {
        let all: (AppDestination) -> Bool = { _ in true }
        #expect(CompactNavigation.shelves(visible: all) == [.albums, .memories, .people, .places, .shared])
        #expect(CompactNavigation.destination(of: .albums, visible: all) == .albums)
        #expect(CompactNavigation.destination(of: .shared, visible: all) == .sharedAlbums)
        #expect(CompactNavigation.utilities(listed: all) == SidebarLayout.utilities + [.backup])
    }

    @Test func advancedPlacesStepBackFromTheList() {
        let all: (AppDestination) -> Bool = { _ in true }
        let off: (AppDestination) -> Bool = { AdvancedFeatures.lists($0, isOn: false) }
        let rows = CompactNavigation.utilities(listed: off)
        #expect(!rows.contains(.stickers))
        #expect(!rows.contains(.insights))
        #expect(rows.contains(.cleanUp) && rows.contains(.backup))
        // Still destinations: a link opens them in Collections.
        #expect(CompactNavigation.path(to: .stickers, routes: []) == [.destination("stickers")])
        #expect(CompactNavigation.reachable(visible: all, listed: all).isSuperset(of: [.stickers, .insights]))
    }

    @Test func placesTheServerDoesNotOfferAreLeftOut() {
        let hidden: Set<AppDestination> = [.people, .tags, .recentlyDeleted]
        let visible: (AppDestination) -> Bool = { !hidden.contains($0) }
        #expect(!CompactNavigation.shelves(visible: visible).contains(.people))
        let rows = CompactNavigation.utilities(listed: visible)
        #expect(hidden.isDisjoint(with: rows))
        // Without the Photos DAV API: Favorites alone on the first shelf, "Shared with you" stands for Shared.
        let noAlbums: (AppDestination) -> Bool = { !SidebarLayout.albums.contains($0) }
        #expect(CompactNavigation.destination(of: .albums, visible: noAlbums) == .favorites)
        #expect(CompactNavigation.destination(of: .shared, visible: noAlbums) == .sharedWithYou)
        let nothingShared: (AppDestination) -> Bool = { !SidebarLayout.albums.contains($0) && $0 != .sharedWithYou }
        #expect(!CompactNavigation.shelves(visible: nothingShared).contains(.shared))
    }

    @Test func shelfPeopleAreNamedFirstThenByPhotos() {
        let people = [
            Person(name: "17", itemCount: 900), Person(name: "Ada", itemCount: 12), Person(name: "Bo", itemCount: 40),
        ]
        #expect(CollectionsOverview.shelfPeople(people).map(\.name) == ["Bo", "Ada", "17"])
    }

    @Test func theMapCardHasRoomAroundThePhotos() {
        let city = MapRegion(minLatitude: 48.1, maxLatitude: 48.2, minLongitude: 11.5, maxLongitude: 11.6)
        let padded = CollectionsOverview.paddedRegion(city)
        #expect(padded.maxLatitude - padded.minLatitude >= 2)
        #expect(padded.minLatitude < 48.1 && padded.maxLongitude > 11.6)
        let world = MapRegion(minLatitude: -40, maxLatitude: 70, minLongitude: -120, maxLongitude: 150)
        let clamped = CollectionsOverview.paddedRegion(world)
        #expect(clamped.minLatitude >= -90 && clamped.maxLatitude <= 90)
        #expect(clamped.minLongitude >= -180 && clamped.maxLongitude <= 180)
    }

    @Test func theOverviewReloadsAfterASyncAndOnANewDay() {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let first = CollectionsOverview.LoadKey(.idle(lastSync: day), account: "a", now: day)
        #expect(first == CollectionsOverview.LoadKey(.idle(lastSync: day), account: "a", now: day.addingTimeInterval(60)))
        #expect(first != CollectionsOverview.LoadKey(.idle(lastSync: day.addingTimeInterval(5)), account: "a", now: day))
        #expect(first != CollectionsOverview.LoadKey(.idle(lastSync: day), account: "a", now: day.addingTimeInterval(86_400)))
        #expect(first != CollectionsOverview.LoadKey(.idle(lastSync: day), account: "b", now: day))
    }

    @Test func tabsKeepTheirOwnSelection() {
        #expect(CompactNavigation.tab(for: .library) == .library)
        #expect(CompactNavigation.tab(for: .search) == .search)
        #expect(CompactNavigation.tabs == [.library, .collections, .search])
        #expect(CompactNavigation.tab(for: .collections) == .collections)
        #expect(CompactNavigation.tab(for: .albums) == .collections)
        #expect(CompactNavigation.tab(for: .backup) == .collections)
    }

    @Test func deepLinkToAnAlbumOpensItInsideCollections() {
        // What `MainView.open(.album)` sets: the Albums destination with the album on its path.
        let path = CompactNavigation.path(to: .albums, routes: [.album(id: "own:Trip")])
        #expect(path == [.destination("albums"), .album(id: "own:Trip")])
        let place = CompactNavigation.place(of: path)
        #expect(place?.destination == .albums)
        #expect(place?.routes == [.album(id: "own:Trip")])
    }

    @Test func theListIsTheRootOfTheStack() {
        #expect(CompactNavigation.path(to: .collections, routes: []).isEmpty)
        #expect(CompactNavigation.place(of: [])?.destination == .collections)
        // Back from Places to the list.
        #expect(CompactNavigation.path(to: .places, routes: []) == [.destination("places")])
        // A tab of its own is never pushed in Collections.
        #expect(CompactNavigation.path(to: .library, routes: []).isEmpty)
    }

    @Test func anAlbumOpenedFromAShelfIsOnTheOverviewsPath() {
        let place = CompactNavigation.place(of: [.album(id: "own:Trip")])
        #expect(place?.destination == .collections)
        #expect(place?.routes == [.album(id: "own:Trip")])
        #expect(CompactNavigation.path(to: .collections, routes: [.person(name: "Ada")]) == [.person(name: "Ada")])
    }

    @Test func pathsTheStackCannotHaveAreIgnored() {
        #expect(CompactNavigation.place(of: [.destination("library")]) == nil)
        #expect(CompactNavigation.place(of: [.destination("collections")]) == nil)
        #expect(CompactNavigation.place(of: [.destination("nonsense")]) == nil)
    }

    @Test func aRestoredSnapshotKeepsTheAlbumButNotTheListEntry() {
        // The snapshot stores the destination itself ("albums"), so it is the same with a sidebar and a tab bar.
        let snapshot = NavigationSnapshot(destination: "albums", routes: [.destination("albums"), .album(id: "own:Trip")])
        #expect(snapshot.routes == [.album(id: "own:Trip")])
        #expect(NavigationSnapshot(stored: snapshot.stored) == snapshot)
    }

    @Test func backupRowSaysWhatBackupIsDoing() {
        var status = BackupStatus()
        #expect(BackupRowStatus.text(isAvailable: false, isEnabled: true, status: status) == nil)
        #expect(BackupRowStatus.text(isAvailable: true, isEnabled: false, status: status) == "Off")
        #expect(BackupRowStatus.text(isAvailable: true, isEnabled: true, status: status) == "On")
        status.pending = 12
        #expect(BackupRowStatus.text(isAvailable: true, isEnabled: true, status: status) == "12 waiting")
        status.phase = .uploading(done: 3, total: 15, current: "IMG_1.jpg")
        #expect(BackupRowStatus.text(isAvailable: true, isEnabled: true, status: status) == "3 of 15")
        status.phase = .upToDate
        #expect(BackupRowStatus.text(isAvailable: true, isEnabled: true, status: status) == "Up to date")
        status.phase = .failed("quota")
        #expect(BackupRowStatus.text(isAvailable: true, isEnabled: true, status: status) == "Needs attention")
        status.phase = .paused("Waiting for Wi-Fi")
        #expect(BackupRowStatus.text(isAvailable: true, isEnabled: true, status: status) == "Paused")
    }
}
