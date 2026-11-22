// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosModel
@testable import PhotosStore

@Suite struct StoreTests {
    func item(
        _ id: FileID, _ time: Double, path: String = "/Photos/x.jpg", mime: String = "image/jpeg", favorite: Bool = false,
        hidden: Bool = false
    )
        -> MediaItem
    {
        MediaItem(
            fileId: id, path: path, mimeType: mime, etag: "e\(id)", modifiedAt: Date(timeIntervalSince1970: time),
            capturedAt: Date(timeIntervalSince1970: time),
            isFavorite: favorite, isLivePhotoVideo: hidden, isArchived: path.hasPrefix("/.archive/"))
    }

    @Test func timelineFiltersAndOrder() throws {
        let store = LibraryStore(database: try .temporary())
        try store.upsert([
            item(1, 100), item(2, 300, favorite: true), item(3, 200, mime: "video/mp4"),
            item(4, 250, mime: "video/quicktime", hidden: true),
            item(5, 400, path: "/.archive/Photos/a.jpg"), item(6, 500, path: "/Photos/WhatsApp/b.jpg"),
        ])
        #expect(try store.gridItems(.all).map(\.fileId) == [6, 2, 3, 1])
        #expect(try store.gridItems(.all, excludedFolders: ["/Photos/WhatsApp"]).map(\.fileId) == [2, 3, 1])
        #expect(try store.gridItems(.photos).map(\.fileId) == [6, 2, 1])
        #expect(try store.gridItems(.videos).map(\.fileId) == [3])
        #expect(try store.gridItems(.favorites).map(\.fileId) == [2])
        #expect(try store.gridItems(.archived).map(\.fileId) == [5])
    }

    @Test func roundTripsAllFields() throws {
        let store = LibraryStore(database: try .temporary())
        var original = item(7, 1000)
        original.latitude = 52.5
        original.longitude = 13.4
        original.place = "Berlin"
        original.livePhotoPeer = 8
        original.width = 4032
        original.height = 3024
        original.blurhash = "LdH:5y"
        original.permissions = Permissions(rawValue: "RGDNVW")
        try store.upsert([original])
        #expect(try store.item(7) == original)
    }

    @Test func outboxAppliesOptimistically() async throws {
        let database = try AccountDatabase.temporary()
        let store = LibraryStore(database: database)
        try store.upsert([item(1, 100)])
        try await database.writer.write { db in
            try Outbox.applyLocally(.favorite(fileId: 1, path: "/Photos/x.jpg", value: true), db: db)
        }
        #expect(try store.item(1)?.isFavorite == true)
        try await database.writer.write { db in
            try Outbox.applyLocally(.archive(fileId: 1, path: "/Photos/x.jpg"), db: db)
        }
        #expect(try store.gridItems(.all).isEmpty)
        #expect(try store.gridItems(.archived).count == 1)
    }
}
