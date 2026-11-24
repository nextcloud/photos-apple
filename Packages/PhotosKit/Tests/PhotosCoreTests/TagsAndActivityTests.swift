// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosCore
@testable import PhotosModel
@testable import PhotosStore

/// Tag changes of a selection and the notification about new photos in a shared album.
@Suite struct TagsAndActivityTests {
    @Test func onlyItemsWhoseTagStateDiffersAreChanged() {
        let tag = SystemTag(id: 5, name: "Dog")
        let items = (1...3).map { MediaItem(fileId: FileID($0), path: "/Photos/\($0).jpg", mimeType: "image/jpeg") }
        let current: [FileID: Set<Int>] = [1: [5], 2: [7]]
        #expect(
            SessionModel.tagOperations(tag, on: items, assigned: true, current: current) == [
                .tag(TagChange(fileId: 2, tagId: 5, tagName: "Dog", assign: true)),
                .tag(TagChange(fileId: 3, tagId: 5, tagName: "Dog", assign: true)),
            ])
        #expect(
            SessionModel.tagOperations(tag, on: items, assigned: false, current: current) == [
                .tag(TagChange(fileId: 1, tagId: 5, tagName: "Dog", assign: false))
            ])
    }

    @Test func sharedAlbumNotificationOpensSharedAlbums() {
        let added = SharedAlbumNotifications.presentation(
            for: AlbumActivity(albumId: "shared:Trip (anna)", title: "Trip", ownerDisplayName: "Anna", added: 3))
        #expect(added.title == "Trip")
        #expect(added.body == "3 new photos")
        #expect(added.destination == "sharedAlbums")
        let one = SharedAlbumNotifications.presentation(for: AlbumActivity(albumId: "shared:Trip (anna)", title: "Trip", added: 1))
        #expect(one.body == "1 new photo")
        let new = SharedAlbumNotifications.presentation(
            for: AlbumActivity(albumId: "shared:Ski (anna)", title: "Ski", ownerDisplayName: "Anna", added: 2, isNewAlbum: true))
        #expect(new.body == "Anna shared the album with you.")
    }
}
