// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import PhotosModel
import PhotosNetworking
import Synchronization
import Testing

@testable import PhotosMedia

/// A preview endpoint that records what is requested, how many requests run at once and which were cancelled, and that
/// can hold its answers back.
final class PreviewStubServer: Sendable {
    struct State: Sendable {
        var started: [FileID] = []
        var answered: [FileID] = []
        var cancelled: [FileID] = []
        var active = 0
        var maxActive = 0
        var isHolding = false
        var held: [CheckedContinuation<Void, Never>] = []
    }

    let host = "previews-\(UUID().uuidString.lowercased()).test"
    let state = Mutex(State())
    let image: Data

    init(width: Int = 32, height: Int = 24) {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        image = ImageDecoding.jpegData(context.makeImage()!)!
        PreviewStubProtocol.servers.withLock { $0[host] = self }
    }

    deinit {
        let host = self.host
        PreviewStubProtocol.servers.withLock { $0[host] = nil }
    }

    var api: PhotosAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PreviewStubProtocol.self]
        let http = HTTPClient(trustStore: TrustStore(directory: nil), configuration: configuration)
        let connection = ServerConnection(
            serverURL: URL(string: "http://\(host)")!, userId: "alice", loginName: "alice", appPassword: "secret", userAgent: "tests")
        return PhotosAPI(dav: DAVClient(http: http, connection: connection), ocs: OCSClient(http: http, connection: connection))
    }

    var started: [FileID] { state.withLock { $0.started } }
    var answered: [FileID] { state.withLock { $0.answered } }
    var cancelled: [FileID] { state.withLock { $0.cancelled } }
    var maxActive: Int { state.withLock { $0.maxActive } }

    /// Requests from now on wait until `release()`.
    func hold() { state.withLock { $0.isHolding = true } }

    func release() {
        let held = state.withLock { state in
            state.isHolding = false
            defer { state.held = [] }
            return state.held
        }
        held.forEach { $0.resume() }
    }

    func begin(_ fileId: FileID) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let wait = state.withLock { state in
                state.started.append(fileId)
                state.active += 1
                state.maxActive = max(state.maxActive, state.active)
                if state.isHolding { state.held.append(continuation) }
                return state.isHolding
            }
            if !wait { continuation.resume() }
        }
    }

    func end(_ fileId: FileID, cancelled: Bool) {
        state.withLock { state in
            state.active -= 1
            if cancelled { state.cancelled.append(fileId) } else { state.answered.append(fileId) }
        }
    }
}

final class PreviewStubProtocol: URLProtocol, @unchecked Sendable {
    static let servers = Mutex<[String: PreviewStubServer]>([:])
    /// Guards the one-time end of a request (answered or cancelled).
    private let finished = Mutex(false)

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host()?.hasSuffix(".test") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let server = Self.servers.withLock({ $0[url.host() ?? ""] }),
            let fileId = FileID(url.lastPathComponent)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Task {
            await server.begin(fileId)
            // A small delay keeps answers from arriving before the test has looked at the queue.
            try? await Task.sleep(for: .milliseconds(5))
            guard finish() else { return }
            server.end(fileId, cancelled: false)
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/jpeg"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: server.image)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        guard finish(), let url = request.url, let server = Self.servers.withLock({ $0[url.host() ?? ""] }),
            let fileId = FileID(url.lastPathComponent)
        else { return }
        server.end(fileId, cancelled: true)
    }

    /// True for the first caller only.
    private func finish() -> Bool {
        finished.withLock { done in
            defer { done = true }
            return !done
        }
    }
}

