// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import PhotosDomain
import PhotosModel
import Testing

@testable import PhotosMedia

/// The preview cache's importance-aware, per-size disk trim and its memory under pressure (SPEC §18.2).
@Suite struct CacheEvictionMediaTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "evict-\(UUID().uuidString)")

    func add(_ cache: PreviewCache, _ fileId: FileID, etag: String = "e", bucket: Int = 256, bytes: Int, age: TimeInterval) throws {
        let url = cache.fileURL(key: PreviewCache.key(fileId: fileId, etag: etag, bucket: bucket))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path(percentEncoded: false))
    }

    func has(_ cache: PreviewCache, _ fileId: FileID, etag: String = "e", bucket: Int = 256) -> Bool {
        cache.hasDiskImage(fileId: fileId, etag: etag, bucket: bucket)
    }

    func image(_ side: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        return context.makeImage()!
    }

    /// Before the pools, one LRU over all sizes: looking at three photos zoomed in removed the thumbnails of a grid.
    @Test func zoomingInDoesNotEvictThumbnails() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = PreviewCache(directory: directory)
        for id in 1...20 { try add(cache, FileID(id), bytes: 1000, age: 3600 + Double(id)) }
        for id in 101...106 { try add(cache, FileID(id), bucket: 4096, bytes: 5000, age: Double(id)) }
        // 50 000 bytes in all, limit 40 000. One LRU removed ten of the (older) thumbnails; now the large pool, 6000 bytes,
        // gives back all but its newest file.
        let left = cache.trimNow(toBytes: 40_000, context: .init())
        #expect(left == 25_000)
        #expect((1...20).allSatisfy { has(cache, FileID($0)) })
        #expect((101...106).filter { has(cache, FileID($0), bucket: 4096) } == [101])
    }

    @Test func importantPhotosStayLongerThanRecentlyScrolledOnes() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = PreviewCache(directory: directory)
        // 1…5 were looked at in the viewer weeks ago (tier 3); 6…10 just scrolled past (no reason).
        for id in 1...5 { try add(cache, FileID(id), bytes: 1000, age: 30 * 86_400) }
        for id in 6...10 { try add(cache, FileID(id), bytes: 1000, age: 70 - Double(id)) }
        let context = PreviewCache.EvictionContext(tiers: [1: 3, 2: 3, 3: 3, 4: 3, 5: 3])
        #expect(cache.trimNow(toBytes: 6000, context: context) == 6000)
        #expect((1...10).filter { has(cache, FileID($0)) } == [1, 2, 3, 4, 5, 10])
    }

    @Test func wholeLibraryThumbnailsAreKeptAndNotCounted() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = PreviewCache(directory: directory)
        try add(cache, 1, etag: "a", bytes: 1000, age: 100)  // in the library
        try add(cache, 1, etag: "a", bucket: 64, bytes: 200, age: 100)
        try add(cache, 2, etag: "old", bytes: 1000, age: 1)  // the photo changed since
        try add(cache, 3, etag: "c", bytes: 1000, age: 1)  // no longer in the library
        try add(cache, 4, etag: "d", bucket: 1024, bytes: 1000, age: 1)  // in the library, but not a thumbnail
        try add(cache, 5, etag: "e-x", bytes: 1000, age: 100)  // an ETag with a dash
        try add(cache, 6, etag: "f_e1234", bytes: 1000, age: 100)  // an edited version
        let library: [FileID: String] = [1: "a", 2: "new", 4: "d", 5: "e-x", 6: "f"]
        let left = cache.trimNow(toBytes: 0, context: .init(libraryEtags: library))
        #expect(left == 0)
        #expect(has(cache, 1, etag: "a") && has(cache, 1, etag: "a", bucket: 64))
        #expect(has(cache, 5, etag: "e-x") && has(cache, 6, etag: "f_e1234"))
        #expect(!has(cache, 2, etag: "old") && !has(cache, 3, etag: "c") && !has(cache, 4, etag: "d", bucket: 1024))
        // When the option is off they are ordinary members of the thumbnail pool.
        cache.trimNow(toBytes: 0, context: .init())
        #expect(!has(cache, 1, etag: "a"))
    }

    @Test func theTrimAsksTheProviderForTheContext() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = PreviewCache(directory: directory)
        for id in 1...4 { try add(cache, FileID(id), bytes: 1000, age: Double(10 - id)) }
        cache.setEvictionContextProvider { PreviewCache.EvictionContext(tiers: [1: 4]) }
        cache.trimNow(toBytes: 2000)
        #expect((1...4).filter { has(cache, FileID($0)) } == [1, 4])
    }

    @Test func cacheFileNamesAreParsed() throws {
        let parsed = try #require(PreviewCache.parse(cacheFile: URL(filePath: "/x/12/3412-ab-c-d-1024.jpg")))
        #expect(parsed.fileId == 3412 && parsed.etag == "ab-c-d" && parsed.bucket == 1024)
        #expect(PreviewCache.parse(cacheFile: URL(filePath: "/x/12/notes.txt")) == nil)
        #expect(PreviewCache.etag("abc_e99", isVersionOf: "abc"))
        #expect(!PreviewCache.etag("abcd", isVersionOf: "abc"))
    }

    // MARK: Memory

    @Test func memoryIsLeastRecentlyUsedWithinItsBudget() {
        let memory = MemoryImageCache(limit: 3000)
        let picture = image(4)
        for id in 1...3 { memory.setObject(ImageBox(picture, maxPixelSize: 4), forKey: "\(id)-e-64", cost: 1000) }
        #expect(memory.object(forKey: "1-e-64") != nil)  // 1 is now the most recently used
        memory.setObject(ImageBox(picture, maxPixelSize: 4), forKey: "4-e-64", cost: 1000)
        #expect(memory.peek("2-e-64") == nil)
        #expect(memory.peek("1-e-64") != nil && memory.peek("3-e-64") != nil && memory.peek("4-e-64") != nil)
        #expect(memory.totalCost == 3000)
        // Replacing an entry does not count it twice.
        memory.setObject(ImageBox(picture, maxPixelSize: 4), forKey: "4-e-64", cost: 500)
        #expect(memory.totalCost == 2500 && memory.count == 3)
        memory.limit = 1000
        #expect(memory.count == 1 && memory.peek("4-e-64") != nil)
        memory.removeAll()
        #expect(memory.count == 0 && memory.totalCost == 0)
    }

    /// Before: a memory warning emptied the whole cache, the viewer's photo and the grid's tiles included.
    @Test func memoryPressureKeepsTheViewerAndTheTilesOnScreen() {
        let cache = PreviewCache(directory: directory, memoryLimitBytes: 100_000_000)
        defer { try? FileManager.default.removeItem(at: directory) }
        let large = image(1024)
        let tile = image(64)
        cache.remember(large, key: PreviewCache.key(fileId: 9, etag: "e", bucket: 1024), maxPixelSize: 1024)  // seen before
        cache.remember(large, key: PreviewCache.key(fileId: 1, etag: "e", bucket: 1024), maxPixelSize: 1024)
        cache.remember(large, key: PreviewCache.key(fileId: 2, etag: "e", bucket: 1024), maxPixelSize: 1024)
        for id in 10...20 { cache.remember(tile, key: PreviewCache.key(fileId: FileID(id), etag: "e", bucket: 256), maxPixelSize: 256) }
        cache.setViewerFocus(current: 1, neighbours: [2])
        let freed = cache.relieveMemory(.warning)
        #expect(freed == large.bytesPerRow * large.height)
        #expect(cache.memoryImage(fileId: 1, etag: "e", bucket: 1024) != nil)
        #expect(cache.memoryImage(fileId: 2, etag: "e", bucket: 1024) != nil)
        #expect(cache.memoryImage(fileId: 9, etag: "e", bucket: 1024) == nil)
        #expect((10...20).allSatisfy { cache.memoryImage(fileId: FileID($0), etag: "e", bucket: 256) != nil })
        // The viewer closed: its photos are ordinary large decodes again.
        cache.clearViewerFocus(ifCurrent: 3)
        #expect(cache.memory.focus.current == 1)
        cache.clearViewerFocus(ifCurrent: 1)
        cache.relieveMemory(.critical)
        #expect(cache.memoryImage(fileId: 1, etag: "e", bucket: 1024) == nil)
    }

    // MARK: Limits

    @Test func theDefaultLimitFollowsTheFreeSpace() {
        let gigabyte: Int64 = 1024 * 1024 * 1024
        #expect(CacheLimits.defaultPreviewBytes(availableBytes: nil) == CacheLimits.defaultPreviewBytes)
        #expect(CacheLimits.defaultPreviewBytes(availableBytes: 40 * gigabyte) == 2 * gigabyte)
        #expect(CacheLimits.defaultPreviewBytes(availableBytes: 2 * gigabyte) == CacheLimits.minimumPreviewBytes)
        #expect(CacheLimits.defaultPreviewBytes(availableBytes: 500 * gigabyte) == CacheLimits.maximumPreviewBytes)
        let defaults = UserDefaults(suiteName: "limits-\(UUID().uuidString)")!
        #expect(CacheLimits.current(defaults, availableBytes: 40 * gigabyte).previewBytes == 2 * gigabyte)
        // The user's own limit is the total of the pools.
        defaults.set(1_000_000_000, forKey: CacheLimits.previewLimitKey)
        let limits = CacheLimits.current(defaults, availableBytes: 40 * gigabyte)
        #expect(limits.previewBytes == 1_000_000_000)
        #expect(limits.previewPools.total == 1_000_000_000)
        #expect(limits.previewPools.large == 150_000_000)
        // The contract with the whole-library filler (SPEC §18.3).
        #expect(CacheLimits.wholeLibraryThumbnailsKey == "cacheWholeLibraryThumbnails")
        // Unset: the platform's default (on on the Mac, off elsewhere; SPEC §18.3.1).
        #expect(CacheLimits.keepsWholeLibraryThumbnails(defaults) == LibraryThumbnailPlan.defaultEnabled)
        defaults.set(false, forKey: CacheLimits.wholeLibraryThumbnailsKey)
        #expect(!CacheLimits.keepsWholeLibraryThumbnails(defaults))
        defaults.set(true, forKey: CacheLimits.wholeLibraryThumbnailsKey)
        #expect(CacheLimits.keepsWholeLibraryThumbnails(defaults))
    }
}
