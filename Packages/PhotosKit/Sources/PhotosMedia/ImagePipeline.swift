// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import OSLog
import PhotosModel
import PhotosNetworking
import Synchronization

/// Loads previews and originals (SPEC §5.5).
///
/// Built for a grid that scrolls through 100 000 items:
/// - Concurrent requests for the same preview share one load.
/// - A load lives as long as somebody waits for it. When the last waiting task is cancelled (the cell scrolled away),
///   the load is cancelled too, including its network request, or dropped from the queue if it has not started.
/// - Loads are queued newest first (what just came on screen wins over what was requested during the fling before it),
///   with separate limits for loads that only decode a cached file and loads that need the server. Prefetches run only
///   when nothing on screen is waiting, and `cancelPrefetch(for:)` takes them back.
/// - Previews are decoded no larger than the request asks for (`maxPixelSize`), in the load's own task, never on the main
///   thread and never on this actor.
public actor ImagePipeline {
    public let api: PhotosAPI
    public nonisolated let cache: PreviewCache
    public nonisolated let originals: OriginalStore
    /// Where previews come from and how long they take (SPEC §18.1.3).
    public nonisolated let metrics: CacheMetrics
    private let logger = Logger(subsystem: "com.nextcloud.photos", category: "images")
    /// Public album token: previews go through `publicPreview`.
    private let publicToken: String?
    /// Local originals of offline albums, used when the preview can't be loaded.
    private var localOriginal: (@Sendable (FileID, String) -> URL?)?
    /// Previews kept on the device by smart offline (SPEC §15.8.1): `(fileId, etag, bucket)` to a file at least that large.
    private var localPreview: (@Sendable (FileID, String, Int) -> URL?)?
    private var isShutDown = false
    /// The edit recipe of a photo (SPEC §16.3): previews of edited photos are rendered on the device and cached.
    private nonisolated let editProvider = Mutex<(@Sendable (FileID) -> EditRecipe?)?>(nil)
    /// The ETag of a photo in the library, for requests made without one (SPEC §18.1.1).
    private nonisolated let etagProvider = Mutex<(@Sendable (FileID) -> String?)?>(nil)
    /// The still of a Live Photo whose effect changes it (long exposure, another key photo), from its motion.
    private var liveStill: (@Sendable (FileID, EditRecipe, Int) async -> CGImage?)?

    /// How many loads may run at once.
    public struct Limits: Sendable, Equatable {
        /// Loads that need the server. The server renders previews on demand; more parallel requests mostly queue there.
        public var network: Int
        /// Loads of previews that are in the disk cache (read and decode).
        public var local: Int
        /// Prefetches kept waiting; older ones are dropped beyond this.
        public var queuedPrefetches: Int

        public init(
            network: Int = 6, local: Int = max(2, min(6, ProcessInfo.processInfo.activeProcessorCount - 2)), queuedPrefetches: Int = 200
        ) {
            self.network = max(1, network)
            self.local = max(1, local)
            self.queuedPrefetches = max(0, queuedPrefetches)
        }
    }

    public let limits: Limits

    private enum Lane { case local, network }

    /// One preview being loaded or waiting to be.
    private struct Load {
        let id: UInt64
        let request: Request
        let lane: Lane
        var waiters: [UInt64: CheckedContinuation<CGImage?, Never>] = [:]
        /// A prefetch asked for it (and has not taken it back).
        var isPrefetch = false
        var task: Task<Void, Never>?
    }

    private var loads: [String: Load] = [:]
    /// Keys of loads that have not started, oldest first; the newest is started first.
    private var queued: [Lane: [String]] = [.local: [], .network: []]
    /// Prefetches that have not started, per lane, oldest first: the network lane downloads, the local lane decodes
    /// what is on disk into memory (`prefetch(_:decode:)`).
    private var queuedPrefetches: [Lane: [String]] = [.local: [], .network: []]
    private var running: [Lane: Int] = [.local: 0, .network: 0]
    /// Every task that has not finished, also those nobody waits for any more (they still hold a slot until they return).
    private var tasks: [UInt64: Task<Void, Never>] = [:]
    private var nextId: UInt64 = 0
    private var storedSinceTrim = 0
    /// Files whose previews must survive a trim: what is pinned for offline use.
    private let pinnedFileIds: @Sendable () -> Set<FileID>

    public func setLocalOriginalProvider(_ provider: @escaping @Sendable (FileID, String) -> URL?) {
        localOriginal = provider
    }

    public func setLocalPreviewProvider(_ provider: @escaping @Sendable (FileID, String, Int) -> URL?) {
        localPreview = provider
    }

    /// Where the edits come from (`EditLibrary`). Every request shows the edited photo unless it asks for the original.
    public nonisolated func setEditProvider(_ provider: @escaping @Sendable (FileID) -> EditRecipe?) {
        editProvider.withLock { $0 = provider }
    }

    public func setLiveStillProvider(_ provider: @escaping @Sendable (FileID, EditRecipe, Int) async -> CGImage?) {
        liveStill = provider
    }

    /// The edit a preview of `fileId` shows: nil when it shows the photo as it is.
    public nonisolated func displayedEdit(_ fileId: FileID) -> EditRecipe? {
        guard let recipe = editProvider.withLock({ $0 })?(fileId), recipe.changesStill else { return nil }
        return recipe
    }

    /// Where the ETags of requests made without one come from: the library index (SPEC §18.1.1).
    ///
    /// Covers, memories, story cards, places and the like know only a file id. Without its ETag such a request would be
    /// cached under a key of its own and download a preview the grid has on disk already; with it, every screen uses
    /// the same cache files for a photo.
    public nonisolated func setEtagProvider(_ provider: @escaping @Sendable (FileID) -> String?) {
        etagProvider.withLock { $0 = provider }
    }

    /// The request with the photo's ETag from the library when it was made without one; unchanged when it has one or
    /// the library does not know the file (then it keeps a key of its own, as before).
    public nonisolated func resolved(_ request: Request) -> Request {
        guard request.etag.isEmpty, let provider = etagProvider.withLock({ $0 }), let etag = provider(request.fileId), !etag.isEmpty
        else { return request }
        var resolved = request
        resolved.etag = etag
        return resolved
    }

    /// The request with the photo's ETag (`resolved`) and current edit, so that it loads (and caches) the edited
    /// version. Requests made without them get them in `preview(_:)`; building it in front lets a tile see that its
    /// picture changed.
    public nonisolated func withEdits(_ request: Request) -> Request {
        let request = resolved(request)
        guard request.showsEdits, request.edit == nil, let recipe = displayedEdit(request.fileId) else { return request }
        var edited = request
        edited.edit = recipe
        return edited
    }

    /// The ETag under which the memory and disk caches keep what a preview of the photo shows now (`bestMemoryImage`);
    /// an empty `etag` is looked up in the library.
    public nonisolated func displayedEtag(fileId: FileID, etag: String) -> String {
        withEdits(Request(fileId: fileId, etag: etag, bucket: 0)).cacheEtag
    }

    /// A preview of this request that is on the device: in the cache or kept by smart offline.
    private func isLocal(_ request: Request) -> Bool {
        if request.edit != nil {
            // Rendered from the unedited preview, which may be on the device.
            return cache.hasDiskImage(fileId: request.fileId, etag: request.cacheEtag, bucket: request.bucket)
                || isLocal(request.unedited)
        }
        return cache.hasDiskImage(fileId: request.fileId, etag: request.etag, bucket: request.bucket)
            || localPreview?(request.fileId, request.etag, request.bucket) != nil
    }

    public init(
        api: PhotosAPI, cache: PreviewCache, originals: OriginalStore, publicToken: String? = nil, limits: Limits = Limits(),
        pinnedFileIds: @escaping @Sendable () -> Set<FileID> = { [] }, metrics: CacheMetrics = .shared
    ) {
        self.pinnedFileIds = pinnedFileIds
        self.metrics = metrics
        self.api = api
        self.cache = cache
        self.originals = originals
        self.publicToken = publicToken
        self.limits = limits
    }

    public struct Request: Sendable, Hashable {
        public var fileId: FileID
        public var etag: String
        public var bucket: Int
        public var hasPreview: Bool
        public var mimeType: String
        /// DAV URL of the original, used when the server has no preview.
        public var originalURL: URL?
        /// The preview is decoded no larger than this (long edge in pixels): a grid tile of 400 px needs the 1024 px
        /// bucket from the server, but holding it decoded at 1024 px would cost six times the memory. Nil: the bucket.
        public var maxPixelSize: Int?
        /// False: the photo as it is, without its edit (SPEC §16.3).
        public var showsEdits = true
        /// The edit the preview is rendered with (`ImagePipeline.withEdits`); nil for the photo as it is.
        public var edit: EditRecipe?

        public init(
            fileId: FileID, etag: String, bucket: Int, hasPreview: Bool = true, mimeType: String = "image/jpeg", originalURL: URL? = nil,
            maxPixelSize: Int? = nil
        ) {
            self.fileId = fileId
            self.etag = etag
            self.bucket = bucket
            self.hasPreview = hasPreview
            self.mimeType = mimeType
            self.originalURL = originalURL
            self.maxPixelSize = maxPixelSize
        }

        /// The size the preview is decoded to.
        public var decodeSize: Int { PreviewCache.decodeLimit(maxPixelSize, bucket: bucket) }

        /// The ETag the caches keep the picture under: an edited version has its own, from the edit's digest.
        public var cacheEtag: String {
            guard let edit else { return etag }
            return "\(etag.isEmpty ? "0" : etag)_e\(edit.renderingDigest)"
        }

        /// The same request for the photo as it is.
        var unedited: Request {
            var request = self
            request.edit = nil
            request.showsEdits = false
            return request
        }

        /// Loads of the same preview at different sizes are separate (each waiter gets the size it asked for).
        var key: String {
            let base = PreviewCache.key(fileId: fileId, etag: cacheEtag, bucket: bucket)
            return decodeSize < bucket ? "\(base)@\(decodeSize)" : base
        }

        func memoryImage(in cache: PreviewCache) -> CGImage? {
            cache.memoryImage(fileId: fileId, etag: cacheEtag, bucket: bucket, minPixelSize: decodeSize)
        }
    }

    /// Returns a preview from memory, disk or the server; `nil` when it can't be loaded or the calling task is cancelled.
    ///
    /// Cancelling the calling task gives the load up: it stops unless another task or a prefetch still wants it.
    public func preview(_ request: Request) async -> CGImage? {
        let request = withEdits(request)
        if let image = request.memoryImage(in: cache) {
            metrics.record(.memory, bucket: request.bucket)
            return image
        }
        if isShutDown || Task.isCancelled { return nil }
        let key = request.key
        nextId += 1
        let waiter = nextId
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
                // Still on the actor, in the caller's task: a cancellation that came in the meantime is seen here, one
                // that comes later finds the waiter registered.
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                    return
                }
                wait(for: request, key: key, waiter: waiter, continuation: continuation)
            }
        } onCancel: {
            Task { await self.giveUp(key: key, waiter: waiter) }
        }
    }

    /// Prefetches previews without waiting. They load after everything that is being waited for; the last request of
    /// a batch starts first (like the newest request on screen).
    /// - Parameter decode: also decode previews that are on disk into memory, in the local lane (the viewer's
    ///   neighbours, SPEC §18.1.2). Without it, what is on disk is left there: the grid's prefetching only gets previews
    ///   from the server, and a disk read when the tile comes on screen is fast enough.
    public func prefetch(_ requests: [Request], decode: Bool = false) {
        guard !isShutDown else { return }
        for request in requests.map(withEdits) where request.memoryImage(in: cache) == nil {
            let key = request.key
            if loads[key] != nil {
                loads[key]?.isPrefetch = true
                continue
            }
            let lane: Lane = isLocal(request) ? .local : .network
            if lane == .local && !decode { continue }
            nextId += 1
            var load = Load(id: nextId, request: request, lane: lane)
            load.isPrefetch = true
            loads[key] = load
            queuedPrefetches[lane, default: []].append(key)
        }
        for lane in [Lane.local, .network] {
            while queuedPrefetches[lane, default: []].count > limits.queuedPrefetches {
                let key = queuedPrefetches[lane, default: []].removeFirst()
                if loads[key]?.waiters.isEmpty == true { loads[key] = nil }
            }
        }
        startLoads()
    }

    /// The best picture of the request's photo that is on the device now: decoded in memory (up to the size asked
    /// for), else a smaller preview on disk (read off the caller's thread). The viewer shows it while the preview it
    /// asked for loads, so a page is never blank (SPEC §18.1.2). Nil when there is none; nothing is downloaded.
    public nonisolated func placeholder(for request: Request) async -> CGImage? {
        let request = withEdits(request)
        let etag = request.cacheEtag
        if let image = cache.bestMemoryImage(fileId: request.fileId, etag: etag, upTo: request.bucket) { return image }
        let cache = cache
        return await Task.detached(priority: .userInitiated) { () -> CGImage? in
            for bucket in PhotosAPI.previewBuckets.reversed() where bucket < request.bucket {
                if let image = cache.diskImage(fileId: request.fileId, etag: etag, bucket: bucket) { return image }
            }
            return nil
        }.value
    }

    /// Takes prefetches back (the items left the prefetch window): loads that nobody waits for are cancelled.
    public func cancelPrefetch(for requests: [Request]) {
        for request in requests.map(withEdits) {
            let key = request.key
            guard loads[key]?.isPrefetch == true else { continue }
            loads[key]?.isPrefetch = false
            dropIfUnwanted(key)
        }
    }

    /// Cancels every prefetch nobody waits for.
    public func cancelAllPrefetches() {
        for (key, load) in loads where load.isPrefetch {
            loads[key]?.isPrefetch = false
            dropIfUnwanted(key)
        }
    }

    /// Cancels the loads in flight and waits for them; nothing is loaded or written to the caches afterwards (account removal).
    public func shutdown() async {
        isShutDown = true
        let waiting = loads.values.flatMap { $0.waiters.values }
        loads = [:]
        queued = [.local: [], .network: []]
        queuedPrefetches = [.local: [], .network: []]
        waiting.forEach { $0.resume(returning: nil) }
        let unfinished = Array(tasks.values)
        unfinished.forEach { $0.cancel() }
        for task in unfinished { await task.value }
        await originals.shutdown()
    }

    /// Loads waiting or running, for tests and diagnostics.
    var pendingLoadCount: Int { loads.count }
    var runningLoadCount: Int { tasks.count }

    // MARK: Scheduling

    private func wait(for request: Request, key: String, waiter: UInt64, continuation: CheckedContinuation<CGImage?, Never>) {
        if loads[key] == nil {
            nextId += 1
            let onDisk = isLocal(request)
            loads[key] = Load(id: nextId, request: request, lane: onDisk ? .local : .network)
            queued[onDisk ? .local : .network, default: []].append(key)
        } else if loads[key]?.task == nil, let lane = loads[key]?.lane, let index = queuedPrefetches[lane]?.firstIndex(of: key) {
            // A prefetch that is now on screen: it joins the loads that are waited for.
            queuedPrefetches[lane]?.remove(at: index)
            queued[lane, default: []].append(key)
        } else if loads[key]?.task == nil, let lane = loads[key]?.lane, let index = queued[lane]?.firstIndex(of: key) {
            // Asked for again: it is the newest request once more.
            queued[lane]?.remove(at: index)
            queued[lane]?.append(key)
        }
        loads[key]?.waiters[waiter] = continuation
        startLoads()
    }

    private func giveUp(key: String, waiter: UInt64) {
        guard let continuation = loads[key]?.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(returning: nil)
        dropIfUnwanted(key)
    }

    /// Cancels a load that has neither waiters nor a prefetch behind it.
    private func dropIfUnwanted(_ key: String) {
        guard let load = loads[key], load.waiters.isEmpty, !load.isPrefetch else { return }
        loads[key] = nil
        if let task = load.task {
            // The task still counts as running until it has returned (`finished`).
            task.cancel()
        } else {
            queued[load.lane]?.removeAll { $0 == key }
            queuedPrefetches[load.lane]?.removeAll { $0 == key }
        }
    }

    private func startLoads() {
        guard !isShutDown else { return }
        for lane in [Lane.local, .network] {
            let limit = lane == .local ? limits.local : limits.network
            while running[lane, default: 0] < limit {
                // Newest first; prefetches only when nothing is waited for in their lane.
                let key: String
                if let next = queued[lane]?.popLast() {
                    key = next
                } else if let next = queuedPrefetches[lane]?.popLast() {
                    key = next
                } else {
                    break
                }
                guard let load = loads[key], load.task == nil else { continue }
                start(load, key: key)
            }
        }
    }

    private func start(_ load: Load, key: String) {
        running[load.lane, default: 0] += 1
        let work = Work(
            api: api, cache: cache, originals: originals, publicToken: publicToken, logger: logger, localOriginal: localOriginal,
            localPreview: localPreview, liveStill: liveStill)
        let request = load.request
        let id = load.id
        let lane = load.lane
        let signposter = metrics.signposter
        // Detached: reading, decoding and the request run on the concurrent executor, not on this actor (and never on the
        // main thread). Loads somebody waits for run at user-initiated priority, prefetches below it.
        let task = Task.detached(priority: load.waiters.isEmpty ? .utility : .userInitiated) { [weak self] in
            // One "Preview" interval per load in Instruments, with the layer it came from.
            let interval: OSSignpostIntervalState? =
                signposter.isEnabled
                ? signposter.beginInterval("Preview", id: signposter.makeSignpostID(), "\(request.bucket)") : nil
            let result = await work.load(request)
            if let interval { signposter.endInterval("Preview", interval, "\(String(describing: result.layer))") }
            await self?.finished(key: key, id: id, lane: lane, result: result)
        }
        loads[key]?.task = task
        tasks[id] = task
    }

    private func finished(key: String, id: UInt64, lane: Lane, result: Work.Result) {
        tasks[id] = nil
        running[lane, default: 1] -= 1
        // The load may have been given up (and even asked for again as a new load) while the task was returning.
        if let load = loads[key], load.id == id {
            loads[key] = nil
            load.waiters.values.forEach { $0.resume(returning: result.image) }
            // A load that was given up is not here any more: what is counted was delivered (or failed).
            metrics.record(result.image == nil ? .failed : result.layer, bucket: load.request.bucket, prefetch: load.waiters.isEmpty)
        }
        if result.downloaded { didStorePreview() }
        startLoads()
    }

    // MARK: Cache size

    /// A long session (a Mac app that is never sent to the background) must not grow the cache without bound either.
    private func didStorePreview() {
        storedSinceTrim += 1
        guard storedSinceTrim >= PreviewCache.trimInterval else { return }
        storedSinceTrim = 0
        Task.detached(priority: .utility) { [weak self] in await self?.trimCaches() }
    }

    /// Brings the disk caches below their limits, least recently used files first (SPEC §5.5). Called at launch, when the
    /// app goes to the background, and after every `PreviewCache.trimInterval` downloaded previews.
    ///
    /// Previews of offline-pinned files are kept. Offline originals are not in these caches at all (they live in the
    /// account's Offline folder), so a trim can never remove them. Returns when both caches are trimmed.
    public nonisolated func trimCaches(limits: CacheLimits = .current()) async {
        let pinned = pinnedFileIds()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            cache.trim(toBytes: limits.previewBytes, protecting: pinned) { continuation.resume() }
        }
        await originals.trim(toBytes: limits.originalBytes)
    }

    /// What one load does, outside the actor.
    private struct Work: Sendable {
        struct Result: Sendable {
            var image: CGImage?
            var downloaded = false
            /// Where it came from (`CacheMetrics`).
            var layer = CacheLayer.failed
        }

        let api: PhotosAPI
        let cache: PreviewCache
        let originals: OriginalStore
        let publicToken: String?
        let logger: Logger
        let localOriginal: (@Sendable (FileID, String) -> URL?)?
        let localPreview: (@Sendable (FileID, String, Int) -> URL?)?
        let liveStill: (@Sendable (FileID, EditRecipe, Int) async -> CGImage?)?

        func load(_ request: Request) async -> Result {
            // Reading, decoding and downsampling must never happen on the main thread (SPEC §10: no scroll hitches).
            dispatchPrecondition(condition: .notOnQueue(.main))
            if Task.isCancelled { return Result() }
            if let edit = request.edit { return await loadEdited(request, edit: edit) }
            let size = request.maxPixelSize
            if let image = cache.diskImage(fileId: request.fileId, etag: request.etag, bucket: request.bucket, maxPixelSize: size) {
                return Result(image: image, layer: .disk)
            }
            if Task.isCancelled { return Result() }
            // Smart offline: a kept preview at least as large as the bucket, decoded to the size asked for. It is not copied
            // into the cache (it is on the device already); only the decoded image is remembered.
            if let file = localPreview?(request.fileId, request.etag, request.bucket),
                let image = ImageDecoding.decode(url: file, maxPixelSize: request.decodeSize)
            {
                cache.remember(
                    image, key: PreviewCache.key(fileId: request.fileId, etag: request.etag, bucket: request.bucket),
                    maxPixelSize: request.decodeSize)
                return Result(image: image, layer: .smartOffline)
            }
            // Offline albums: thumbnail the downloaded original instead of hitting the network.
            if let file = localOriginal?(request.fileId, request.etag),
                let image = ImageDecoding.decode(url: file, maxPixelSize: request.bucket)
            {
                return Result(
                    image: cache.store(image, fileId: request.fileId, etag: request.etag, bucket: request.bucket, maxPixelSize: size),
                    layer: .offline)
            }
            do {
                let data: Data
                if let publicToken {
                    data = try await api.dav.get(api.publicPreviewURL(fileId: request.fileId, size: request.bucket, token: publicToken))
                        .data
                } else {
                    data = try await api.preview(fileId: request.fileId, size: request.bucket, etag: request.etag)
                }
                if let image = cache.store(data, fileId: request.fileId, etag: request.etag, bucket: request.bucket, maxPixelSize: size) {
                    return Result(image: image, downloaded: true, layer: .network)
                }
            } catch NetworkError.notFound {
                // fall through to local thumbnail
            } catch {
                if !Task.isCancelled {
                    logger.debug("preview \(request.fileId) failed: \(error.localizedDescription, privacy: .public)")
                }
                return Result()
            }
            // No server preview (e.g. HEIC/RAW without a preview provider): thumbnail the original locally.
            guard MimeTypes.kind(of: request.mimeType) == .image, let url = request.originalURL,
                let file = try? await originals.original(fileId: request.fileId, etag: request.etag, url: url, maxBytes: 50 * 1024 * 1024),
                let image = ImageDecoding.decode(url: file, maxPixelSize: request.bucket)
            else { return Result() }
            return Result(
                image: cache.store(image, fileId: request.fileId, etag: request.etag, bucket: request.bucket, maxPixelSize: size),
                downloaded: true, layer: .network)
        }

        /// An edited photo (SPEC §16.3): rendered on the device from its unedited preview (or, for a Live Photo effect,
        /// from its motion) and cached under the edit's own ETag.
        func loadEdited(_ request: Request, edit: EditRecipe) async -> Result {
            let etag = request.cacheEtag
            if let image = cache.diskImage(fileId: request.fileId, etag: etag, bucket: request.bucket, maxPixelSize: request.maxPixelSize) {
                return Result(image: image, layer: .disk)
            }
            var base: CGImage?
            var downloaded = false
            // A rendition counts where its base came from (a Live Photo still: the network).
            var layer = CacheLayer.network
            if edit.live?.changesStill == true, let liveStill {
                base = await liveStill(request.fileId, edit, request.bucket)
            }
            if base == nil {
                var unedited = request.unedited
                unedited.maxPixelSize = nil
                let result = await load(unedited)
                base = result.image
                downloaded = result.downloaded
                layer = result.layer
            }
            guard let base, !Task.isCancelled,
                let rendered = EditRendering.rendition(of: base, recipe: edit, maxPixelSize: request.bucket)
            else { return Result(downloaded: downloaded) }
            return Result(
                image: cache.store(
                    rendered, fileId: request.fileId, etag: etag, bucket: request.bucket, maxPixelSize: request.maxPixelSize),
                downloaded: downloaded, layer: layer)
        }
    }
}

