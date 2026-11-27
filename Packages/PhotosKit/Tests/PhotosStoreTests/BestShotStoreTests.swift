// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosDomain
import PhotosModel
import Testing

@testable import PhotosStore

/// What the best-shot analysis stores, and how similar shots and bursts read it (SPEC §21.4).
@Suite struct BestShotStoreTests {
    let start = Date(timeIntervalSince1970: 1_750_000_000)

    func item(_ id: FileID, _ seconds: Double, etag: String? = nil) -> MediaItem {
        MediaItem(
            fileId: id, path: "/Photos/IMG_\(id).jpg", mimeType: "image/jpeg", size: 1000 * id, etag: etag ?? "e\(id)",
            modifiedAt: start.addingTimeInterval(seconds), capturedAt: start.addingTimeInterval(seconds),
            permissions: Permissions(rawValue: "RGDNVW"))
    }

    @Test func signalsArePerVersionOfTheFile() throws {
        let database = try AccountDatabase.temporary()
        try LibraryStore(database: database).upsert([item(1, 0), item(2, 1), item(3, 2)])
        let store = BestShotStore(database: database)
        #expect(try store.missing([3, 1, 2]).map(\.fileId) == [3, 1, 2])
        let sharp = BestShot.Signals(sharpness: 9, exposure: 0.9, faces: [.init(x: 0.1, y: 0.1, width: 0.2, height: 0.2, eyesOpen: 1)])
        try store.save([(.init(fileId: 1, etag: "e1"), sharp), (.init(fileId: 2, etag: "e2"), nil)])
        #expect(try store.signals(of: [1, 2, 3]) == [1: sharp])
        // A failed analysis is not asked for again; the photo not analysed is.
        #expect(try store.missing([1, 2, 3]).map(\.fileId) == [3])
        #expect(try store.count() == 1)
        // A new version of the file: analysed again, the old signals no longer count.
        try LibraryStore(database: database).upsert([item(1, 0, etag: "e1b")])
        #expect(try store.signals(of: [1]).isEmpty)
        #expect(try store.missing([1]).map(\.etag) == ["e1b"])
        // Rows go with their photos.
        try LibraryStore(database: database).delete([2])
        #expect(try database.writer.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM bestShot") } == 1)
        try store.deleteAll()
        #expect(try store.count() == 0)
    }

    @Test func similarShotsChooseByTheStoredSignals() async throws {
        let database = try AccountDatabase.temporary()
        try LibraryStore(database: database).upsert([item(1, 0), item(2, 2), item(3, 4)])
        let scene: [Int8] = [100, 0, 0, 0]
        try SimilarityStore(database: database).save(
            [1, 2, 3].map { id in
                (
                    candidate: SimilarityStore.Candidate(fileId: id, etag: "e\(id)"),
                    // Photo 1 has the best aesthetics score: the old rule would keep it.
                    analysis: SimilarityStore.Analysis(print: [1], sketch: scene, quality: id == 1 ? 0.9 : 0.1, isUtility: false)
                )
            })
        let store = BestShotStore(database: database)
        func signals(open: Float) -> BestShot.Signals {
            BestShot.Signals(sharpness: 8, exposure: 0.9, faces: [.init(x: 0.3, y: 0.3, width: 0.3, height: 0.3, eyesOpen: open)])
        }
        try store.save([
            (.init(fileId: 1, etag: "e1"), signals(open: 0.05)), (.init(fileId: 2, etag: "e2"), signals(open: 0.9)),
            (.init(fileId: 3, etag: "e3"), signals(open: 0.1)),
        ])
        let groups = try await SimilarityStore(database: database).similarShots()
        #expect(groups.count == 1)
        #expect(groups.first?.best == 2)
        #expect(groups.first?.reasons.first == .eyesOpen)
        #expect(groups.first?.analysed == 3)

        // The timeline's evidence reads the same rows.
        let evidence = StoredBurstEvidence(database: database)
        #expect(evidence.sketches(of: [1, 2, 9]).keys.sorted() == [1, 2])
        #expect(evidence.signals(of: [2, 9]) == [2: signals(open: 0.9)])
    }

    @Test func memoryCoversAreTheBestAnalysedPhotos() async throws {
        let database = try AccountDatabase.temporary()
        // A trip of ten photos, an hour apart.
        let items = (1...10).map { id in item(FileID(id), Double(id) * 3600) }
        try LibraryStore(database: database).upsert(items)
        let before = try await LibraryStore(database: database).memories()
        let trip = try #require(before.trips.first)
        // Nothing analysed: the algorithm's cover (the middle of the trip).
        #expect(trip.cover == 5 || trip.cover == 6)

        // Photo 2 has the best aesthetics score, photo 9 a better one but a blink: 2 is the cover.
        try SimilarityStore(database: database).save(
            [2, 9].map { id in
                (
                    candidate: SimilarityStore.Candidate(fileId: id, etag: "e\(id)"),
                    analysis: SimilarityStore.Analysis(print: [1], sketch: [1], quality: id == 2 ? 0.5 : 0.7, isUtility: false)
                )
            })
        try BestShotStore(database: database).save([
            (
                .init(fileId: 9, etag: "e9"),
                BestShot.Signals(sharpness: 8, exposure: 0.9, faces: [.init(x: 0.3, y: 0.3, width: 0.3, height: 0.3, eyesOpen: 0.05)])
            )
        ])
        let after = try await LibraryStore(database: database).memories()
        #expect(after.trips.first?.cover == 2)
        #expect(after.trips.first?.items == trip.items)
    }
}
