// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import Synchronization
import Testing

@testable import PhotosDomain
@testable import PhotosMedia
@testable import PhotosModel
@testable import PhotosStore

/// Photo descriptions written on the device from cached previews (SPEC §16.2).
@Suite(.timeLimit(.minutes(5))) struct PhotoDescriberTests {
    /// A grey 2×2 PNG: decoding it needs no GPU.
    static let png = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAAAAABX3VL4AAAADklEQVR4nGNoaGBoaAAABgYCASzBUNcAAAAASUVORK5CYII=")!

    func makeLibrary() throws -> (AccountDatabase, PreviewCache, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "photos-describer-\(UUID().uuidString)")
        let database = try AccountDatabase.temporary()
        try LibraryStore(database: database).upsert([
            MediaItem(fileId: 1, path: "/Photos/a.jpg", mimeType: "image/jpeg", etag: "e1"),
            MediaItem(fileId: 2, path: "/Photos/b.jpg", mimeType: "image/jpeg", etag: "e2"),
            MediaItem(fileId: 3, path: "/Photos/c.jpg", mimeType: "image/jpeg", etag: "e3"),
        ])
        return (database, PreviewCache(directory: directory), directory)
    }

    /// Only photos whose preview is cached are described, once per version; the lookup sees the new text at once.
    @Test func describesOnlyCachedPreviewsOnce() async throws {
        let (database, cache, directory) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        cache.store(Self.png, fileId: 1, etag: "e1", bucket: 256)
        cache.store(Self.png, fileId: 3, etag: "e3", bucket: 1024)
        // A preview of an older version does not count.
        cache.store(Self.png, fileId: 2, etag: "old", bucket: 256)
        let lookup = PhotoDescriptionLookup(database: database)
        #expect(lookup.text(of: 1, language: "en") == nil)
        let indexer = PhotoDescriptionIndexer(database: database, cache: cache, lookup: lookup)
        let calls = Counter()
        let describe: @Sendable (CGImage) async throws -> PhotoDescriptionStore.Result = { _ in
            calls.increment()
            return PhotoDescriptionStore.Result(text: "A grey square", language: "en", source: .vision)
        }
        #expect(try await indexer.run(batchSize: 1, describe: describe) == 2)
        #expect(calls.value == 2)
        #expect(lookup.text(of: 1, language: "en") == "A grey square")
        #expect(try PhotoDescriptionStore(database: database).progress() == (described: 2, total: 3))
        // Nothing new: nothing is looked at again.
        #expect(try await indexer.run(describe: describe) == 0)
        // Stopped by the system right away: nothing is done.
        cache.store(Self.png, fileId: 2, etag: "e2", bucket: 256)
        #expect(try await indexer.run(shouldContinue: { false }, describe: describe) == 0)
        #expect(try await indexer.run(describe: describe) == 1)
    }

    /// A failing describer ends the run after three failures and stores nothing for them (tried again later).
    @Test func failuresAreTriedAgainLater() async throws {
        let (database, cache, directory) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        for id in 1...3 { cache.store(Self.png, fileId: FileID(id), etag: "e\(id)", bucket: 256) }
        struct Unavailable: Error {}
        let indexer = PhotoDescriptionIndexer(database: database, cache: cache)
        #expect(try await indexer.run(describe: { _ in throw Unavailable() }) == 0)
        #expect(try PhotoDescriptionStore(database: database).candidates(limit: 10).count == 3)
    }

    /// Real Vision on the Mac: a plain picture is analysed without error (it shows nothing worth a sentence).
    @Test(.disabled(if: TestEnvironment.isSimulator, TestEnvironment.noVision)) func visionLooksAtAPicture() async throws {
        let image = try #require(ImageDecoding.decode(data: Self.png, maxPixelSize: 64))
        let facts = try await PhotoDescriber.facts(in: image)
        #expect(facts.faceCount == 0)
        #expect(facts.text.isEmpty)
    }
}

/// Counts calls from any thread.
final class Counter: Sendable {
    private let count = Mutex(0)
    var value: Int { count.withLock { $0 } }
    func increment() { count.withLock { $0 += 1 } }
}
