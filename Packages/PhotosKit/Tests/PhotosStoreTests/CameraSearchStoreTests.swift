// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import Testing

@testable import PhotosDomain
@testable import PhotosModel
@testable import PhotosStore

/// Camera and lens chips answered by the one table of camera data (`photoExif`; SPEC §22.3).
@Suite(.timeLimit(.minutes(5))) struct CameraSearchStoreTests {
    let database: AccountDatabase
    let library: LibraryStore

    init() throws {
        database = try AccountDatabase.temporary()
        library = LibraryStore(database: database)
        try library.upsert([
            MediaItem(fileId: 1, path: "/Photos/Lisbon/DSCF0001.jpg", mimeType: "image/jpeg", etag: "e1", place: "Lisbon"),
            MediaItem(fileId: 2, path: "/Photos/Lisbon/DSCF0002.jpg", mimeType: "image/jpeg", etag: "e2", place: "Porto"),
            MediaItem(fileId: 3, path: "/Photos/IMG_0003.jpg", mimeType: "image/jpeg", etag: "e3", place: "Lisbon"),
        ])
        try InsightsStore(database: database).store([
            1: ("e1", ExifFacts(camera: "Fujifilm X100V", lens: "XF23mmF2 R WR")),
            2: ("e2", ExifFacts(camera: "Fujifilm X100V")),
            3: ("e3", ExifFacts(camera: "iPhone 15 Pro")),
        ])
    }

    func search(_ filters: [SearchFilter]) async throws -> [FileID] {
        try await library.search(LibrarySearch(filters: filters)).map(\.fileId).sorted()
    }

    @Test func aCameraChipFindsItsPhotos() async throws {
        #expect(try await search([.camera("Fujifilm X100V")]) == [1, 2])
        // Two cameras: either. With a place: both.
        #expect(try await search([.camera("Fujifilm X100V"), .camera("iPhone 15 Pro")]) == [1, 2, 3])
        #expect(try await search([.camera("Fujifilm X100V"), .place("Lisbon")]) == [1])
        #expect(try await search([.lens("XF23mmF2 R WR")]) == [1])
        #expect(try await search([.camera("Leica Q3")]) == [])
    }

    @Test func theVocabularyIsMostUsedFirst() async throws {
        let vocabulary = try await InsightsStore(database: database).cameraVocabulary()
        #expect(vocabulary.cameras == ["Fujifilm X100V", "iPhone 15 Pro"])
        #expect(vocabulary.lenses == ["XF23mmF2 R WR"])
    }
}
