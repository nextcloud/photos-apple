// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import ImageIO
import PhotosModel
import Synchronization

/// Wraps a `CGImage` for `NSCache`.
final class ImageBox: @unchecked Sendable {
    let image: CGImage
    /// The size limit it was decoded with (long edge in pixels). An image smaller than that is the whole preview.
    let maxPixelSize: Int
    init(_ image: CGImage, maxPixelSize: Int) {
        self.image = image
        self.maxPixelSize = maxPixelSize
    }
}

/// Disk + memory cache of preview images keyed by `(fileId, etag, bucket)` (SPEC §5.5.1).
public final class PreviewCache: @unchecked Sendable {
    public let directory: URL
    private let memory = NSCache<NSString, ImageBox>()
    private let fileManager = FileManager.default
    private let ioQueue = DispatchQueue(label: "com.nextcloud.photos.previewcache", qos: .utility)
    /// Fires when the system is short of memory (the notification behind `didReceiveMemoryWarning`, also on the Mac).
    private let memoryPressure: any DispatchSourceMemoryPressure
    /// Disk hits whose files' modification dates (the "last used" of `trim`) are not written yet.
    private let touches = Mutex(Touches())

    struct Touches {
        /// Keys already noted in this process: a file is touched at most once per run.
        var noted: Set<String> = []
        var pending: [URL] = []
        var flushScheduled = false
    }

    /// A file used again is only marked as used when its date is older than this: scrolling through 10 000 cached tiles
    /// then writes no metadata at all for the files used today.
    static let touchInterval: TimeInterval = 86_400
    /// Disk hits are written in batches, this long after the first one.
    static let touchDelay: TimeInterval = 5

    /// Downloaded previews after which the pipeline trims the disk cache again.
    public static let trimInterval = 2000

    /// Decoded previews kept in memory. The whole app has 300 MB while scrolling on an iPhone (SPEC §10), so there the
    /// cache gets about 1/80 of the device's memory, between 48 and 120 MB (77 MB with 6 GB, 102 MB with 8 GB); on iPad
    /// that is the upper bound. Mac and Vision Pro keep 200 MB.
    public static func defaultMemoryLimit(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int {
        #if os(iOS)
            return Int(min(max(physicalMemory / 80, 48 * 1024 * 1024), 120 * 1024 * 1024))
        #else
            return 200 * 1024 * 1024
        #endif
    }

    public init(directory: URL, memoryLimitBytes: Int = PreviewCache.defaultMemoryLimit()) {
        self.directory = directory
        memory.totalCostLimit = memoryLimitBytes
        memoryPressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: ioQueue)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        // Decoded previews are the largest thing the app can give back at once; they come back from disk when needed.
        memoryPressure.setEventHandler { [weak self] in self?.clearMemory() }
        memoryPressure.activate()
    }

    deinit { memoryPressure.cancel() }

    public var memoryLimitBytes: Int { memory.totalCostLimit }

    static func key(fileId: FileID, etag: String, bucket: Int) -> String {
        "\(fileId)-\(etag.isEmpty ? "0" : CacheFileName.etag(etag))-\(bucket)"
    }

    func fileURL(key: String) -> URL {
        // Shard by the last two digits of the file id to keep directories small.
        let shard = String(key.prefix(while: { $0 != "-" }).suffix(2))
        return directory.appending(path: shard).appending(path: key + ".jpg")
    }

    /// Memory-only lookup (fast path for cell configuration).
    ///
    /// Previews are decoded no larger than they are shown (`maxPixelSize`), so the image in memory may be smaller than
    /// its bucket: with `minPixelSize` only an image decoded with at least that limit counts.
    public func memoryImage(fileId: FileID, etag: String, bucket: Int, minPixelSize: Int = 0) -> CGImage? {
        guard let box = memory.object(forKey: Self.key(fileId: fileId, etag: etag, bucket: bucket) as NSString),
            box.maxPixelSize >= min(minPixelSize, bucket)
        else { return nil }
        return box.image
    }

    /// Best image already in memory with at least `minBucket` (or any smaller one as placeholder).
    public func bestMemoryImage(fileId: FileID, etag: String, upTo bucket: Int) -> CGImage? {
        for size in [4096, 1024, 256, 64] where size <= bucket {
            if let image = memoryImage(fileId: fileId, etag: etag, bucket: size) { return image }
        }
        return nil
    }

    /// Decodes a preview from disk, downsampled to `maxPixelSize` (long edge; the whole bucket when nil).
    public func diskImage(fileId: FileID, etag: String, bucket: Int, maxPixelSize: Int? = nil) -> CGImage? {
        let key = Self.key(fileId: fileId, etag: etag, bucket: bucket)
        let url = fileURL(key: key)
        let limit = Self.decodeLimit(maxPixelSize, bucket: bucket)
        guard let image = ImageDecoding.decode(url: url, maxPixelSize: limit) else { return nil }
        noteUse(url, key: key)
        remember(image, key: key, maxPixelSize: limit)
        return image
    }

    /// Remembers that a file was read, for the LRU order of `trim`: written later, in one batch, off the caller's thread.
    func noteUse(_ url: URL, key: String) {
        let schedule = touches.withLock { touches -> Bool in
            // Bounded: a long session over a huge library forgets what it noted (a file is then at most noted again).
            if touches.noted.count > 50_000 { touches.noted.removeAll(keepingCapacity: true) }
            guard touches.noted.insert(key).inserted else { return false }
            touches.pending.append(url)
            guard !touches.flushScheduled else { return false }
            touches.flushScheduled = true
            return true
        }
        if schedule {
            ioQueue.asyncAfter(deadline: .now() + Self.touchDelay) { [weak self] in self?.flushTouches() }
        }
    }

