// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import Testing

@testable import PhotosModel
@testable import PhotosNetworking
@testable import PhotosStore

/// Album titles in search (SPEC SR-3).
@Suite(.timeLimit(.minutes(5))) struct AlbumSearchTests {
    let database: AccountDatabase
    let library: LibraryStore
    let collections: CollectionStore

    init() throws {
        database = try AccountDatabase.temporary()
        library = LibraryStore(database: database)
        collections = CollectionStore(database: database)
        try library.upsert([
            MediaItem(fileId: 1, path: "/Photos/IMG_0001.jpg", mimeType: "image/jpeg", etag: "e1"),
            MediaItem(fileId: 2, path: "/Photos/IMG_0002.jpg", mimeType: "image/jpeg", etag: "e2"),
            MediaItem(fileId: 3, path: "/Photos/IMG_0003.mov", mimeType: "video/quicktime", etag: "e3"),
        ])
    }

    func search(_ text: String) async throws -> [FileID] {
        try await library.search(LibrarySearch(texts: [text])).map(\.fileId).sorted()
    }

    static func child(_ item: MediaItem) -> MediaParser.CollectionChild {
        MediaParser.CollectionChild(item: item, childName: "\(item.fileId)-\(item.name)", origin: "user", ownerPath: nil)
    }

    func indexed(_ id: FileID) -> MediaItem {
        MediaItem(fileId: id, path: "/Photos/IMG_000\(id).jpg", mimeType: "image/jpeg", etag: "e\(id)")
    }

    /// A photo of another user, known only as the child of a shared album.
    func foreign(_ id: FileID, name: String, time: Double = 1000, place: String? = nil) -> MediaItem {
        MediaItem(
            fileId: id, path: "photos/me/sharedalbums/x/\(id)-\(name)", name: name, mimeType: "image/jpeg", etag: "f\(id)",
            modifiedAt: Date(timeIntervalSince1970: time), capturedAt: Date(timeIntervalSince1970: time), place: place,
            mountType: MediaItem.collectionChildMountType)
    }

    // MARK: Album titles in the index

    @Test func albumTitlesAreSearchable() async throws {
        try collections.upsertAlbum(Album(kind: .own, name: "Hawaii 2024"))
        try collections.replaceAlbumContent(albumId: "own:Hawaii 2024", children: [Self.child(indexed(1)), Self.child(indexed(2))])
        #expect(try await search("hawaii") == [1, 2])
        // Together with a file name, and in short words (scanned, not trigram-matched).
        #expect(try await search("hawaii 0002") == [2])
        #expect(try await search("20") == [1, 2])
        // A photo taken out of the album no longer matches.
        try collections.replaceAlbumContent(albumId: "own:Hawaii 2024", children: [Self.child(indexed(2))])
        #expect(try await search("hawaii") == [2])
        // Another title (a shared album's title changes with the listing): found under the new one only.
        var album = try #require(try collections.album(id: "own:Hawaii 2024"))
        album.title = "Big Island"
        try collections.upsertAlbum(album)
        #expect(try await search("hawaii") == [])
        #expect(try await search("island") == [2])
        // A deleted album takes its title out of the index.
        try collections.deleteAlbum(id: "own:Hawaii 2024")
        #expect(try await search("island") == [])
        #expect(try await search("0002") == [2])
    }

    @Test func sharedAlbumTitlesAreSearchablePublicLinksAreNot() async throws {
        try collections.replaceAlbums(
            [Album(kind: .shared, name: "Family (anna)", title: "Family", ownerId: "anna")], kind: .shared)
        try collections.replaceAlbumContent(albumId: "shared:Family (anna)", children: [Self.child(indexed(1))])
        #expect(try await search("family") == [1])
        // Not the owner suffix of the DAV name.
        #expect(try await search("anna") == [])
        try collections.upsertAlbum(Album(kind: .publicLink, name: "token123", title: "Wedding"))
        try collections.replaceAlbumContent(albumId: "publicLink:token123", children: [Self.child(indexed(2))])
        #expect(try await search("wedding") == [])
    }

    @Test func photosOfSharedAlbumsThatAreNotInTheIndexAreFound() async throws {
        try collections.replaceAlbums(
            [Album(kind: .shared, name: "Family (anna)", title: "Family", ownerId: "anna")], kind: .shared)
        try collections.replaceAlbumContent(
            albumId: "shared:Family (anna)",
            children: [
                Self.child(indexed(1)), Self.child(foreign(100, name: "beach.jpg", time: 5000, place: "Zürich")),
                Self.child(foreign(101, name: "dinner.jpg", time: 3000)),
            ])
        // By the album's title: the indexed photo and the two of the other user, newest first.
        #expect(try await library.search(LibrarySearch(texts: ["family"])).map(\.fileId) == [100, 101, 1])
        // By their own name or place (diacritics ignored), as indexed photos are.
        #expect(try await search("beach") == [100])
        #expect(try await search("zurich") == [100])
        #expect(try await search("family dinner") == [101])
        // By the album chip, with the other criteria applied to them too.
        #expect(try await library.search(LibrarySearch(albumIds: ["shared:Family (anna)"])).map(\.fileId) == [100, 101, 1])
        #expect(try await library.search(LibrarySearch(places: ["Zürich"], albumIds: ["shared:Family (anna)"])).map(\.fileId) == [100])
        let early = Date(timeIntervalSince1970: 0)..<Date(timeIntervalSince1970: 4000)
        #expect(try await library.search(LibrarySearch(texts: ["family"], dateRanges: [early])).map(\.fileId) == [101, 1].sorted(by: >))
        #expect(try await library.searchItems(LibrarySearch(texts: ["beach"])).map(\.fileId) == [100])
        // Searches without text or album stay in the library.
        #expect(try await library.search(LibrarySearch(places: ["Zürich"])).isEmpty)
    }

    @Test func albumTitlesSurviveARebuildOfTheIndex() async throws {
        try collections.upsertAlbum(Album(kind: .own, name: "Hawaii"))
        try collections.replaceAlbumContent(albumId: "own:Hawaii", children: [Self.child(indexed(1))])
        try library.deleteIndex()
        #expect(try await search("hawaii") == [])
        // The next sync writes the row again; the album's content stayed, and its title comes with it.
        try library.upsert([indexed(1)])
        #expect(try await search("hawaii") == [1])
        try collections.replaceAlbumContent(albumId: "own:Hawaii", children: [])
        #expect(try await search("hawaii") == [])
    }

    /// A database of the previous version: the photos already in albums become searchable by title in the migration.
    @Test func migratesADatabaseOfThePreviousVersion() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "photos-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let pool = try DatabasePool(path: url.path(percentEncoded: false))
        try AccountDatabase.migrator.migrate(pool, upTo: "v3-album-activity")
        try await pool.write { db in
            try MediaItem(fileId: 1, path: "/Photos/IMG_0001.jpg", mimeType: "image/jpeg", etag: "e1").insert(db)
            try db.execute(
                sql: "INSERT INTO album(id, kind, name, title) VALUES ('own:Hawaii', 'own', 'Hawaii', 'Hawaii')")
            try db.execute(sql: "INSERT INTO albumItem(albumId, fileId, childName) VALUES ('own:Hawaii', 1, '1-IMG_0001.jpg')")
        }
        try pool.close()

        let migrated = LibraryStore(database: try AccountDatabase(url: url))
        #expect(try await migrated.search(LibrarySearch(texts: ["hawaii"])).map(\.fileId) == [1])
        #expect(try await migrated.search(LibrarySearch(texts: ["img_0001"])).map(\.fileId) == [1])
    }
}
