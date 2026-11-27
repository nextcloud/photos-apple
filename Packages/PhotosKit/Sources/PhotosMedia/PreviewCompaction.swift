// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import ImageIO
import OSLog
import Synchronization
import UniformTypeIdentifiers

/// Stores the lossless previews of the screen and large pools (1024 px and up) as HEIC, in the background (SPEC §22.4.4).
///
/// The server sends PNG previews of PNG files (screenshots, graphics): 1–9 MB each at these sizes. The pipeline stores
/// what it downloads as it comes (converting there would slow the load the user waits for); this converts such files
/// afterwards, one at a time at background priority, while the pipeline downloads nothing. A file keeps its name (the
/// cache reads by content) and its modification date (the cache's "last used"), and keeps its transparency (HEIC with
/// alpha); it is replaced only when the HEIC is smaller. JPEG previews are left alone (§18.3.3: not smaller at the same
/// fidelity).
public final class PreviewCompactor: Sendable {
    public let directory: URL
    /// The pipeline is loading from the server: the compactor waits.
    private let isBusy = Mutex<(@Sendable () async -> Bool)?>(nil)
    private let state = Mutex(State())
    private let logger = Logger(subsystem: "com.nextcloud.photos", category: "images")

    struct State {
        var pending: [URL] = []
        var queued: Set<URL> = []
        var running = false
        var scanned = false
        var totals = Totals()
    }

    /// What was converted in this process (Settings › Server › Cache performance, tests).
    public struct Totals: Sendable, Equatable {
        public var files = 0
        public var bytesBefore: Int64 = 0
        public var bytesAfter: Int64 = 0
    }

    /// The smallest bucket that is converted: the thumbnail pools are filled as HEIC already (§18.3.3).
    public static let minimumBucket = 1024
    /// The wait after a preview was stored before the conversion starts, and between two files.
    let startDelay: Duration
    static let pause: Duration = .milliseconds(30)
    /// The `UserDefaults` key that says this cache was looked through once (files stored later are queued as they come).
    var scanKey: String { "previewLosslessScan.v1:" + directory.path(percentEncoded: false) }

    public init(directory: URL, startDelay: Duration = .seconds(3)) {
        self.directory = directory
        self.startDelay = startDelay
    }

    public func setBusyCheck(_ check: (@Sendable () async -> Bool)?) {
        isBusy.withLock { $0 = check }
    }

    public var totals: Totals { state.withLock { $0.totals } }

    // MARK: What is converted

