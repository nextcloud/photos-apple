// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import ImageIO
import PhotosModel
import Synchronization

/// Pre-rendered tiles of the Library (SPEC §22.4.1): every photo's picture at 128 px (short edge), one file per month
/// holding all of that month's tiles behind a small index, memory-mapped.
///
/// A tile is what a grid cell shows before (or instead of) its preview: in the first frame after a launch, while
/// flinging through 100 000 photos, and as the final picture at the small zoom steps (Months, Years). Looking one up is a
/// dictionary lookup in an index that is already in memory and a decode of about 9 KB of JPEG from mapped memory
/// (0.14 ms on an M-class Mac), with no file opened per photo and nothing waiting for the image pipeline. The month's
/// file is opened once and stays mapped (the system pages it in and out; it is not app memory).
///
/// Built in the background from the previews in the disk cache (`TileCacheBuilder`); a tile is valid for the ETag it
/// was made from (with an edit, the edited version's), so a changed photo just misses until the next build.
public final class TileCache: Sendable {
    /// The short edge of a tile in pixels; the long edge follows the photo's shape, at most `longEdgeLimit`.
    public static let shortEdge = 128
    public static let longEdgeLimit = 256
    /// JPEG quality of a tile: 9 KB on average for the test library's photos.
    public static let quality = 0.7
    /// The bucket decoded tiles are remembered under in the preview cache's memory (`PreviewCache.tileImage`).
    public static let memoryBucket = 128

    public let directory: URL
    private let blocks = Mutex<[String: Block]>([:])
    /// Months known to have no file (looked for once until the builder writes one).
    private let absent = Mutex<Set<String>>([])

    public init(directory: URL) {
        self.directory = directory
    }

    // MARK: Keys

    /// The month a photo's tile is filed under: its timeline date (`LibraryStore.timestamp`) in UTC, `2024-05`.
    public static func month(of timestamp: Double) -> String {
        let days = Int((timestamp / 86_400).rounded(.down))
        // Civil date from days since 1970 (Howard Hinnant's algorithm): no Calendar on the scrolling path.
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
        return String(format: "%04d-%02d", year, month)
    }

