// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import PhotosModel
import Testing

@testable import PhotosMedia

@Suite struct CacheMetricsTests {
    @Test func countsPerLayerAndBucketAndKeepsPrefetchesApart() {
        let metrics = CacheMetrics()
        metrics.record(.memory, bucket: 256)
        metrics.record(.memory, bucket: 256)
        metrics.record(.disk, bucket: 1024)
        metrics.record(.network, bucket: 1024)
        metrics.record(.network, bucket: 1024, prefetch: true)
        // Sizes between the buckets count as the next larger one.
        metrics.record(.disk, bucket: 2048)
        let snapshot = metrics.snapshot()
        #expect(snapshot.layer(.memory)?.demand == [0, 2, 0, 0])
        #expect(snapshot.layer(.disk)?.demand == [0, 0, 1, 1])
        #expect(snapshot.layer(.network)?.demand == [0, 0, 1, 0])
        #expect(snapshot.layer(.network)?.prefetch == [0, 0, 1, 0])
        // 4 of 5 waited-for previews came from the device; the prefetch does not count.
        #expect(snapshot.hitRate == 0.8)
        #expect(snapshot.hitRate(bucket: 1024) == 0.5)
        #expect(snapshot.hitRate(bucket: 64) == nil)
        metrics.reset()
        #expect(metrics.snapshot().hitRate == nil)
    }

    @Test func percentilesOverARingBuffer() {
        let metrics = CacheMetrics()
        for value in 1...100 { metrics.record(.viewerFull, milliseconds: Double(value)) }
        var times = metrics.snapshot().times(.viewerFull)
        #expect(times?.count == 100)
        #expect(times?.p50 == 50)
        #expect(times?.p95 == 95)
        #expect(metrics.snapshot().times(.tile)?.p50 == nil)
        // Only the newest samples are kept.
        for _ in 0..<CacheMetrics.sampleCapacity { metrics.record(.viewerFull, milliseconds: 7) }
        times = metrics.snapshot().times(.viewerFull)
        #expect(times?.p95 == 7)
        #expect(times?.count == 100 + CacheMetrics.sampleCapacity)
    }

    @Test func timersMeasureElapsedTime() async throws {
        let metrics = CacheMetrics()
        let timer = metrics.begin(.tile)
        try await Task.sleep(for: .milliseconds(20))
        metrics.finish(timer)
        let p50 = try #require(metrics.snapshot().times(.tile)?.p50)
        #expect(p50 >= 15 && p50 < 2000)
    }

    @Test func snapshotsRoundTripAsJSON() throws {
        let metrics = CacheMetrics()
        metrics.record(.smartOffline, bucket: 1024)
        metrics.record(.tile, milliseconds: 3)
        let file = FileManager.default.temporaryDirectory.appending(path: "metrics-\(UUID().uuidString)/m.json")
        metrics.write(to: file)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let read = try decoder.decode(CacheMetrics.Snapshot.self, from: Data(contentsOf: file))
        #expect(read.layer(.smartOffline)?.demand == [0, 0, 1, 0])
        #expect(read.times(.tile)?.p50 == 3)
    }

    @Test func usagePerBucketAndPool() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "usage-\(UUID().uuidString)")
        func write(_ path: String, bytes: Int) throws {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: bytes).write(to: url)
        }
        try write("Previews/12/112-abc-256.jpg", bytes: 100)
        try write("Previews/13/113-0-256.jpg", bytes: 50)
        try write("Previews/13/113-abc_e1f-1024.jpg", bytes: 1000)
        try write("Previews/14/114-abc-4096.heic", bytes: 4000)
        try write("SmartOffline/9-x.jpg", bytes: 300)
        try write("Offline/a.jpg", bytes: 7)
        let usage = CacheUsage.scan(
            previews: root.appending(path: "Previews"), smartOffline: root.appending(path: "SmartOffline"),
            offline: root.appending(path: "Offline"), originals: root.appending(path: "Originals"))
        #expect(usage.previewFiles == [0, 2, 1, 1])
        #expect(usage.previewBytes == [0, 150, 1000, 4000])
        #expect(usage.previewTotal == 5150)
        #expect(usage.smartOfflineBytes == 300)
        #expect(usage.smartOfflineFiles == 1)
        #expect(usage.offlineBytes == 7)
        #expect(usage.originalBytes == 0)
        #expect(CacheUsage.bucket(ofCacheFile: "5-e-64.jpg") == 64)
        #expect(CacheUsage.bucket(ofCacheFile: "5.jpg") == nil)
    }

    @Test func thePipelineCountsWhereEachPreviewCameFrom() async throws {
        let server = PreviewStubServer()
        let api = server.api
        let metrics = CacheMetrics()
        let directory = FileManager.default.temporaryDirectory.appending(path: "metrics-pipeline-\(UUID().uuidString)")
        let pipeline = ImagePipeline(
            api: api, cache: PreviewCache(directory: directory.appending(path: "previews")),
            originals: OriginalStore(directory: directory.appending(path: "originals"), dav: api.dav), metrics: metrics)
        let request = ImagePipeline.Request(fileId: 3, etag: "e3", bucket: 256)
        #expect(await pipeline.preview(request) != nil)
        #expect(await pipeline.preview(request) != nil)
        pipeline.cache.clearMemory()
        #expect(await pipeline.preview(request) != nil)
        let snapshot = metrics.snapshot()
        #expect(snapshot.layer(.network)?.demand == [0, 1, 0, 0])
        #expect(snapshot.layer(.memory)?.demand == [0, 1, 0, 0])
        #expect(snapshot.layer(.disk)?.demand == [0, 1, 0, 0])
    }
}
