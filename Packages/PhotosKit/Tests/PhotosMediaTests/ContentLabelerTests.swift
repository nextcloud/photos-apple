// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import Testing

@testable import PhotosMedia
@testable import PhotosModel
@testable import PhotosStore

/// On-device labels from cached previews (SPEC SR-3).
@Suite struct ContentLabelerTests {
    @Test func wordsAreTheMostConfidentIdentifiersOnce() {
        let words = ContentLabeler.words([("animal", 0.5), ("sports_car", 0.9), ("Dog", 0.7), ("dog", 0.6), ("", 0.99)])
        #expect(words == ["sports car", "dog", "animal"])
        let many = (0..<30).map { (identifier: "label\($0)", confidence: Float($0)) }
        #expect(ContentLabeler.words(many).count == ContentLabeler.maximumLabels)
    }

    /// A plain grey square: Vision runs on it, whatever it makes of it.
    static func image() -> CGImage {
        let context = CGContext(
            data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        return context.makeImage()!
    }

    /// Only photos whose preview is cached are looked at; nothing is downloaded. Each one is looked at once per version.
    @Test(.disabled(if: TestEnvironment.isSimulator, TestEnvironment.noVision)) func labelsOnlyCachedPreviewsOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "photos-labeler-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AccountDatabase.temporary()
        try LibraryStore(database: database).upsert([
            MediaItem(fileId: 1, path: "/Photos/a.jpg", mimeType: "image/jpeg", etag: "e1"),
            MediaItem(fileId: 2, path: "/Photos/b.jpg", mimeType: "image/jpeg", etag: "e2"),
        ])
        let cache = PreviewCache(directory: directory)
        cache.store(Self.image(), fileId: 1, etag: "e1", bucket: 256)
        // A preview of an older version does not count.
        cache.store(Self.image(), fileId: 2, etag: "old", bucket: 256)

        let labeler = ContentLabeler(database: database, cache: cache)
        #expect(try await labeler.run() == 1)
        #expect(try LabelStore(database: database).visionProgress() == (labeled: 1, total: 2))
        // Nothing new to do: a second run looks at nothing again.
        #expect(try await labeler.run() == 0)
        // Stopped by the system right away: nothing is done.
        cache.store(Self.image(), fileId: 2, etag: "e2", bucket: 1024)
        #expect(try await labeler.run(shouldContinue: { false }) == 0)
        #expect(try await labeler.run() == 1)
    }
}
