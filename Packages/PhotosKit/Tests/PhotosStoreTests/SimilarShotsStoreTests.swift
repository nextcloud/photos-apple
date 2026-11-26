// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosDomain
import PhotosModel
import Testing

@testable import PhotosStore

/// Similar shots across the library from the stored sketches (Clean up, SPEC §19.3).
@Suite struct SimilarShotsStoreTests {
    @Test func seriesFromTheStoredSketches() async throws {
        let database = try AccountDatabase.temporary()
        let library = LibraryStore(database: database)
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        func item(_ id: FileID, _ seconds: Double, archived: Bool = false, permissions: String = "RGDNVW") -> MediaItem {
            MediaItem(
                fileId: id, path: "/Photos/IMG_\(id).jpg", mimeType: "image/jpeg", size: 1000 * id, etag: "e\(id)",
                modifiedAt: start.addingTimeInterval(seconds), capturedAt: start.addingTimeInterval(seconds),
                permissions: Permissions(rawValue: permissions), isArchived: archived)
        }
        try library.upsert([
            item(1, 0), item(2, 3), item(3, 6, permissions: "RGNVW"),
            // Archived photos are not offered.
            item(4, 7, archived: true),
            // Another scene.
            item(5, 30),
        ])
        let store = SimilarityStore(database: database)
        let scene: [Int8] = [100, 0, 0, 0]
        let analyses: [(SimilarityStore.Candidate, SimilarityStore.Analysis)] = [
            (.init(fileId: 1, etag: "e1"), .init(print: [1], sketch: scene, quality: 0.1, isUtility: false)),
            (.init(fileId: 2, etag: "e2"), .init(print: [1], sketch: [95, 30, 0, 0], quality: 0.8, isUtility: false)),
            (.init(fileId: 3, etag: "e3"), .init(print: [1], sketch: scene, quality: 0.2, isUtility: false)),
            (.init(fileId: 4, etag: "e4"), .init(print: [1], sketch: scene, quality: 0.9, isUtility: false)),
            (.init(fileId: 5, etag: "e5"), .init(print: [1], sketch: [0, 0, 100, 0], quality: 0.5, isUtility: false)),
        ]
        try store.save(analyses.map { (candidate: $0.0, analysis: $0.1) })

        let groups = try await store.similarShots()
        #expect(groups.count == 1)
        #expect(groups.first?.ids == [1, 2, 3])
        #expect(groups.first?.best == 2)
        #expect(groups.first?.others == [1], "the read-only shot is not offered")
        #expect(groups.first?.bytes == 1000)

        // A changed file's old sketch no longer counts.
        try library.upsert([MediaItem(fileId: 1, path: "/Photos/IMG_1.jpg", mimeType: "image/jpeg", size: 1000, etag: "e1b")])
        #expect(try await store.similarShots().isEmpty)
    }
}
