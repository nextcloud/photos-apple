// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel
import PhotosStore
import Testing

@testable import PhotosAppUI

/// The tag sheet's marks, the first sync's "N of M" and the wording of shared-album activity.
@Suite struct TagsAndActivityTextTests {
    @Test func tagMarks() {
        #expect(TagMark(count: 0, of: 3) == .none)
        #expect(TagMark(count: 2, of: 3) == .some)
        #expect(TagMark(count: 3, of: 3) == .all)
        // Tapping a tag on some or none of the photos gives it to all; on all of them it takes it off.
        #expect(TagMark.none.assignsOnTap && TagMark.some.assignsOnTap && !TagMark.all.assignsOnTap)
    }

    @Test func initialSyncProgress() {
        let n = 12_000.formatted()
        let m = 48_213.formatted()
        #expect(InitialSyncProgress.text(count: 12_000, total: 48_213) == "Loading your library — \(n) of \(m)")
        // Stock servers tell no total.
        #expect(InitialSyncProgress.text(count: 12_000, total: nil) == "Loading your library — \(n)")
        // The day counts leave out shared folders: once more arrived than they promised, no total is claimed.
        #expect(InitialSyncProgress.text(count: 50_000, total: 48_213) == "Loading your library — \(50_000.formatted())")
        #expect(InitialSyncProgress.text(count: 0, total: 48_213) == "Loading your library — 0 of \(m)")
        #expect(InitialSyncProgress.text(count: 0, total: nil) == "Loading your library…")
    }

    @Test func activityWording() {
        let trip = AlbumActivity(albumId: "shared:Trip (anna)", title: "Trip", ownerDisplayName: "Anna", added: 1)
        let party = AlbumActivity(albumId: "shared:Party (bob)", title: "Party", ownerDisplayName: "Bob", added: 4)
        let new = AlbumActivity(albumId: "shared:Ski (anna)", title: "Ski", ownerDisplayName: "Anna", added: 7, isNewAlbum: true)
        #expect(AlbumActivityText.summary([trip]) == "1 new photo in “Trip”")
        #expect(AlbumActivityText.summary([party]) == "4 new photos in “Party”")
        #expect(AlbumActivityText.summary([trip, party]) == "5 new photos in 2 albums")
        #expect(AlbumActivityText.summary([new]) == "“Ski” was shared with you")
        #expect(AlbumActivityText.detail(trip) == "1 new photo")
        #expect(AlbumActivityText.detail(new) == "Shared with you by Anna")
    }
}
