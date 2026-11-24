// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import PhotosDomain
import Testing

@testable import PhotosMedia
@testable import PhotosModel
@testable import PhotosStore

/// "Show Similar": cached previews are indexed with Vision, once per version, and searched (SPEC §15.5).
@Suite struct SimilarityIndexTests {
    /// A picture with a few shapes; `variant` shifts them a little (another shot of the same scene), `seed` makes
    /// another scene.
    static func image(seed: Int, variant: Int = 0) -> CGImage {
        let side = 256
        let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        var state = UInt64(seed + 1) &* 0x9E37_79B9_7F4A_7C15
        func next() -> CGFloat {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return CGFloat(state >> 11) / CGFloat(1 << 53)
        }
        context.setFillColor(CGColor(red: next(), green: next(), blue: next(), alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        for _ in 0..<6 {
            context.setFillColor(CGColor(red: next(), green: next(), blue: next(), alpha: 1))
            let rect = CGRect(x: next() * 200 + CGFloat(variant * 3), y: next() * 200, width: 30 + next() * 80, height: 30 + next() * 80)
            if next() > 0.5 { context.fillEllipse(in: rect) } else { context.fill(rect) }
        }
        return context.makeImage()!
    }

    @Test func indexesCachedPreviewsOnceAndFindsTheSameScene() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "photos-similar-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AccountDatabase.temporary()
        let items = (1...8).map { MediaItem(fileId: FileID($0), path: "/Photos/\($0).jpg", mimeType: "image/jpeg", etag: "e\($0)") }
        try LibraryStore(database: database).upsert(items)
        let cache = PreviewCache(directory: directory)
        // 1 and 2: the same scene; 3…7 other scenes; 8 not cached.
        cache.store(Self.image(seed: 1), fileId: 1, etag: "e1", bucket: 256)
        cache.store(Self.image(seed: 1, variant: 1), fileId: 2, etag: "e2", bucket: 256)
        for id in 3...7 { cache.store(Self.image(seed: id * 17), fileId: FileID(id), etag: "e\(id)", bucket: 256) }

        let index = SimilarityIndex(database: database)
        let indexer = SimilarityIndexer(database: database, cache: cache, index: index)
        #expect(try await indexer.run() == 7)
        #expect(await index.count == 7)
        // Incremental: nothing new, nothing done.
        #expect(try await indexer.run() == 0)
        // Stopped right away: nothing is done.
        try LibraryStore(database: database).upsert([MediaItem(fileId: 3, path: "/Photos/3.jpg", mimeType: "image/jpeg", etag: "e3b")])
        #expect(try await indexer.run(shouldContinue: { false }) == 0)

        let store = SimilarityStore(database: database)
        let print = try #require(try store.prints(of: [1])[1])
        #expect(print.count == 768)
        let matches = try await index.similar(to: print, excluding: 1, threshold: -1)
        #expect(matches.first?.fileId == 2)
        #expect(!matches.contains { $0.fileId == 1 })
        #expect((matches.first?.similarity ?? 0) > (matches.last?.similarity ?? 1))

        // A fresh index (a new launch) loads what is stored.
        let reloaded = SimilarityIndex(database: database)
        try await reloaded.refresh()
        // Photo 3 has a new version: its old sketch no longer counts.
        #expect(await reloaded.count == 6)

        // The print of a photo that was never indexed is worked out on demand.
        let onDemand = try await reloaded.featurePrint(of: .init(fileId: 8, etag: "e8")) { Self.image(seed: 1) }
        #expect(onDemand?.count == 768)
        #expect(await reloaded.count == 7)
        #expect(try store.prints(of: [8])[8] == onDemand)
        let vectors = await reloaded.vectors(of: [1, 8, 99])
        #expect(vectors.keys.sorted() == [1, 8])
    }
}
