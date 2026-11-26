// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Network
import OSLog
import PhotosDomain
import PhotosMedia
import PhotosModel
import PhotosNetworking
import PhotosStore
import Synchronization

/// Keeps the thumbnails of the whole library on the device (SPEC §18.3.1): the 256 px preview of every photo, downloaded,
/// and the 64 px one, made from it. With them every zoom level of the library shows pictures at once, also offline.
///
/// A pass walks the library newest first, page by page, and fills what is missing; what is on the disk is the state, so
/// a pass that stops (the app is closed, the network goes) is resumed by the next one. It downloads only while the
/// image pipeline has nothing to load for the screen (`FillPacing`), on Wi-Fi unless the user allowed cellular, never in
/// Low Power Mode or Low Data Mode, two previews at a time. Files are written to the disk cache without being decoded,
/// so the memory cache keeps what is on screen.
///
/// Not through `ImagePipeline.prefetch`: its queue keeps the newest 200 prefetches and drops the oldest (a filler
/// would push out the grid's own prefetches), it decodes into the memory cache, and it says nothing when a preview is
/// done, which pacing and progress need.
public actor LibraryThumbnailFiller {
    /// How far the thumbnails are.
    public struct Progress: Sendable, Equatable {
        /// Photos with a server preview in the library.
        public var total = 0
        /// Of these, the photos whose thumbnails are on the device.
        public var done = 0
        public var isRunning = false
        /// The last pass stopped because of the conditions (no Wi-Fi, Low Power Mode, Low Data Mode).
        public var isWaitingForConditions = false
        /// When `total` and `done` were counted; nil before the first count.
        public var countedAt: Date?

        public init() {}

        public var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
        public var isComplete: Bool { countedAt != nil && done >= total }
    }

    /// What a pass did.
    public struct Outcome: Sendable, Equatable {
        /// 256 px previews downloaded.
        public var downloaded = 0
        /// 64 px previews made on the device.
        public var made = 0
        public var failed = 0
        /// Photos still without their thumbnails.
        public var remaining = 0
        /// Stopped before the end (conditions, background time, the setting turned off).
        public var stopped = false
    }

    let services: AccountServices
    let store: CacheFillStore
    private let settings: @Sendable () -> (enabled: Bool, allowsCellular: Bool)
    private let excludedFolders: @Sendable () async -> [String]
    private let logger = Logger(subsystem: "com.nextcloud.photos", category: "thumbnails")
    private let pathMonitor = NWPathMonitor()
    private var running: Task<Outcome, Never>?
    private var isShutDown = false
    /// When the pipeline was last seen busy.
    private var lastBusyAt: Date?
    private let state = Mutex(Progress())

    /// Tests set the conditions instead of reading the real ones.
    var networkOverride: NetworkConditions?
    var lowPowerOverride: Bool?
    var pipelineIdleOverride: (@Sendable () async -> Bool)?
    var quietPeriod = FillPacing.quietPeriod

    public static let pageSize = 500
    /// Downloads at a time: the grid has six network lanes; two in the background leave the server room for them.
    public static let concurrency = 2
    static let previewBucket = 256
    static let smallBucket = 64

    public init(
        services: AccountServices,
        settings: @escaping @Sendable () -> (enabled: Bool, allowsCellular: Bool) = {
            (LibraryThumbnailSettings.isEnabled(), LibraryThumbnailSettings.allowsCellular())
        },
        excludedFolders: @escaping @Sendable () async -> [String] = { [] }
    ) {
        self.services = services
        self.store = CacheFillStore(database: services.database)
        self.settings = settings
        self.excludedFolders = excludedFolders
        pathMonitor.start(queue: DispatchQueue(label: "com.nextcloud.photos.thumbnails.path"))
    }

    /// The progress for Settings (any thread).
    public nonisolated var progress: Progress { state.withLock { $0 } }

    func setConditions(
        network: NetworkConditions?, lowPower: Bool?, pipelineIdle: (@Sendable () async -> Bool)? = nil, quiet: TimeInterval? = nil
    ) {
        networkOverride = network
        lowPowerOverride = lowPower
        pipelineIdleOverride = pipelineIdle
        if let quiet { quietPeriod = quiet }
    }

    // MARK: Conditions

    var network: NetworkConditions { networkOverride ?? NetworkConditions(pathMonitor.currentPath) }
    var isLowPowerMode: Bool { lowPowerOverride ?? BackgroundPreparation.isLowPowerMode }

    private func pipelineIdle() async -> Bool {
        if let pipelineIdleOverride { return await pipelineIdleOverride() }
        return await services.images.isNetworkIdle
    }

    /// Waits until the next download may start; false when the pass is to stop.
    private func waitForTurn(_ shouldContinue: @Sendable () -> Bool) async -> Bool {
        while true {
            guard shouldContinue(), !Task.isCancelled, !isShutDown, settings().enabled else { return false }
            let idle = await pipelineIdle()
            let now = Date()
            if !idle { lastBusyAt = now }
            let network = network
            let conditions = FillConditions(
                isConnected: network.isConnected, isExpensive: network.isExpensive, isConstrained: network.isConstrained,
                isLowPowerMode: isLowPowerMode, allowsExpensive: settings().allowsCellular, pipelineIdle: idle,
                idleFor: lastBusyAt.map { now.timeIntervalSince($0) } ?? .infinity)
            switch FillPacing.decide(conditions, quietPeriod: quietPeriod) {
            case .go:
                return true
            case .stop:
                state.withLock { $0.isWaitingForConditions = true }
                return false
            case .wait(let seconds):
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    // MARK: Passes

    /// Runs a pass over the whole library; a call while a pass runs waits for that pass.
    ///
    /// - Parameter shouldContinue: checked before every download; false stops the pass (the background time is over).
    @discardableResult
    public func run(shouldContinue: @escaping @Sendable () -> Bool = { true }) async -> Outcome {
        guard !isShutDown else { return Outcome() }
        if let running { return await running.value }
        let task = Task { await self.pass(shouldContinue: shouldContinue) }
        running = task
        let outcome = await task.value
        running = nil
        return outcome
    }

    /// The photos whose thumbnails are kept and the space they take: shown before the setting is turned on. Uses the sizes
    /// of previews this device has cached, else typical ones (`LibraryThumbnailPlan.typicalBytes`).
    public func estimate() async -> (photos: Int, bytes: Int64) {
        let excluded = await excludedFolders()
        let photos = (try? await store.libraryCount(excludedFolders: excluded)) ?? 0
        let cache = services.images.cache
        let averages = await Task.detached(priority: .utility) {
            cache.averageFileSizes(buckets: LibraryThumbnailPlan.buckets)
        }.value
        return (photos, LibraryThumbnailPlan.estimatedBytes(photos: photos, averages: averages))
    }

    /// Counts what is on the device without downloading anything (Settings, before the first pass).
    public func count() async {
        guard running == nil else { return }
        let excluded = await excludedFolders()
        var total = 0
        var done = 0
        var cursor: CacheFillStore.Cursor?
        let cache = services.images.cache
        while !Task.isCancelled, let page = try? await store.libraryPage(after: cursor, limit: Self.pageSize, excludedFolders: excluded),
            let last = page.last
        {
            cursor = CacheFillStore.Cursor(timestamp: last.timestamp, fileId: last.fileId)
            total += page.count
            done += page.filter { Self.isFilled($0, cache: cache) }.count
        }
        state.withLock {
            $0.total = total
            $0.done = done
            $0.countedAt = Date()
        }
    }

    private func pass(shouldContinue: @escaping @Sendable () -> Bool) async -> Outcome {
        var outcome = Outcome()
        guard settings().enabled else { return outcome }
        let excluded = await excludedFolders()
        let cache = services.images.cache
        let api = services.api
        let total = (try? await store.libraryCount(excludedFolders: excluded)) ?? 0
        state.withLock {
            $0.isRunning = true
            $0.isWaitingForConditions = false
            $0.total = total
        }
        defer { state.withLock { $0.isRunning = false } }
        var done = 0
        var seen = 0
        var cursor: CacheFillStore.Cursor?
        do {
            while !outcome.stopped {
                let page = try await store.libraryPage(after: cursor, limit: Self.pageSize, excludedFolders: excluded)
                guard let last = page.last else { break }
                cursor = CacheFillStore.Cursor(timestamp: last.timestamp, fileId: last.fileId)
                seen += page.count
                var missing: [CacheFillStore.Photo] = []
                for photo in page {
                    if Self.isFilled(photo, cache: cache) { done += 1 } else { missing.append(photo) }
                }
                let counted = done
                state.withLock {
                    $0.done = counted
                    $0.total = max(total, seen)
                }
                let filled = await fill(missing, cache: cache, api: api, shouldContinue: shouldContinue, outcome: &outcome)
                done += filled
            }
        } catch {
            logger.error("thumbnail pass failed: \(error.localizedDescription, privacy: .public)")
            outcome.stopped = true
        }
        outcome.remaining = max(0, max(total, seen) - done)
        let finalDone = done
        state.withLock {
            $0.done = finalDone
            if !outcome.stopped { $0.total = seen }
            $0.countedAt = Date()
        }
        logger.info(
            "thumbnail pass: \(outcome.downloaded) downloaded, \(outcome.made) made, \(outcome.failed) failed, \(outcome.remaining) remaining"
        )
        return outcome
    }

    /// Fills the thumbnails of these photos, at most `concurrency` at a time; returns how many were completed.
    private func fill(
        _ photos: [CacheFillStore.Photo], cache: PreviewCache, api: PhotosAPI, shouldContinue: @escaping @Sendable () -> Bool,
        outcome: inout Outcome
    ) async -> Int {
        var completed = 0
        var tally = outcome
        await withTaskGroup(of: FillResult.self) { group in
            var next = 0
            var inFlight = 0
            while true {
                while next < photos.count, inFlight < Self.concurrency, !tally.stopped {
                    let photo = photos[next]
                    // Only the 64 px one is missing: made from the 256 px file, without the network.
                    let needsNetwork = !cache.hasDiskImage(fileId: photo.fileId, etag: photo.etag, bucket: Self.previewBucket)
                    if needsNetwork, !(await waitForTurn(shouldContinue)) {
                        tally.stopped = true
                        break
                    }
                    next += 1
                    inFlight += 1
                    group.addTask { await Self.fill(photo, cache: cache, api: api) }
                }
                guard inFlight > 0, let result = await group.next() else { break }
                inFlight -= 1
                if result.downloaded { tally.downloaded += 1 }
                if result.made { tally.made += 1 }
                if result.failed {
                    tally.failed += 1
                } else {
                    completed += 1
                    state.withLock { $0.done += 1 }
                }
            }
        }
        outcome = tally
        return completed
    }

    struct FillResult: Sendable {
        var downloaded = false
        var made = false
        var failed = false
    }

    /// Both thumbnails of the photo are in the disk cache.
    static func isFilled(_ photo: CacheFillStore.Photo, cache: PreviewCache) -> Bool {
        cache.hasDiskImage(fileId: photo.fileId, etag: photo.etag, bucket: previewBucket)
            && cache.hasDiskImage(fileId: photo.fileId, etag: photo.etag, bucket: smallBucket)
    }

    /// Downloads the 256 px preview unless it is cached (a lossless one is stored as HEIC) and makes the 64 px one from it.
    static func fill(_ photo: CacheFillStore.Photo, cache: PreviewCache, api: PhotosAPI) async -> FillResult {
        var result = FillResult()
        var data = cache.diskData(fileId: photo.fileId, etag: photo.etag, bucket: previewBucket)
        if data == nil {
            guard let downloaded = try? await api.preview(fileId: photo.fileId, size: previewBucket, etag: photo.etag),
                PreviewTranscoding.type(of: downloaded) != nil
            else {
                result.failed = true
                return result
            }
            let stored = PreviewTranscoding.storage(for: downloaded).data
            guard cache.storeFile(stored, fileId: photo.fileId, etag: photo.etag, bucket: previewBucket) else {
                result.failed = true
                return result
            }
            data = downloaded
            result.downloaded = true
        }
        if !cache.hasDiskImage(fileId: photo.fileId, etag: photo.etag, bucket: smallBucket) {
            guard let data, let small = ImageDecoding.smallerPreview(from: data, maxPixelSize: smallBucket),
                cache.storeFile(small, fileId: photo.fileId, etag: photo.etag, bucket: smallBucket)
            else {
                result.failed = true
                return result
            }
            result.made = true
        }
        return result
    }

    /// Stops a running pass and waits for it (account switch, removal).
    public func shutdown() async {
        isShutDown = true
        pathMonitor.cancel()
        running?.cancel()
        _ = await running?.value
    }

    /// The setting was turned off: a running pass stops before its next download.
    public func stop() async {
        running?.cancel()
        _ = await running?.value
    }
}