@Suite(.timeLimit(.minutes(1))) struct ImagePipelineTests {
    let server = PreviewStubServer()
    let directory = FileManager.default.temporaryDirectory.appending(path: "pipeline-\(UUID().uuidString)")

    func pipeline(network: Int = 6, queuedPrefetches: Int = 200, pinned: Set<FileID> = []) -> ImagePipeline {
        let api = server.api
        return ImagePipeline(
            api: api, cache: PreviewCache(directory: directory.appending(path: "previews")),
            originals: OriginalStore(directory: directory.appending(path: "originals"), dav: api.dav),
            limits: ImagePipeline.Limits(network: network, local: 2, queuedPrefetches: queuedPrefetches), pinnedFileIds: { pinned })
    }

    func request(_ id: FileID) -> ImagePipeline.Request { ImagePipeline.Request(fileId: id, etag: "e\(id)", bucket: 256) }

    /// Waits until `condition` holds (the pipeline and the stub work on other threads).
    func eventually(_ what: String, _ condition: @Sendable () async -> Bool) async {
        for _ in 0..<1000 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out waiting for: \(what)")
    }

    @Test func loadsDecodesOffTheMainThreadAndCaches() async throws {
        let pipeline = pipeline()
        // Called from the main actor, as a view does; the load itself asserts that it is not on the main thread.
        let image = await MainActor.run { Task { await pipeline.preview(request(1)) } }.value
        #expect(image?.width == 32)
        #expect(server.started == [1])
        // Memory, then disk: no second request.
        #expect(await pipeline.preview(request(1)) != nil)
        pipeline.cache.clearMemory()
        #expect(await pipeline.preview(request(1)) != nil)
        #expect(server.started == [1])
        #expect(await pipeline.pendingLoadCount == 0)
    }

    @Test func concurrentRequestsShareOneLoad() async throws {
        let pipeline = pipeline()
        server.hold()
        let tasks = (0..<5).map { _ in Task { await pipeline.preview(request(1)) } }
        await eventually("the request") { server.started == [1] }
        try await Task.sleep(for: .milliseconds(30))
        server.release()
        for task in tasks { #expect(await task.value != nil) }
        #expect(server.started == [1])
    }

    @Test func cancellingTheOnlyWaiterCancelsTheRequest() async throws {
        let pipeline = pipeline()
        server.hold()
        let task = Task { await pipeline.preview(request(1)) }
        await eventually("the request") { server.started == [1] }
        task.cancel()
        // The cell's task returns at once, and the network request is cancelled.
        #expect(await task.value == nil)
        await eventually("the cancelled request") { server.cancelled == [1] }
        await eventually("an empty pipeline") {
            let pending = await pipeline.pendingLoadCount
            let running = await pipeline.runningLoadCount
            return pending == 0 && running == 0
        }
        server.release()
        #expect(server.answered.isEmpty)
        #expect(!pipeline.cache.hasDiskImage(fileId: 1, etag: "e1", bucket: 256))
        // Asking again loads it.
        #expect(await pipeline.preview(request(1)) != nil)
    }

    @Test func aLoadSurvivesAsLongAsSomeoneWaits() async throws {
        let pipeline = pipeline()
        server.hold()
        let first = Task { await pipeline.preview(request(1)) }
        let second = Task { await pipeline.preview(request(1)) }
        await eventually("the request") { server.started == [1] }
        try await Task.sleep(for: .milliseconds(30))
        first.cancel()
        #expect(await first.value == nil)
        try await Task.sleep(for: .milliseconds(30))
        #expect(server.cancelled.isEmpty)
        server.release()
        #expect(await second.value != nil)
        #expect(server.answered == [1])
    }

    @Test func queuedLoadsOfCancelledWaitersNeverStart() async throws {
        let pipeline = pipeline(network: 1)
        server.hold()
        let visible = Task { await pipeline.preview(request(1)) }
        await eventually("the first request") { server.started == [1] }
        // A fling: 50 cells ask and scroll away before their load starts.
        let gone = (2...51).map { id in Task { await pipeline.preview(request(FileID(id))) } }
        await eventually("the queue") { await pipeline.pendingLoadCount == 51 }
        gone.forEach { $0.cancel() }
        for task in gone { #expect(await task.value == nil) }
        await eventually("the emptied queue") { await pipeline.pendingLoadCount == 1 }
        server.release()
        #expect(await visible.value != nil)
        #expect(server.started == [1])
    }

    @Test func loadsAreLimitedAndNewestFirst() async throws {
        let pipeline = pipeline(network: 1)
        server.hold()
        var tasks = [Task { await pipeline.preview(request(1)) }]
        await eventually("the first request") { server.started == [1] }
        for id in 2...5 {
            tasks.append(Task { await pipeline.preview(request(FileID(id))) })
            await eventually("request \(id) in the queue") { await pipeline.pendingLoadCount == id }
        }
        server.release()
        for task in tasks { #expect(await task.value != nil) }
        // One at a time; what was asked for last (what is on screen now) first.
        #expect(server.started == [1, 5, 4, 3, 2])
        #expect(server.maxActive == 1)
    }

    @Test func networkLoadsRespectTheLimit() async throws {
        let pipeline = pipeline(network: 3)
        let images = await withTaskGroup(of: CGImage?.self) { group in
            for id in 1...40 { group.addTask { await pipeline.preview(request(FileID(id))) } }
            var images: [CGImage?] = []
            for await image in group { images.append(image) }
            return images
        }
        #expect(images.count == 40 && images.allSatisfy { $0 != nil })
        #expect(server.maxActive <= 3)
        #expect(server.maxActive >= 2)
        #expect(Set(server.answered).count == 40)
    }

    @Test func prefetchRunsAfterWhatIsWaitedForAndCanBeCancelled() async throws {
        let pipeline = pipeline(network: 1)
        server.hold()
        await pipeline.prefetch((1...6).map { request(FileID($0)) })
        // Newest prefetch first.
        await eventually("the first prefetch") { server.started == [6] }
        let visible = Task { await pipeline.preview(request(100)) }
        await eventually("the visible request in the queue") { await pipeline.pendingLoadCount == 7 }
        // The items 1…3 leave the prefetch window, and so does the one being loaded.
        await pipeline.cancelPrefetch(for: [1, 2, 3, 6].map { request(FileID($0)) })
        await eventually("the cancelled prefetch") { server.cancelled == [6] }
        server.release()
        #expect(await visible.value != nil)
        await eventually("the remaining prefetches") { Set(server.answered) == [100, 5, 4] }
        // What is waited for goes before the prefetches that are left.
        #expect(server.started == [6, 100, 5, 4])
        await eventually("an empty pipeline") { await pipeline.pendingLoadCount == 0 }
        #expect(pipeline.cache.hasDiskImage(fileId: 5, etag: "e5", bucket: 256))
        #expect(!pipeline.cache.hasDiskImage(fileId: 1, etag: "e1", bucket: 256))
    }

    @Test func aPrefetchThatComesOnScreenIsKeptWhenThePrefetchIsCancelled() async throws {
        let pipeline = pipeline(network: 1, queuedPrefetches: 2)
        server.hold()
        await pipeline.prefetch((1...5).map { request(FileID($0)) })
        await eventually("the first prefetch") { server.started == [5] }
        // Only the two newest prefetches were kept (one of them is the one that runs).
        #expect(await pipeline.pendingLoadCount == 2)
        let onScreen = Task { await pipeline.preview(request(4)) }
        try await Task.sleep(for: .milliseconds(30))
        await pipeline.cancelAllPrefetches()
        await eventually("the cancelled prefetches") { await pipeline.pendingLoadCount == 1 }
        server.release()
        #expect(await onScreen.value != nil)
        #expect(server.started == [5, 4])
        // Prefetching what is cached already asks for nothing.
        await pipeline.prefetch([request(4)])
        try await Task.sleep(for: .milliseconds(30))
        #expect(server.started == [5, 4])
    }

    @Test func previewsAreDecodedAtTheRequestedSizeNotTheBucketSize() async throws {
        let server = PreviewStubServer(width: 1024, height: 768)
        let api = server.api
        let pipeline = ImagePipeline(
            api: api, cache: PreviewCache(directory: directory.appending(path: "previews")),
            originals: OriginalStore(directory: directory.appending(path: "originals"), dav: api.dav))
        func request(_ size: Int?) -> ImagePipeline.Request {
            ImagePipeline.Request(fileId: 7, etag: "e7", bucket: 1024, maxPixelSize: size)
        }
        // A tile of 320 px gets 320 px decoded (about 300 KB instead of 3 MB), and the whole preview goes to disk.
        let small = await pipeline.preview(request(320))
        #expect(small?.width == 320)
        #expect(small?.height == 240)
        #expect(pipeline.cache.hasDiskImage(fileId: 7, etag: "e7", bucket: 1024))
        // A larger tile is not served the small image from memory: it is decoded again from disk, not downloaded again.
        let large = await pipeline.preview(request(nil))
        #expect(large?.width == 1024)
        #expect(server.started == [7])
        // A smaller one is served from memory by the larger image, which is not replaced by a smaller decode.
        let again = await pipeline.preview(request(320))
        #expect(again?.width == 1024)
        #expect(pipeline.cache.memoryImage(fileId: 7, etag: "e7", bucket: 1024, minPixelSize: 1024)?.width == 1024)
        // A preview smaller than its bucket (a small original) counts as complete once decoded with the full limit.
        #expect(PreviewCache.decodeLimit(2000, bucket: 1024) == 1024)
        #expect(PreviewCache.decodeLimit(nil, bucket: 256) == 256)
    }

    @Test func shutdownEndsWaitersAndLoads() async throws {
        let pipeline = pipeline(network: 1)
        server.hold()
        let tasks = (1...4).map { id in Task { await pipeline.preview(request(FileID(id))) } }
        await eventually("the queue") { await pipeline.pendingLoadCount == 4 && !server.started.isEmpty }
        await pipeline.shutdown()
        for task in tasks { #expect(await task.value == nil) }
        #expect(await pipeline.runningLoadCount == 0)
        server.release()
        #expect(await pipeline.preview(request(9)) == nil)
        #expect(server.started.count == 1)
    }
}

@Suite(.timeLimit(.minutes(1))) struct PreviewCacheTrimTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "cache-\(UUID().uuidString)")

    /// Writes a cache file of `bytes` bytes that was last used `age` seconds ago.
    func add(_ cache: PreviewCache, _ fileId: FileID, bytes: Int, age: TimeInterval) throws {
        let url = cache.fileURL(key: PreviewCache.key(fileId: fileId, etag: "e", bucket: 256))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path(percentEncoded: false))
    }

    func has(_ cache: PreviewCache, _ fileId: FileID) -> Bool { cache.hasDiskImage(fileId: fileId, etag: "e", bucket: 256) }

    @Test func trimRemovesLeastRecentlyUsedFirst() throws {
        let cache = PreviewCache(directory: directory)
        for id in 1...10 { try add(cache, FileID(id), bytes: 1000, age: Double(id) * 60) }
        #expect(cache.totalSize() == 10_000)
        // Below the limit: nothing happens.
        #expect(cache.trimNow(toBytes: 10_000) == 10_000)
        #expect(cache.trimNow(toBytes: 4500) == 4000)
        #expect((1...10).filter { has(cache, FileID($0)) } == [1, 2, 3, 4])
    }

    @Test func trimNeverRemovesPinnedFiles() throws {
        let cache = PreviewCache(directory: directory)
        for id in 1...10 { try add(cache, FileID(id), bytes: 1000, age: Double(id) * 60) }
        // The two oldest files are pinned for offline use; so is a file whose id starts like another one's.
        try add(cache, 100, bytes: 1000, age: 9000)
        let left = cache.trimNow(toBytes: 3000, protecting: [9, 10, 100])
        #expect(left == 3000)
        #expect((1...10).filter { has(cache, FileID($0)) } == [9, 10])
        #expect(has(cache, 100))
        // Even a limit of zero keeps them.
        #expect(cache.trimNow(toBytes: 0, protecting: [9, 10, 100]) == 3000)
        #expect(has(cache, 9) && has(cache, 10) && has(cache, 100))
        #expect(PreviewCache.fileId(ofCacheFile: URL(filePath: "/x/12/3412-abc-def-256.jpg")) == 3412)
    }

    @Test func readingAPreviewMakesItRecentlyUsed() throws {
        let cache = PreviewCache(directory: directory)
        let context = CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let data = ImageDecoding.jpegData(context.makeImage()!)!
        for id in 1...3 {
            cache.store(data, fileId: FileID(id), etag: "e", bucket: 256)
            let url = cache.fileURL(key: PreviewCache.key(fileId: FileID(id), etag: "e", bucket: 256))
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-Double(4 - id) * 3600)], ofItemAtPath: url.path(percentEncoded: false))
        }
        // 1 is the oldest file, but it was just looked at.
        cache.clearMemory()
        #expect(cache.diskImage(fileId: 1, etag: "e", bucket: 256) != nil)
        cache.trimNow(toBytes: Int64(data.count) + 1)
        #expect((1...3).filter { has(cache, FileID($0)) } == [1])
    }

    @Test func pipelineTrimsBothCachesAndKeepsPinnedPreviewsAndOfflineFiles() async throws {
        let server = PreviewStubServer()
        let api = server.api
        let cache = PreviewCache(directory: directory.appending(path: "previews"))
        let originals = OriginalStore(directory: directory.appending(path: "originals"), dav: api.dav)
        // Offline albums live in their own folder, next to the caches.
        let offline = directory.appending(path: "Offline")
        try FileManager.default.createDirectory(at: offline, withIntermediateDirectories: true)
        try Data(count: 5000).write(to: offline.appending(path: "7.jpg"))
        for id in 1...6 { try add(cache, FileID(id), bytes: 1000, age: Double(id) * 60) }
        for id in 1...4 {
            let url = originals.localURL(fileId: FileID(id), etag: "e", ext: "jpg")
            try Data(count: 2000).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-Double(id) * 60)], ofItemAtPath: url.path(percentEncoded: false))
        }
        let pipeline = ImagePipeline(api: api, cache: cache, originals: originals, pinnedFileIds: { [6] })
        await pipeline.trimCaches(limits: CacheLimits(previewBytes: 2500, originalBytes: 4000))
        #expect((1...6).filter { has(cache, FileID($0)) } == [1, 6])
        #expect((1...4).filter { originals.cached(fileId: FileID($0), etag: "e", url: URL(filePath: "/x.jpg")) != nil } == [1, 2])
        #expect(FileManager.default.fileExists(atPath: offline.appending(path: "7.jpg").path(percentEncoded: false)))
    }

    @Test func limitsAndMemoryBudget() {
        #expect(CacheLimits().previewBytes == 2 * 1024 * 1024 * 1024)
        #expect(CacheLimits().originalBytes == 1024 * 1024 * 1024)
        let defaults = UserDefaults(suiteName: "limits-\(UUID().uuidString)")!
        #expect(CacheLimits.current(defaults) == CacheLimits())
        defaults.set(500_000_000, forKey: CacheLimits.previewLimitKey)
        defaults.set(-1, forKey: CacheLimits.originalLimitKey)
        #expect(CacheLimits.current(defaults) == CacheLimits(previewBytes: 500_000_000))

        let megabyte = 1024 * 1024
        let gigabyte: UInt64 = 1024 * 1024 * 1024
        #if os(iOS)
            // iPhone-class devices stay well below the 300 MB the whole app may use while scrolling.
            #expect(PreviewCache.defaultMemoryLimit(physicalMemory: 6 * gigabyte) < 80 * megabyte)
            #expect(PreviewCache.defaultMemoryLimit(physicalMemory: 3 * gigabyte) == 48 * megabyte)
            #expect(PreviewCache.defaultMemoryLimit(physicalMemory: 16 * gigabyte) == 120 * megabyte)
        #else
            #expect(PreviewCache.defaultMemoryLimit(physicalMemory: 8 * gigabyte) == 200 * megabyte)
        #endif
        #expect(PreviewCache(directory: directory).memoryLimitBytes == PreviewCache.defaultMemoryLimit())
        #expect(PreviewCache(directory: directory, memoryLimitBytes: 8 * megabyte).memoryLimitBytes == 8 * megabyte)
    }
}
