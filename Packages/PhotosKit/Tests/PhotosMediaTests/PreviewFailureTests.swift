// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import PhotosModel
import Testing

@testable import PhotosMedia

/// Photos without a server preview (SPEC §20.1): asked for again on the next sync, with a backoff — not on every scroll.
struct PreviewFailureLogTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func backoffGrowsAndStopsAtADay() {
        let steps: [TimeInterval] = (1...7).map { PreviewFailureLog.backoff(afterAttempts: $0) }
        #expect(steps == [120, 600, 3600, 21600, 86400, 86400, 86400])
    }

    @Test func aFailedFileWaitsForTheNextSyncAndItsBackoff() {
        var log = PreviewFailureLog()
        #expect(log.allowsRequest(fileId: 7, etag: "a", at: start))
        log.recordFailure(fileId: 7, etag: "a", at: start)
        #expect(log.hasNoPreview(fileId: 7, etag: "a"))
        // Neither time alone nor a sync alone.
        #expect(!log.allowsRequest(fileId: 7, etag: "a", at: start.addingTimeInterval(3600)))
        var synced = log
        synced.librarySynced()
        #expect(!synced.allowsRequest(fileId: 7, etag: "a", at: start.addingTimeInterval(60)))
        #expect(synced.allowsRequest(fileId: 7, etag: "a", at: start.addingTimeInterval(120)))
        // A second failure waits longer, and for another sync.
        synced.recordFailure(fileId: 7, etag: "a", at: start.addingTimeInterval(120))
        synced.librarySynced()
        #expect(!synced.allowsRequest(fileId: 7, etag: "a", at: start.addingTimeInterval(120 + 599)))
        #expect(synced.allowsRequest(fileId: 7, etag: "a", at: start.addingTimeInterval(120 + 600)))
    }

    @Test func aNewVersionOrASuccessIsAskedForAtOnce() {
        var log = PreviewFailureLog()
        log.recordFailure(fileId: 7, etag: "a", at: start)
        #expect(log.allowsRequest(fileId: 7, etag: "b", at: start))
        #expect(!log.hasNoPreview(fileId: 7, etag: "b"))
        #expect(log.allowsRequest(fileId: 8, etag: "a", at: start))
        log.recordSuccess(fileId: 7, etag: "a")
        #expect(log.allowsRequest(fileId: 7, etag: "a", at: start))
        #expect(!log.hasNoPreview(fileId: 7, etag: "a"))
    }

    @Test func remembersWhyAndLetsLowDataModeWaitOnlyForItsEnd() {
        var log = PreviewFailureLog()
        log.recordFailure(fileId: 7, etag: "a", reason: .tooLarge(bytes: 80_000_000), at: start)
        log.recordFailure(fileId: 8, etag: "a", reason: .lowDataMode, at: start)
        #expect(log.reason(fileId: 7, etag: "a") == .tooLarge(bytes: 80_000_000))
        #expect(log.reason(fileId: 9, etag: "a") == nil)
        // In Low Data Mode it waits like any other; when it ended, at once (no sync, no backoff).
        #expect(!log.allowsRequest(fileId: 8, etag: "a", isConstrained: true, at: start))
        #expect(log.allowsRequest(fileId: 8, etag: "a", isConstrained: false, at: start))
        #expect(!log.allowsRequest(fileId: 7, etag: "a", isConstrained: false, at: start))
    }

    @Test func staysBounded() {
        var log = PreviewFailureLog()
        for id in 0..<(PreviewFailureLog.capacity + 10) {
            log.recordFailure(fileId: FileID(id), etag: "e", at: start.addingTimeInterval(Double(id)))
        }
        #expect(log.count == PreviewFailureLog.capacity)
        // The oldest went first.
        #expect(!log.hasNoPreview(fileId: 0, etag: "e"))
        #expect(log.hasNoPreview(fileId: FileID(PreviewFailureLog.capacity + 9), etag: "e"))
    }
}

@Suite(.timeLimit(.minutes(1))) struct PreviewFailurePipelineTests {
    let server = PreviewStubServer()
    let directory = FileManager.default.temporaryDirectory.appending(path: "pipeline-\(UUID().uuidString)")

    func pipeline() -> ImagePipeline {
        let api = server.api
        return ImagePipeline(
            api: api, cache: PreviewCache(directory: directory.appending(path: "previews")),
            originals: OriginalStore(directory: directory.appending(path: "originals"), dav: api.dav))
    }

    func request(_ id: FileID, bucket: Int = 256) -> ImagePipeline.Request {
        ImagePipeline.Request(fileId: id, etag: "e\(id)", bucket: bucket)
    }

    @Test func aFileWithoutAPreviewIsNotAskedForAgainOnEveryShow() async {
        server.state.withLock { $0.missing = [5] }
        let pipeline = pipeline()
        #expect(await pipeline.preview(request(5)) == nil)
        #expect(server.started == [5])
        #expect(pipeline.hasNoPreview(fileId: 5, etag: "e5"))
        // Scrolling past it again, another size, a prefetch, a sync within the backoff: no request.
        #expect(await pipeline.preview(request(5)) == nil)
        #expect(await pipeline.preview(request(5, bucket: 1024)) == nil)
        await pipeline.prefetch([request(5)])
        pipeline.librarySynced()
        #expect(await pipeline.preview(request(5)) == nil)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(server.started == [5])
        // Other photos load as before.
        #expect(await pipeline.preview(request(6)) != nil)
        #expect(!pipeline.hasNoPreview(fileId: 6, etag: "e6"))
        // A new version of the file is asked for at once.
        #expect(await pipeline.preview(ImagePipeline.Request(fileId: 5, etag: "e5-new", bucket: 256)) == nil)
        #expect(server.started == [5, 6, 5])
    }
}
