// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import OSLog
import Synchronization

/// Where a preview came from (SPEC §18.1.3).
public enum CacheLayer: Int, Sendable, CaseIterable, Codable {
    /// Decoded, in the memory cache.
    case memory
    /// The disk cache (`Library/Caches/Previews`).
    case disk
    /// A preview kept by smart offline (SPEC §15.8.1).
    case smartOffline
    /// Thumbnailed from the original of an offline album.
    case offline
    /// Downloaded from the server (or thumbnailed from a downloaded original).
    case network
    /// Not loaded: an error, a file without a preview, or given up.
    case failed
}

/// Counts where previews come from and how long pictures take to appear, for the diagnostics screen and Instruments
/// (SPEC §18.1.3, §10 budgets).
///
/// Cheap enough to stay on in release builds: an event is a few additions under an uncontended `Mutex` (an
/// `os_unfair_lock`, held for nanoseconds, never across a suspension), with no allocation — the time samples go into
/// fixed ring buffers. An actor would cost a task and a hop per event, which is more than the event itself. Signpost
/// intervals are only begun while Instruments records them (`OSSignposter.isEnabled`).
public final class CacheMetrics: Sendable {
    /// The app's metrics; the pipeline and the views record here. Tests make their own.
    public static let shared = CacheMetrics()

    /// The picture a time-to-show sample is about.
    public enum Timing: Int, Sendable, CaseIterable, Codable {
        /// A grid tile: from its configuration to its first real picture (the BlurHash does not count).
        case tile
        /// A viewer page: from becoming the current page to its first real picture of any size.
        case viewerFirst
        /// A viewer page: from becoming the current page to the preview it asked for (1024 px).
        case viewerFull
    }

    /// The preview sizes counted separately (`PhotosAPI.previewBuckets`); any other size counts as the next larger one.
    public static let buckets = [64, 256, 1024, 4096]
    /// Time samples kept per timing; older ones are overwritten.
    public static let sampleCapacity = 1024

    struct Counters {
        /// Loads somebody waited for, by `layer * buckets.count + bucket index`.
        var demand: [Int]
        /// Loads only a prefetch asked for, the same way.
        var prefetch: [Int]
        /// Ring buffers of milliseconds, one per `Timing`.
        var samples: [[Double]]
        var sampleCounts: [Int]
        var since: Date

        init(now: Date = Date()) {
            let cells = CacheLayer.allCases.count * CacheMetrics.buckets.count
            demand = Array(repeating: 0, count: cells)
            prefetch = Array(repeating: 0, count: cells)
            samples = Array(
                repeating: Array(repeating: 0, count: CacheMetrics.sampleCapacity), count: Timing.allCases.count)
            sampleCounts = Array(repeating: 0, count: Timing.allCases.count)
            since = now
        }
    }

    private let counters = Mutex(Counters())
    /// Intervals for Instruments' os_signpost instrument: "Preview" (one load), "Tile" and "Viewer" (time to show).
    public let signposter = OSSignposter(subsystem: "com.nextcloud.photos", category: "cache")

    public init() {}

    static func bucketIndex(_ bucket: Int) -> Int {
        buckets.firstIndex { bucket <= $0 } ?? buckets.count - 1
    }

    // MARK: Recording

    /// A preview was served from `layer`.
    /// - Parameter prefetch: only a prefetch asked for it (nobody waited); kept apart from the hit rate.
    public func record(_ layer: CacheLayer, bucket: Int, prefetch: Bool = false) {
        let cell = layer.rawValue * Self.buckets.count + Self.bucketIndex(bucket)
        counters.withLock { counters in
            if prefetch {
                counters.prefetch[cell] += 1
            } else {
                counters.demand[cell] += 1
            }
        }
    }

    /// A time to show was measured.
    public func record(_ timing: Timing, milliseconds: Double) {
        counters.withLock { counters in
            let index = counters.sampleCounts[timing.rawValue] % Self.sampleCapacity
            counters.samples[timing.rawValue][index] = milliseconds
            counters.sampleCounts[timing.rawValue] += 1
        }
    }

    /// Started when a picture is wanted; `finish` records the time it took.
    public struct ShowTimer: Sendable {
        public let timing: Timing
        let start: ContinuousClock.Instant
        let interval: OSSignpostIntervalState?
    }

    public func begin(_ timing: Timing) -> ShowTimer {
        var interval: OSSignpostIntervalState?
        if signposter.isEnabled {
            interval = signposter.beginInterval(timing == .tile ? "Tile" : "Viewer", id: signposter.makeSignpostID())
        }
        return ShowTimer(timing: timing, start: .now, interval: interval)
    }

    /// The picture is shown.
    public func finish(_ timer: ShowTimer) {
        let elapsed = ContinuousClock.now - timer.start
        if let interval = timer.interval {
            signposter.endInterval(timer.timing == .tile ? "Tile" : "Viewer", interval)
        }
        let components = elapsed.components
        record(timer.timing, milliseconds: Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15)
        // Launch → first pictures of the Library (SPEC §10, §20.6); only the app's metrics, not a test's own.
        if timer.timing == .tile, self === Self.shared { LaunchMetrics.shared.tileShown() }
    }

    /// Starts counting again from zero.
    public func reset(now: Date = Date()) {
        counters.withLock { $0 = Counters(now: now) }
    }

