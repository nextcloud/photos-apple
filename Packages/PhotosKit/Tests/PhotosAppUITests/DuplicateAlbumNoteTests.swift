// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import PhotosCore
import PhotosModel
import PhotosNetworking
import Testing

@testable import PhotosAppUI

/// The album warning of Duplicates reads the albums from the local index only (SPEC §7.15).
@Suite struct DuplicateAlbumNoteTests {
    @Test @MainActor func namesTheAlbumsAndCountsTheUncheckedOnes() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "duplicate-note-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let services = try AccountServices(
            account: Account(serverURL: URL(string: "https://cloud.invalid")!, userId: "alice", loginName: "alice", displayName: "Alice"),
            appPassword: "x", http: HTTPClient(trustStore: TrustStore(directory: nil)),
            features: ServerFeatures(serverVersion: ServerVersion(major: 33)), userAgent: "tests", layout: StorageLayout(container: root),
            onUnauthorized: {})
        let kept = MediaItem(fileId: 1, path: "/Photos/a/cat.jpg", mimeType: "image/jpeg")
        let copy = MediaItem(fileId: 2, path: "/Photos/b/cat.jpg", mimeType: "image/jpeg")
        try services.library.upsert([kept, copy])
        let trip = Album(kind: .own, name: "Trip", itemCount: 1)
        let both = Album(kind: .own, name: "Both", itemCount: 2)
        let unopened = Album(kind: .own, name: "Unopened", itemCount: 5)
        let empty = Album(kind: .own, name: "Empty")
        for album in [trip, both, unopened, empty] { try services.collections.upsertAlbum(album) }
        try await services.database.writer.write { db in
            for (album, fileId) in [(trip, 2), (both, 1), (both, 2)] {
                try db.execute(
                    sql: "INSERT INTO albumItem(albumId, fileId, childName, origin, ownerPath, position) VALUES (?, ?, ?, 'user', NULL, 1)",
                    arguments: [album.id, fileId, "\(fileId)-cat.jpg"])
            }
            try db.execute(
                sql: "UPDATE album SET contentFetchedAt = 1 WHERE id IN (?, ?)", arguments: [trip.id, both.id])
        }
        let note = DuplicateAlbumNote.make(deleting: [copy], kept: kept, services: services)
        #expect(note.albums.map(\.name) == ["Trip"])
        #expect(note.unchecked == 1)
        #expect(note.canKeepMemberships)
        #expect(note.message?.contains("“Trip”") == true)
        await services.shutdown(closeDatabase: true)
    }
}
