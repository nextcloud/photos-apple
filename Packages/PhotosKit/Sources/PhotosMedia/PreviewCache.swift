// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import ImageIO
import PhotosModel

/// Wraps a `CGImage` for `NSCache`.
final class ImageBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

/// Disk + memory cache of preview images keyed by `(fileId, etag, bucket)` (SPEC §5.5.1).
public final class PreviewCache: @unchecked Sendable {
    public let directory: URL
    private let memory = NSCache<NSString, ImageBox>()
    private let fileManager = FileManager.default
    private let ioQueue = DispatchQueue(label: "com.nextcloud.photos.previewcache", qos: .utility)

    public init(directory: URL, memoryLimitBytes: Int = 200 * 1024 * 1024) {
        self.directory = directory
        memory.totalCostLimit = memoryLimitBytes
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static func key(fileId: FileID, etag: String, bucket: Int) -> String {
        "\(fileId)-\(etag.isEmpty ? "0" : etag)-\(bucket)"
    }

    func fileURL(key: String) -> URL {
        // Shard by the last two digits of the file id to keep directories small.
        let shard = String(key.prefix(while: { $0 != "-" }).suffix(2))
        return directory.appending(path: shard).appending(path: key + ".jpg")
    }

    /// Memory-only lookup (fast path for cell configuration).
    public func memoryImage(fileId: FileID, etag: String, bucket: Int) -> CGImage? {
        memory.object(forKey: Self.key(fileId: fileId, etag: etag, bucket: bucket) as NSString)?.image
    }

    /// Best image already in memory with at least `minBucket` (or any smaller one as placeholder).
    public func bestMemoryImage(fileId: FileID, etag: String, upTo bucket: Int) -> CGImage? {
        for size in [4096, 1024, 256, 64] where size <= bucket {
            if let image = memoryImage(fileId: fileId, etag: etag, bucket: size) { return image }
        }
        return nil
    }

    public func diskImage(fileId: FileID, etag: String, bucket: Int) -> CGImage? {
        let key = Self.key(fileId: fileId, etag: etag, bucket: bucket)
        let url = fileURL(key: key)
        guard let image = ImageDecoding.decode(url: url, maxPixelSize: bucket) else { return nil }
        // Touch for LRU.
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path(percentEncoded: false))
        remember(image, key: key)
        return image
    }

    public func hasDiskImage(fileId: FileID, etag: String, bucket: Int) -> Bool {
        fileManager.fileExists(atPath: fileURL(key: Self.key(fileId: fileId, etag: etag, bucket: bucket)).path(percentEncoded: false))
    }

    /// Stores encoded image data and returns the decoded image.
    @discardableResult
    public func store(_ data: Data, fileId: FileID, etag: String, bucket: Int) -> CGImage? {
        let key = Self.key(fileId: fileId, etag: etag, bucket: bucket)
        let url = fileURL(key: key)
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        guard let image = ImageDecoding.decode(data: data, maxPixelSize: bucket) else { return nil }
        remember(image, key: key)
        return image
    }

    /// Stores a locally generated image (e.g. a thumbnail of a HEIC original without server preview).
    @discardableResult
    public func store(_ image: CGImage, fileId: FileID, etag: String, bucket: Int) -> CGImage {
        if let data = ImageDecoding.jpegData(image) { return store(data, fileId: fileId, etag: etag, bucket: bucket) ?? image }
        return image
    }

    func remember(_ image: CGImage, key: String) {
        memory.setObject(ImageBox(image), forKey: key as NSString, cost: image.bytesPerRow * image.height)
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

    /// Deletes least-recently-used files until the cache is below `limit` bytes.
    public func trim(toBytes limit: Int64) {
        ioQueue.async { [self] in
            guard
                let enumerator = fileManager.enumerator(
                    at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
            else { return }
            var files: [(URL, Int64, Date)] = []
            var total: Int64 = 0
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]), let size = values.fileSize
                else {
                    continue
                }
                files.append((url, Int64(size), values.contentModificationDate ?? .distantPast))
                total += Int64(size)
            }
            guard total > limit else { return }
            for (url, size, _) in files.sorted(by: { $0.2 < $1.2 }) {
                try? fileManager.removeItem(at: url)
                total -= size
                if total <= limit { break }
            }
        }
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