    // MARK: Reading

    /// The numbers at one moment, for the diagnostics screen and the before/after measurements.
    public struct Snapshot: Sendable, Codable, Equatable {
        public struct Layer: Sendable, Codable, Equatable {
            public var layer: CacheLayer
            /// Waited-for loads per bucket (`CacheMetrics.buckets`).
            public var demand: [Int]
            /// Prefetch-only loads per bucket.
            public var prefetch: [Int]
            public var demandTotal: Int { demand.reduce(0, +) }
        }

        public struct Times: Sendable, Codable, Equatable {
            public var timing: Timing
            public var count: Int
            public var p50: Double?
            public var p95: Double?
        }

        public var since: Date
        public var layers: [Layer]
        public var times: [Times]

        /// Waited-for previews that were not loaded from the network (or failed), of all waited-for previews.
        public var hitRate: Double? {
            let total = layers.reduce(0) { $0 + $1.demandTotal }
            guard total > 0 else { return nil }
            let local = layers.filter { [.memory, .disk, .smartOffline, .offline].contains($0.layer) }.reduce(0) { $0 + $1.demandTotal }
            return Double(local) / Double(total)
        }

        /// The same for one bucket.
        public func hitRate(bucket: Int) -> Double? {
            let index = CacheMetrics.bucketIndex(bucket)
            let total = layers.reduce(0) { $0 + $1.demand[index] }
            guard total > 0 else { return nil }
            let local = layers.filter { [.memory, .disk, .smartOffline, .offline].contains($0.layer) }.reduce(0) {
                $0 + $1.demand[index]
            }
            return Double(local) / Double(total)
        }

        public func layer(_ layer: CacheLayer) -> Layer? { layers.first { $0.layer == layer } }
        public func times(_ timing: Timing) -> Times? { times.first { $0.timing == timing } }
    }

    public func snapshot() -> Snapshot {
        let counters = counters.withLock { $0 }
        let width = Self.buckets.count
        let layers = CacheLayer.allCases.map { layer in
            let range = layer.rawValue * width..<(layer.rawValue + 1) * width
            return Snapshot.Layer(layer: layer, demand: Array(counters.demand[range]), prefetch: Array(counters.prefetch[range]))
        }
        let times = Timing.allCases.map { timing in
            let count = counters.sampleCounts[timing.rawValue]
            let kept = Array(counters.samples[timing.rawValue].prefix(min(count, Self.sampleCapacity))).sorted()
            return Snapshot.Times(
                timing: timing, count: count, p50: Self.percentile(0.5, of: kept), p95: Self.percentile(0.95, of: kept))
        }
        return Snapshot(since: counters.since, layers: layers, times: times)
    }

    /// Nearest-rank percentile of sorted values.
    static func percentile(_ p: Double, of sorted: [Double]) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let rank = Int((p * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    /// Writes the snapshot as JSON (diagnostics, and the before/after measurements in the simulator).
    public func write(to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot()) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// How much the caches of an account hold, per preview size and pool (SPEC §18.1.3). Computed by scanning the
/// directories, off the main thread.
public struct CacheUsage: Sendable, Equatable {
    /// Disk cache bytes and files per bucket (`CacheMetrics.buckets`); the last entry also holds unknown sizes.
    public var previewBytes: [Int64]
    public var previewFiles: [Int]
    public var smartOfflineBytes: Int64 = 0
    public var smartOfflineFiles = 0
    public var offlineBytes: Int64 = 0
    public var originalBytes: Int64 = 0

    public init() {
        previewBytes = Array(repeating: 0, count: CacheMetrics.buckets.count)
        previewFiles = Array(repeating: 0, count: CacheMetrics.buckets.count)
    }

    public var previewTotal: Int64 { previewBytes.reduce(0, +) }

    /// The bucket of a preview cache file: `<fileId>-<etag>-<bucket>.<ext>`.
    static func bucket(ofCacheFile name: Substring) -> Int? {
        let stem = name.prefix { $0 != "." }
        guard let dash = stem.lastIndex(of: "-") else { return nil }
        return Int(stem[stem.index(after: dash)...])
    }

    /// Scans the directories. Blocking; call it from a background task.
    public static func scan(previews: URL, smartOffline: URL?, offline: URL?, originals: URL?) -> CacheUsage {
        var usage = CacheUsage()
        for (url, size) in files(in: previews) {
            let index = bucket(ofCacheFile: url.lastPathComponent[...]).map(CacheMetrics.bucketIndex) ?? CacheMetrics.buckets.count - 1
            usage.previewBytes[index] += size
            usage.previewFiles[index] += 1
        }
        if let smartOffline {
            for (_, size) in files(in: smartOffline) {
                usage.smartOfflineBytes += size
                usage.smartOfflineFiles += 1
            }
        }
        if let offline { usage.offlineBytes = files(in: offline).reduce(0) { $0 + $1.1 } }
        if let originals { usage.originalBytes = files(in: originals).reduce(0) { $0 + $1.1 } }
        return usage
    }

    static func files(in directory: URL) -> [(URL, Int64)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return [] }
        var result: [(URL, Int64)] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            result.append((url, Int64(values.fileSize ?? 0)))
        }
        return result
    }
}
