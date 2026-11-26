// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import ImageIO
import PhotosDomain
import PhotosModel

/// The "Keep thumbnails of the whole library" setting (SPEC §18.3.1). Per device, for every account.
///
/// While it is on, the preview cache keeps the 64 and 256 px previews of every photo in the library and does not count
/// them against its budgets (the evict side of the contract, SPEC §18.2); off, they are ordinary cache files.
public enum LibraryThumbnailSettings {
    /// `CacheLimits.wholeLibraryThumbnailsKey`.
    public static var enabledKey: String { CacheLimits.wholeLibraryThumbnailsKey }
    /// Thumbnails may be downloaded on cellular and personal hotspots too.
    public static let cellularKey = "cacheWholeLibraryThumbnailsOnCellular"

    /// Whether the thumbnails of the whole library are kept; the platform's default until the user chose
    /// (`LibraryThumbnailPlan.defaultEnabled`: on on the Mac). Read the key through this, not `bool(forKey:)`.
    public static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: enabledKey) as? Bool) ?? LibraryThumbnailPlan.defaultEnabled
    }

    public static func allowsCellular(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: cellularKey)
    }

    /// Makes `bool(forKey:)` of the key return the platform's default too (registration domain, not saved). Called at
    /// launch, so code that reads the key directly sees the same value as `isEnabled`.
    public static func registerDefault(_ defaults: UserDefaults = .standard) {
        defaults.register(defaults: [enabledKey: LibraryThumbnailPlan.defaultEnabled])
    }
}

// MARK: - Shared helpers of the cache fillers (fill, SPEC §18.3)
//
// Fillers write whole previews to the disk cache without decoding them: what they fill is not on screen, and decoding it
// into the memory cache would push out what is.

extension PreviewCache {
    /// Writes an encoded preview into the disk cache, where `diskImage` and `hasDiskImage` find it. Nothing is decoded and
    /// the memory cache is not touched. Returns false when the file could not be written.
    @discardableResult
    public func storeFile(_ data: Data, fileId: FileID, etag: String, bucket: Int) -> Bool {
        let url = fileURL(key: Self.key(fileId: fileId, etag: etag, bucket: bucket))
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// The encoded preview from the disk cache, without touching the memory cache or the file's "last used" date.
    public func diskData(fileId: FileID, etag: String, bucket: Int) -> Data? {
        try? Data(contentsOf: fileURL(key: Self.key(fileId: fileId, etag: etag, bucket: bucket)))
    }

    /// Average size of the cached previews of these buckets, from at most `sample` files each; a bucket with fewer than
    /// `minimum` files has none. Reads only directory entries; off the main thread.
    public func averageFileSizes(buckets: [Int], sample: Int = 300, minimum: Int = 30) -> [Int: Int64] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return [:]
        }
        let suffixes = Dictionary(uniqueKeysWithValues: buckets.map { ("-\($0).jpg", $0) })
        var sums: [Int: (bytes: Int64, count: Int)] = [:]
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            // A cache of 100 000 files is not walked for an estimate.
            if visited > 20_000 { break }
            let name = url.lastPathComponent
            guard let dash = name.lastIndex(of: "-"), let bucket = suffixes[String(name[dash...])],
                sums[bucket, default: (0, 0)].count < sample,
                let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            else { continue }
            sums[bucket, default: (0, 0)].bytes += Int64(size)
            sums[bucket, default: (0, 0)].count += 1
            if suffixes.values.allSatisfy({ sums[$0, default: (0, 0)].count >= sample }) { break }
        }
        return sums.compactMapValues { $0.count >= max(1, minimum) ? $0.bytes / Int64($0.count) : nil }
    }
}

extension ImageDecoding {
    /// A smaller preview made from a larger one (64 px from a 256 px preview), as JPEG; aspect-fit like the server's.
    public static func smallerPreview(from data: Data, maxPixelSize: Int) -> Data? {
        guard let image = decode(data: data, maxPixelSize: maxPixelSize) else { return nil }
        return jpegData(image)
    }
}