    /// The first bytes of a lossless still image (PNG, TIFF, BMP).
    public static func isLossless(prefix data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(8))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return true }  // PNG
        if bytes.starts(with: [0x49, 0x49, 0x2A, 0x00]) || bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return true }  // TIFF
        return bytes.starts(with: [0x42, 0x4D])  // BMP
    }

    static func isLossless(file url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return isLossless(prefix: (try? handle.read(upToCount: 8)) ?? Data())
    }

    /// A cache file of a bucket that is converted (`<fileId>-<etag>-<bucket>.jpg`).
    static func isCandidate(_ url: URL) -> Bool {
        guard let bucket = PreviewCache.parse(cacheFile: url)?.bucket else { return false }
        return bucket >= minimumBucket
    }

    /// Converts one file in place. Returns the sizes before and after, nil when it was left as it is (not lossless, HEIC
    /// not smaller, transparency that would be lost, gone meanwhile).
    @discardableResult
    public static func compact(file url: URL, quality: Double = PreviewTranscoding.heicQuality) -> (before: Int, after: Int)? {
        let manager = FileManager.default
        guard isLossless(file: url), let data = try? Data(contentsOf: url, options: .mappedIfSafe),
            let heic = PreviewTranscoding.heic(from: data, quality: quality)
        else { return nil }
        // The encoder leaves out an alpha channel that is opaque everywhere; one that is not must come along.
        if hasAlpha(data), !hasAlpha(heic), !isOpaque(data) { return nil }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let temporary = url.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).tmp")
        do {
            try heic.write(to: temporary)
            if let modified {
                try manager.setAttributes([.modificationDate: modified], ofItemAtPath: temporary.path(percentEncoded: false))
            }
            // Removed meanwhile (a trim): not brought back.
            guard manager.fileExists(atPath: url.path(percentEncoded: false)) else {
                try? manager.removeItem(at: temporary)
                return nil
            }
            _ = try manager.replaceItemAt(url, withItemAt: temporary)
            return (data.count, heic.count)
        } catch {
            try? manager.removeItem(at: temporary)
            return nil
        }
    }

    /// Every pixel is opaque (decoded into a grey-and-alpha bitmap: two bytes a pixel).
    static func isOpaque(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
            let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 2,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let pixels = context.data
        else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = UnsafeBufferPointer(start: pixels.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 2)
        return !stride(from: 1, to: bytes.count, by: 2).contains { bytes[$0] != 255 }
    }

    static func hasAlpha(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return false }
        return (properties[kCGImagePropertyHasAlpha] as? Bool) ?? false
    }

    // MARK: Queue

    /// A preview was stored: converted a few seconds later when it is lossless (the pipeline calls this with the data
    /// it wrote, so nothing is read here).
    public func didStore(_ url: URL, data: Data, bucket: Int) {
        guard bucket >= Self.minimumBucket, Self.isLossless(prefix: data) else { return }
        enqueue([url])
    }

    func enqueue(_ urls: [URL]) {
        let start = state.withLock { state -> Bool in
            for url in urls where state.queued.insert(url).inserted { state.pending.append(url) }
            guard !state.running, !state.pending.isEmpty else { return false }
            state.running = true
            return true
        }
        if start { Task.detached(priority: .background) { [self] in await drain() } }
    }

    /// Looks through the cache once (the first launch with this version): earlier lossless previews are queued.
    /// - Parameter suiteName: the `UserDefaults` suite of the marker (tests); the standard defaults when nil.
    public func scanOnce(suiteName: String? = nil) {
        let key = scanKey
        let defaults = Self.defaults(suiteName)
        let go = state.withLock { state -> Bool in
            guard !state.scanned else { return false }
            state.scanned = true
            return true
        }
        guard go, !defaults.bool(forKey: key) else { return }
        Task.detached(priority: .background) { [self] in
            let found = Self.losslessFiles(in: directory)
            Self.defaults(suiteName).set(true, forKey: key)
            if !found.isEmpty { logger.info("previews: \(found.count) lossless files to convert to HEIC") }
            enqueue(found)
        }
    }

    static func defaults(_ suiteName: String?) -> UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    static func losslessFiles(in directory: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return [] }
        var found: [URL] = []
        for case let url as URL in enumerator where isCandidate(url) && isLossless(file: url) { found.append(url) }
        return found
    }

    private func drain() async {
        try? await Task.sleep(for: startDelay)
        while let url = state.withLock({ state -> URL? in
            guard !state.pending.isEmpty else {
                state.running = false
                return nil
            }
            let url = state.pending.removeFirst()
            state.queued.remove(url)
            return url
        }) {
            // Not while previews are downloaded for the screen: the conversion takes a core for up to a second.
            if let busy = isBusy.withLock({ $0 }) {
                var waited = 0
                while await busy(), waited < 600 {
                    try? await Task.sleep(for: .milliseconds(500))
                    waited += 1
                }
            }
            if let sizes = Self.compact(file: url) {
                state.withLock { state in
                    state.totals.files += 1
                    state.totals.bytesBefore += Int64(sizes.before)
                    state.totals.bytesAfter += Int64(sizes.after)
                }
            }
            try? await Task.sleep(for: Self.pause)
        }
        let totals = self.totals
        if totals.files > 0 {
            logger.info("previews: \(totals.files) converted to HEIC, \(totals.bytesBefore) → \(totals.bytesAfter) bytes")
        }
    }

    /// Waits until the queue is empty (tests).
    func waitUntilIdle() async {
        while state.withLock({ $0.running || !$0.pending.isEmpty }) { try? await Task.sleep(for: .milliseconds(20)) }
    }
}