// MARK: - Shared helper of the cache fillers (fill, SPEC §18.3)

extension ImagePipeline {
    /// Nothing waits for a preview from the server and no prefetch is queued or running: a background filler may use the
    /// network without slowing what is on screen.
    public var isNetworkIdle: Bool {
        // Only the network lane: prefetches decoded from the disk (`prefetch(_:decode:)`, the viewer's neighbours) do not
        // use the server. `queuedPrefetches` is per lane, so it is never empty as a whole.
        running[.network, default: 0] == 0 && (queued[.network] ?? []).isEmpty && (queuedPrefetches[.network] ?? []).isEmpty
    }
}

/// Size limits of the disk caches (SPEC §5.5: LRU caps). Offline albums are not a cache and have no limit.
public struct CacheLimits: Sendable, Equatable {
    public var previewBytes: Int64
    public var originalBytes: Int64

    public static let defaultPreviewBytes: Int64 = 2 * 1024 * 1024 * 1024
    public static let defaultOriginalBytes: Int64 = 1024 * 1024 * 1024
    /// `UserDefaults` keys (bytes) that override the defaults.
    public static let previewLimitKey = "previewCacheLimitBytes"
    public static let originalLimitKey = "originalCacheLimitBytes"

    public init(previewBytes: Int64 = CacheLimits.defaultPreviewBytes, originalBytes: Int64 = CacheLimits.defaultOriginalBytes) {
        self.previewBytes = previewBytes
        self.originalBytes = originalBytes
    }

