// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import PhotosModel
import Synchronization
import Testing

@testable import PhotosMedia

/// One cache key per photo (SPEC §18.1.1) and the viewer's loading ahead (SPEC §18.1.2).
@Suite(.timeLimit(.minutes(1))) struct LoadPathTests {
    let server = PreviewStubServer()
    let directory = FileManager.default.temporaryDirectory.appending(path: "loadpath-\(UUID().uuidString)")
    let metrics = CacheMetrics()

    func pipeline(network: Int = 6, local: Int = 2) -> ImagePipeline {
        let api = server.api
        return ImagePipeline(
            api: api, cache: PreviewCache(directory: directory.appending(path: "previews")),
            originals: OriginalStore(directory: directory.appending(path: "originals"), dav: api.dav),
            limits: ImagePipeline.Limits(network: network, local: local), metrics: metrics)
    }

    /// The grid's request: with the photo's ETag.
    func tile(_ id: FileID, bucket: Int = 256) -> ImagePipeline.Request {
        ImagePipeline.Request(fileId: id, etag: "e\(id)", bucket: bucket)
    }

    /// A cover's request: a file id only.
    func cover(_ id: FileID, bucket: Int = 256) -> ImagePipeline.Request {
        ImagePipeline.Request(fileId: id, etag: "", bucket: bucket)
    }

    func eventually(_ what: String, _ condition: @Sendable () async -> Bool) async {
        for _ in 0..<1000 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out waiting for: \(what)")
    }

    // MARK: One cache key per photo

    @Test func aCoverAfterTheGridIsADiskHit() async throws {
        let pipeline = pipeline()
        pipeline.setEtagProvider { id in id == 404 ? nil : "e\(id)" }
        #expect(await pipeline.preview(tile(5)) != nil)
        pipeline.cache.clearMemory()
        #expect(await pipeline.preview(cover(5)) != nil)
        // Not downloaded again: the cover read the grid's file.
        #expect(server.started == [5])
        #expect(metrics.snapshot().layer(.disk)?.demand == [0, 1, 0, 0])
        // And from memory once it is decoded, under the same key as the tile.
        #expect(pipeline.cache.memoryImage(fileId: 5, etag: "e5", bucket: 256) != nil)
        #expect(pipeline.displayedEtag(fileId: 5, etag: "") == "e5")
        #expect(pipeline.cache.bestMemoryImage(fileId: 5, etag: pipeline.displayedEtag(fileId: 5, etag: ""), upTo: 1024) != nil)
        // The other way round: the grid finds what a cover loaded.
        #expect(await pipeline.preview(cover(6)) != nil)
        pipeline.cache.clearMemory()
        #expect(await pipeline.preview(tile(6)) != nil)
        #expect(server.started == [5, 6])
        // A file the library does not know keeps a key of its own.
        #expect(await pipeline.preview(cover(404)) != nil)
        #expect(pipeline.cache.hasDiskImage(fileId: 404, etag: "", bucket: 256))
    }

    @Test func withoutTheLibraryACoverIsDownloadedAgain() async throws {
        // What happened before SPEC §18.1.1 (and still happens for public albums, which have no library).
        let pipeline = pipeline()
        #expect(await pipeline.preview(tile(5)) != nil)
        pipeline.cache.clearMemory()
        #expect(await pipeline.preview(cover(5)) != nil)
        #expect(server.started == [5, 5])
    }

    @Test func requestsWithAnETagAreNotLookedUp() {
        let pipeline = pipeline()
        let lookups = EtagLookupCounter()
        pipeline.setEtagProvider { id in
            lookups.increment()
            return "library-\(id)"
        }
        #expect(pipeline.resolved(tile(3)).etag == "e3")
        #expect(lookups.value == 0)
        #expect(pipeline.resolved(cover(3)).etag == "library-3")
        #expect(lookups.value == 1)
    }

    // MARK: Viewer neighbours

    @Test func neighboursInTheDirectionOfPagingFirst() {
        #expect(ViewerPrefetchPlan.neighbours(of: 5, count: 10, direction: 1) == [6, 7, 4, 3])
        #expect(ViewerPrefetchPlan.neighbours(of: 5, count: 10, direction: -1) == [4, 3, 6, 7])
        // At the ends only what exists.
        #expect(ViewerPrefetchPlan.neighbours(of: 0, count: 10, direction: -1) == [1, 2])
        #expect(ViewerPrefetchPlan.neighbours(of: 9, count: 10, direction: 1) == [8, 7])
        #expect(ViewerPrefetchPlan.neighbours(of: 0, count: 1, direction: 1) == [])
        #expect(ViewerPrefetchPlan.direction(from: nil, to: 4) == 1)
        #expect(ViewerPrefetchPlan.direction(from: 5, to: 4) == -1)
        #expect(ViewerPrefetchPlan.direction(from: 3, to: 4) == 1)
    }

    @Test func theLargePreviewOnlyOnAnInexpensiveNetwork() {
        #expect(ViewerPrefetchPlan.loadsDetail(isExpensive: false, isConstrained: false, isLowPower: false))
        #expect(!ViewerPrefetchPlan.loadsDetail(isExpensive: true, isConstrained: false, isLowPower: false))
        #expect(!ViewerPrefetchPlan.loadsDetail(isExpensive: false, isConstrained: true, isLowPower: false))
        #expect(!ViewerPrefetchPlan.loadsDetail(isExpensive: false, isConstrained: false, isLowPower: true))
    }

    @Test func neighboursLoadInOrderAfterThePhotoShownAndCanBeTakenBack() async throws {
        let pipeline = pipeline(network: 1)
        server.hold()
        // The photo shown (20) is waited for; its neighbours 21, 22, 19, 18 are prefetched, most wanted last.
        let shown = Task { await pipeline.preview(tile(20, bucket: 1024)) }
        await eventually("the photo shown") { server.started == [20] }
        let plan: [FileID] = ViewerPrefetchPlan.neighbours(of: 20, count: 100, direction: 1).map(FileID.init)
        await pipeline.prefetch(plan.reversed().map { tile($0, bucket: 1024) }, decode: true)
        // Paging back before they start: 18 is no neighbour any more.
        await pipeline.cancelPrefetch(for: [tile(18, bucket: 1024)])
        server.release()
        #expect(await shown.value != nil)
        await eventually("the neighbours") { Set(server.answered) == [20, 21, 22, 19] }
        #expect(server.started == [20, 21, 22, 19])
        await eventually("an empty pipeline") { await pipeline.pendingLoadCount == 0 }
        // Decoded into memory: paging to them shows them at once.
        #expect(pipeline.cache.memoryImage(fileId: 21, etag: "e21", bucket: 1024) != nil)
        #expect(metrics.snapshot().layer(.network)?.prefetch == [0, 0, 3, 0])
    }

    @Test func neighboursOnDiskAreDecodedIntoMemoryOnlyWhenAskedTo() async throws {
        let pipeline = pipeline()
        for id: FileID in [1, 2] { #expect(await pipeline.preview(tile(id, bucket: 1024)) != nil) }
        pipeline.cache.clearMemory()
        // The grid's prefetch leaves what is on disk there.
        await pipeline.prefetch([tile(1, bucket: 1024)])
        try await Task.sleep(for: .milliseconds(50))
        #expect(pipeline.cache.memoryImage(fileId: 1, etag: "e1", bucket: 1024) == nil)
        // The viewer's decodes it, without the network.
        await pipeline.prefetch([tile(1, bucket: 1024), tile(2, bucket: 1024)], decode: true)
        await eventually("decoded neighbours") {
            pipeline.cache.memoryImage(fileId: 1, etag: "e1", bucket: 1024) != nil
                && pipeline.cache.memoryImage(fileId: 2, etag: "e2", bucket: 1024) != nil
        }
        #expect(server.started == [1, 2])
        #expect(metrics.snapshot().layer(.disk)?.prefetch == [0, 0, 2, 0])
        await eventually("an empty pipeline") { await pipeline.pendingLoadCount == 0 }
    }

    @Test func aDecodePrefetchThatComesOnScreenIsWaitedFor() async throws {
        // One local slot, busy: the prefetch waits in the local lane until the page is shown and asks for it.
        let pipeline = pipeline(local: 1)
        #expect(await pipeline.preview(tile(1, bucket: 1024)) != nil)
        pipeline.cache.clearMemory()
        await pipeline.prefetch([tile(1, bucket: 1024)], decode: true)
        #expect(await pipeline.preview(tile(1, bucket: 1024)) != nil)
        await eventually("an empty pipeline") { await pipeline.pendingLoadCount == 0 }
        #expect(server.started == [1])
    }

    @Test func thePlaceholderIsTheBestSmallerPictureOnTheDevice() async throws {
        let pipeline = pipeline()
        pipeline.setEtagProvider { "e\($0)" }
        // Nothing on the device: no placeholder, and nothing is downloaded for it.
        #expect(await pipeline.placeholder(for: tile(9, bucket: 1024)) == nil)
        #expect(server.started.isEmpty)
        // The grid's 256 px tile on disk is the viewer's placeholder while 1024 px loads.
        #expect(await pipeline.preview(tile(9, bucket: 256)) != nil)
        pipeline.cache.clearMemory()
        #expect(await pipeline.placeholder(for: tile(9, bucket: 1024)) != nil)
        // Now in memory: found there, also for a request without an ETag.
        #expect(await pipeline.placeholder(for: cover(9, bucket: 1024)) != nil)
        // Never the size asked for or a larger one: that is the preview itself.
        #expect(await pipeline.placeholder(for: tile(9, bucket: 64)) == nil)
        #expect(server.started == [9])
    }
}

/// Counts calls from any thread.
final class EtagLookupCounter: Sendable {
    private let count = Mutex(0)
    func increment() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}
