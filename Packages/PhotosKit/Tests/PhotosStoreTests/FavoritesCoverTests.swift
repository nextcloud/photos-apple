// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosModel
@testable import PhotosStore

/// The Favorites card's cover: the newest favourite, followed live, nil without favourites (SPEC §20.1).
@Suite(.timeLimit(.minutes(1))) struct FavoritesCoverTests {
    let database: AccountDatabase
    let library: LibraryStore

    init() throws {
        database = try AccountDatabase.temporary()
        library = LibraryStore(database: database)
    }

    func item(_ id: Int, favorite: Bool, at seconds: Double, path: String? = nil, archived: Bool = false) -> MediaItem {
        var item = MediaItem(
            fileId: FileID(id), path: path ?? "/Photos/IMG_\(id).jpg", mimeType: "image/jpeg", etag: "e\(id)",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000 + seconds), isFavorite: favorite)
        item.isArchived = archived
        return item
    }

    @Test func theNewestFavouriteFollowsTheIndex() async throws {
        try library.upsert([item(1, favorite: false, at: 300), item(2, favorite: true, at: 100), item(3, favorite: false, at: 200)])
        var newest = library.observeNewest(.favorites).makeAsyncIterator()
        #expect(try await newest.next()??.fileId == 2)
        // A newer photo becomes a favourite: it is the cover.
        try library.upsert([item(3, favorite: true, at: 200)])
        #expect(try await newest.next()??.fileId == 3)
        // No favourites left: no cover (the card's gradient).
        try library.upsert([item(2, favorite: false, at: 100), item(3, favorite: false, at: 200)])
        #expect(try await newest.next() == .some(nil))
    }

    @Test func hiddenFoldersAndTheArchiveAreLeftOut() async throws {
        try library.upsert([
            item(1, favorite: true, at: 100), item(2, favorite: true, at: 300, path: "/Hidden/IMG_2.jpg"),
            item(3, favorite: true, at: 400, archived: true),
        ])
        var newest = library.observeNewest(.favorites, excludedFolders: ["/Hidden"]).makeAsyncIterator()
        #expect(try await newest.next()??.fileId == 1)
    }
}