    /// FNV-1a of the ETag the tile was made for.
    public static func etagHash(_ etag: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in etag.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    func fileURL(month: String) -> URL { directory.appending(path: month + ".tiles") }

    // MARK: Reading

    /// One month's file: mapped data and its index.
    struct Block: Sendable {
        struct Entry: Sendable, Equatable {
            var etag: UInt64
            var offset: Int
            var length: Int
        }

        let data: Data
        let entries: [FileID: Entry]

        func tile(_ fileId: FileID, etag: UInt64) -> Data? {
            guard let entry = entries[fileId], entry.etag == etag else { return nil }
            return data.subdata(in: entry.offset..<(entry.offset + entry.length))
        }
    }

    /// The encoded tile of a photo, nil when there is none for this ETag.
    public func data(fileId: FileID, etag: String, timestamp: Double) -> Data? {
        block(Self.month(of: timestamp))?.tile(fileId, etag: Self.etagHash(etag))
    }

    /// Debug builds: `PHOTOS_DEBUG_NO_TILES=1` turns the lookups off (before/after measurements, docs/PERFORMANCE.md).
    #if DEBUG
        static let isOff = ProcessInfo.processInfo.environment["PHOTOS_DEBUG_NO_TILES"] != nil
    #else
        static let isOff = false
    #endif

    /// The tile of a photo, decoded now (on the caller's thread); nil when there is none for this ETag.
    public func image(fileId: FileID, etag: String, timestamp: Double) -> CGImage? {
        guard !Self.isOff, let data = data(fileId: fileId, etag: etag, timestamp: timestamp),
            let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    func block(_ month: String) -> Block? {
        if let block = blocks.withLock({ $0[month] }) { return block }
        if absent.withLock({ $0.contains(month) }) { return nil }
        guard let data = try? Data(contentsOf: fileURL(month: month), options: .alwaysMapped), let block = Self.parse(data) else {
            absent.withLock { _ = $0.insert(month) }
            return nil
        }
        blocks.withLock { $0[month] = block }
        return block
    }

    /// The index of a month's file, for the builder.
    func entries(month: String) -> [FileID: Block.Entry] { block(month)?.entries ?? [:] }

    /// The month's file changed or went: the next lookup opens it again.
    func invalidate(_ month: String) {
        blocks.withLock { $0[month] = nil }
        absent.withLock { _ = $0.remove(month) }
    }

    /// Everything goes (the preview cache was cleared).
    public func reset() {
        blocks.withLock { $0 = [:] }
        absent.withLock { $0 = [] }
    }

    /// Months that have a file, and how large it is.
    public func files() -> [String: Int64] {
        let keys: [URLResourceKey] = [.fileSizeKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return [:] }
        var result: [String: Int64] = [:]
        for url in urls where url.pathExtension == "tiles" {
            result[url.deletingPathExtension().lastPathComponent] = Int64((try? url.resourceValues(forKeys: Set(keys)).fileSize) ?? 0)
        }
        return result
    }

    // MARK: File format

    // "NCT1", count (UInt32), then per tile fileId (Int64), ETag hash (UInt64), offset and length (UInt32 each), then the
    // JPEG data of the tiles. Little endian.
    static let magic: [UInt8] = Array("NCT1".utf8)
    static let headerSize = 8
    static let entrySize = 24

    static func parse(_ data: Data) -> Block? {
        guard data.count >= headerSize, Array(data.prefix(4)) == magic else { return nil }
        let count = Int(data.loadLE(UInt32.self, at: 4))
        guard count >= 0, headerSize + count * entrySize <= data.count else { return nil }
        var entries: [FileID: Block.Entry] = [:]
        entries.reserveCapacity(count)
        for index in 0..<count {
            let at = headerSize + index * entrySize
            let entry = Block.Entry(
                etag: data.loadLE(UInt64.self, at: at + 8), offset: Int(data.loadLE(UInt32.self, at: at + 16)),
                length: Int(data.loadLE(UInt32.self, at: at + 20)))
            guard entry.offset >= 0, entry.offset + entry.length <= data.count else { return nil }
            entries[FileID(bitPattern: UInt64(data.loadLE(Int64.self, at: at)))] = entry
        }
        return Block(data: data, entries: entries)
    }

    /// A month's file from its tiles.
    static func encode(_ tiles: [(fileId: FileID, etag: UInt64, data: Data)]) -> Data {
        let sorted = tiles.sorted { $0.fileId < $1.fileId }
        var output = Data(magic)
        output.appendLE(UInt32(sorted.count))
        var offset = headerSize + sorted.count * entrySize
        for tile in sorted {
            output.appendLE(tile.fileId)
            output.appendLE(tile.etag)
            output.appendLE(UInt32(offset))
            output.appendLE(UInt32(tile.data.count))
            offset += tile.data.count
        }
        for tile in sorted { output.append(tile.data) }
        return output
    }

    /// Writes a month's file (atomically: a reader keeps the mapping of the file it opened) or removes it when empty.
    func write(month: String, tiles: [(fileId: FileID, etag: UInt64, data: Data)]) throws {
        let url = fileURL(month: month)
        if tiles.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.encode(tiles).write(to: url, options: .atomic)
        }
        invalidate(month)
    }

    func remove(month: String) {
        try? FileManager.default.removeItem(at: fileURL(month: month))
        invalidate(month)
    }

    // MARK: Making a tile

    /// A tile from a preview: 128 px on the short edge (the long edge at most 256), JPEG.
    public static func makeTile(from preview: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(preview as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0
        else { return nil }
        let long = max(width, height)
        let short = min(width, height)
        let target = min(longEdgeLimit, Int((Double(shortEdge) * Double(long) / Double(short)).rounded(.up)))
        guard let image = ImageDecoding.thumbnail(source, maxPixelSize: min(target, long)) else { return nil }
        return ImageDecoding.jpegData(image, quality: quality)
    }
}

extension Data {
    func loadLE<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        var value: T = 0
        Swift.withUnsafeMutableBytes(of: &value) { buffer in
            _ = copyBytes(to: buffer, from: (startIndex + offset)..<(startIndex + offset + MemoryLayout<T>.size))
        }
        return T(littleEndian: value)
    }

    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
