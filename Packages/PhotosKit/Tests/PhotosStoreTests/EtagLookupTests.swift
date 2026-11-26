// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosModel
@testable import PhotosNetworking
@testable import PhotosStore

/// The ETag lookup behind one cache key per photo (SPEC §18.1.1).
@Suite struct EtagLookupTests {
    @Test func etagsOfIndexedAndAlbumOnlyFiles() throws {
        let database = try AccountDatabase.temporary()
        let library = LibraryStore(database: database)
        let collections = CollectionStore(database: database)
        try library.upsert([MediaItem(fileId: 1, path: "/Photos/a.jpg", mimeType: "image/jpeg", etag: "e1")])
        let foreign = MediaItem(
            fileId: 300, path: "photos/me/sharedalbums/x/300-c.jpg", name: "c.jpg", mimeType: "image/jpeg", etag: "f300",
            mountType: MediaItem.collectionChildMountType)
        try collections.replaceAlbums([Album(kind: .shared, name: "Trip (bob)", title: "Trip", ownerId: "bob")], kind: .shared)
        try collections.replaceAlbumContent(
            albumId: "shared:Trip (bob)",
            children: [MediaParser.CollectionChild(item: foreign, childName: "300-c.jpg", origin: "user", ownerPath: nil)])
        #expect(try library.etag(of: 1) == "e1")
        #expect(try library.etag(of: 300) == "f300")
        #expect(try library.etag(of: 999) == nil)
    }
}