    /// Writes the noted uses: a file's modification date is set to now unless it is less than `touchInterval` old.
    /// Runs on the cache's queue (and in tests).
    func flushTouches(now: Date = Date()) {
        let urls = touches.withLock { touches -> [URL] in
            defer {
                touches.pending = []
                touches.flushScheduled = false
            }
            return touches.pending
        }
        for url in urls {
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if let modified, now.timeIntervalSince(modified) < Self.touchInterval { continue }
            try? fileManager.setAttributes([.modificationDate: now], ofItemAtPath: url.path(percentEncoded: false))
        }
    }

    /// The limit a preview of `bucket` is decoded with: the requested size, never more than the bucket.
    static func decodeLimit(_ maxPixelSize: Int?, bucket: Int) -> Int {
        guard let maxPixelSize, maxPixelSize > 0 else { return bucket }
        return min(maxPixelSize, bucket)
    }

    public func hasDiskImage(fileId: FileID, etag: String, bucket: Int) -> Bool {
        fileManager.fileExists(atPath: fileURL(key: Self.key(fileId: fileId, etag: etag, bucket: bucket)).path(percentEncoded: false))
    }

    /// Stores encoded image data (the whole preview) and returns the image decoded to `maxPixelSize` (the bucket when nil).
    @discardableResult
    public func store(_ data: Data, fileId: FileID, etag: String, bucket: Int, maxPixelSize: Int? = nil) -> CGImage? {
        let key = Self.key(fileId: fileId, etag: etag, bucket: bucket)
        let url = fileURL(key: key)
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        let limit = Self.decodeLimit(maxPixelSize, bucket: bucket)
        guard let image = ImageDecoding.decode(data: data, maxPixelSize: limit) else { return nil }
        remember(image, key: key, maxPixelSize: limit)
        return image
    }

    /// Stores a locally generated image (e.g. a thumbnail of a HEIC original without server preview).
    @discardableResult
    public func store(_ image: CGImage, fileId: FileID, etag: String, bucket: Int, maxPixelSize: Int? = nil) -> CGImage {
        if let data = ImageDecoding.jpegData(image) {
            return store(data, fileId: fileId, etag: etag, bucket: bucket, maxPixelSize: maxPixelSize) ?? image
        }
        return image
    }

    func remember(_ image: CGImage, key: String, maxPixelSize: Int) {
        // A larger decode already in memory serves this size too; don't replace it with a smaller one.
        if let existing = memory.object(forKey: key as NSString), existing.maxPixelSize > maxPixelSize { return }
        memory.setObject(
            ImageBox(image, maxPixelSize: maxPixelSize), forKey: key as NSString, cost: image.bytesPerRow * image.height)
    }

    public func clearMemory() { memory.removeAllObjects() }

    public func totalSize() -> Int64 {
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// Deletes least-recently-used files until the cache is below `limit` bytes, in the background.
    ///
    /// "Used" is the file's modification date: `diskImage` notes every read, and the notes are written in batches (a file
    /// used again on the same day keeps its date).
    /// - Parameters:
    ///   - protecting: files whose previews are never deleted (offline-pinned items); they still count towards the size.
    ///   - completion: called on the cache's queue when the trim is done.
    public func trim(toBytes limit: Int64, protecting: Set<FileID> = [], completion: (@Sendable () -> Void)? = nil) {
        ioQueue.async { [self] in
            trimNow(toBytes: limit, protecting: protecting)
            completion?()
        }
    }

    /// The trim itself. Returns the bytes left in the cache.
    @discardableResult
    func trimNow(toBytes limit: Int64, protecting: Set<FileID> = []) -> Int64 {
        // What was used since the last batch counts as used.
        flushTouches()
        guard
            let enumerator = fileManager.enumerator(
                at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
        else { return 0 }
        var files: [(URL, Int64, Date)] = []
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                values.isRegularFile == true, let size = values.fileSize
            else { continue }
            total += Int64(size)
            if !protecting.isEmpty, let fileId = Self.fileId(ofCacheFile: url), protecting.contains(fileId) { continue }
            files.append((url, Int64(size), values.contentModificationDate ?? .distantPast))
        }
        guard total > limit else { return total }
        for (url, size, _) in files.sorted(by: { $0.2 < $1.2 }) {
            try? fileManager.removeItem(at: url)
            total -= size
            if total <= limit { break }
        }
        return total
    }

    /// The file id a cache file belongs to (`<fileId>-<etag>-<bucket>.jpg`).
    static func fileId(ofCacheFile url: URL) -> FileID? {
        FileID(url.lastPathComponent.prefix(while: { $0 != "-" }))
    }

    public func removeAll() {
        memory.removeAllObjects()
        try? fileManager.removeItem(at: directory)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}

/// ImageIO helpers.
public enum ImageDecoding {
    public static func decode(data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        return thumbnail(source, maxPixelSize: maxPixelSize)
    }

    public static func decode(url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return thumbnail(source, maxPixelSize: maxPixelSize)
    }

    static func thumbnail(_ source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    public static func jpegData(_ image: CGImage, quality: Double = 0.8) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