    /// The limits in effect unless the settings say otherwise: previews scaled by the free space
    /// (`defaultPreviewBytes(availableBytes:)`, SPEC §18.2), originals 1 GB.
    public static func current(_ defaults: UserDefaults = .standard, availableBytes: Int64? = availableDiskBytes()) -> CacheLimits {
        var limits = CacheLimits(previewBytes: defaultPreviewBytes(availableBytes: availableBytes))
        if let bytes = defaults.object(forKey: previewLimitKey) as? NSNumber, bytes.int64Value > 0 {
            limits.previewBytes = bytes.int64Value
        }
        if let bytes = defaults.object(forKey: originalLimitKey) as? NSNumber, bytes.int64Value > 0 {
            limits.originalBytes = bytes.int64Value
        }
        return limits
    }
}

/// Downloads and caches original files (SPEC §5.5.2), separate LRU cap.
public actor OriginalStore {
    public let directory: URL
    let dav: DAVClient
    private var inflight: [String: Task<URL, any Error>] = [:]
    private var isShutDown = false

    public init(directory: URL, dav: DAVClient) {
        self.directory = directory
        self.dav = dav
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    nonisolated func localURL(fileId: FileID, etag: String, ext: String) -> URL {
        directory.appending(path: "\(fileId)-\(CacheFileName.etag(etag)).\(ext.isEmpty ? "bin" : ext)")
    }

    /// Cached local copy if present.
    public nonisolated func cached(fileId: FileID, etag: String, url: URL) -> URL? {
        let local = localURL(fileId: fileId, etag: etag, ext: url.pathExtension.lowercased())
        return FileManager.default.fileExists(atPath: local.path(percentEncoded: false)) ? local : nil
    }

    /// Downloads the original (or returns the cached copy).
    public func original(fileId: FileID, etag: String, url: URL, maxBytes: Int64? = nil) async throws -> URL {
        if let cached = cached(fileId: fileId, etag: etag, url: url) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: cached.path(percentEncoded: false))
            return cached
        }
        if isShutDown { throw CancellationError() }
        let key = "\(fileId)-\(etag)"
        if let task = inflight[key] { return try await task.value }
        let target = localURL(fileId: fileId, etag: etag, ext: url.pathExtension.lowercased())
        let task = Task<URL, any Error> { [dav] in
            if let maxBytes {
                let head = try await dav.head(url)
                if let length = head.header("content-length").flatMap(Int64.init), length > maxBytes {
                    throw NetworkError.http(status: 413, message: "File too large to preview locally")
                }
            }
            let (file, _) = try await dav.download(url)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: file, to: target)
            return target
        }
        inflight[key] = task
        defer { inflight[key] = nil }
        return try await task.value
    }

    /// Cancels the downloads in flight and waits for them; nothing is downloaded afterwards.
    public func shutdown() async {
        isShutDown = true
        let tasks = Array(inflight.values)
        tasks.forEach { $0.cancel() }
        for task in tasks { _ = try? await task.value }
    }

    public func trim(toBytes limit: Int64) {
        let manager = FileManager.default
        guard
            let files = try? manager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        else { return }
        var entries = files.compactMap { url -> (URL, Int64, Date)? in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]), let size = values.fileSize
            else { return nil }
            return (url, Int64(size), values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        entries.sort { $0.2 < $1.2 }
        for (url, size, _) in entries where total > limit {
            try? manager.removeItem(at: url)
            total -= size
        }
    }

    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
