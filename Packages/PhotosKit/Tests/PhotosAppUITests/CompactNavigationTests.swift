// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosBackup
import PhotosDomain
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

    @Test func everyDestinationIsATabOrListedInCollections() {
        let listed = Set(CompactNavigation.sections(visible: { _ in true }).flatMap(\.destinations))
        for destination in AppDestination.allCases {
            if CompactNavigation.tabs.contains(destination) {
                #expect(!listed.contains(destination), "\(destination) has a tab of its own")
            } else if destination == .onThisDay {
                // The first section of Memories; reached by links, notifications and widgets.
                #expect(CompactNavigation.tab(for: destination) == .collections)
            } else {
                #expect(listed.contains(destination), "\(destination) cannot be reached on iPhone")
                #expect(CompactNavigation.tab(for: destination) == .collections)
            }
        }
    }

    @Test func listFollowsTheSidebarAndEndsWithBackup() {
        let sections = CompactNavigation.sections(visible: { _ in true })
        #expect(sections.map(\.kind) == [.browse, .collections, .utilities])
        #expect(sections[0].destinations == [.photos, .videos, .favorites, .memories, .map])
        #expect(sections[1].destinations == SidebarLayout.collections)
        #expect(sections[2].destinations == SidebarLayout.utilities + [.backup])
    }

    @Test func placesTheServerDoesNotOfferAreLeftOut() {
        let hidden: Set<AppDestination> = [.people, .places, .tags, .recentlyDeleted]
        let sections = CompactNavigation.sections(visible: { !hidden.contains($0) })
        let listed = sections.flatMap(\.destinations)
        #expect(hidden.isDisjoint(with: listed))
        #expect(listed.contains(.albums))
        // A group without rows has no header either.
        let none = CompactNavigation.sections(visible: { !SidebarLayout.collections.contains($0) })
        #expect(none.map(\.kind) == [.browse, .utilities])
    }

    @Test func tabsKeepTheirOwnSelection() {
        #expect(CompactNavigation.tab(for: .library) == .library)
        #expect(CompactNavigation.tab(for: .search) == .search)
        #expect(CompactNavigation.tab(for: .settings) == .settings)
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

    @Test func pathsTheStackCannotHaveAreIgnored() {
        #expect(CompactNavigation.place(of: [.album(id: "own:Trip")]) == nil)
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
