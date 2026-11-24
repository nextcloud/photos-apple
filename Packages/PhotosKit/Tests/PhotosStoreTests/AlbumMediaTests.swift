// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosModel
@testable import PhotosNetworking
@testable import PhotosStore

/// Full items of an album for the Apple TV app (SPEC §15.3).
@Suite struct AlbumMediaTests {
    let collections: CollectionStore
    let library: LibraryStore

    init() throws {
        let database = try AccountDatabase.temporary()
        library = LibraryStore(database: database)
        collections = CollectionStore(database: database)
        try library.upsert([
            MediaItem(fileId: 1, path: "/Photos/a.jpg", mimeType: "image/jpeg", etag: "e1"),
            MediaItem(fileId: 2, path: "/Photos/b.jpg", mimeType: "image/jpeg", etag: "e2"),
        ])
    }

    static func child(_ item: MediaItem) -> MediaParser.CollectionChild {
        MediaParser.CollectionChild(item: item, childName: "\(item.fileId)-\(item.name)", origin: "user", ownerPath: nil)
    }

    @Test func albumItemsComeInAlbumOrderFromTheIndexAndTheAlbum() async throws {
        let foreign = MediaItem(
            fileId: 100, path: "photos/me/sharedalbums/x/100-c.jpg", name: "c.jpg", mimeType: "image/jpeg", etag: "f",
            mountType: MediaItem.collectionChildMountType)
        try collections.replaceAlbums([Album(kind: .shared, name: "Family (anna)", title: "Family", ownerId: "anna")], kind: .shared)
        let indexed2 = try #require(try library.item(2))
        let indexed1 = try #require(try library.item(1))
        try collections.replaceAlbumContent(
            albumId: "shared:Family (anna)", children: [Self.child(indexed2), Self.child(foreign), Self.child(indexed1)])
        let media = try await collections.albumMedia(albumId: "shared:Family (anna)")
        #expect(media.map(\.fileId) == [2, 100, 1])
        #expect(media.first?.etag == "e2")
        #expect(try await collections.albumMedia(albumId: "own:None").isEmpty)
    }

    @Test func oneItemIsFoundInTheIndexOrInAnAlbum() throws {
        let foreign = MediaItem(
            fileId: 200, path: "photos/me/sharedalbums/x/200-d.jpg", name: "d.jpg", mimeType: "image/jpeg", etag: "g",
            mountType: MediaItem.collectionChildMountType)
        try collections.replaceAlbums([Album(kind: .shared, name: "Trip (bob)", title: "Trip", ownerId: "bob")], kind: .shared)
        try collections.replaceAlbumContent(albumId: "shared:Trip (bob)", children: [Self.child(foreign)])
        #expect(try collections.mediaItem(fileId: 1)?.path == "/Photos/a.jpg")
        #expect(try collections.mediaItem(fileId: 200)?.name == "d.jpg")
        #expect(try collections.mediaItem(fileId: 999) == nil)
    }
}
