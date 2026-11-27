// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import PhotosMedia
@testable import PhotosModel
@testable import PhotosStore

/// The Library's pre-rendered tiles (SPEC §22.4.1): the file format, the lookups, the builder and the trim.
@Suite(.disabled(if: TestEnvironment.isSimulator, TestEnvironment.noGPU)) struct TileCacheTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "tiles-\(UUID().uuidString)")

    /// A 256 px preview (4:3) with some structure.
    static func preview(seed: Int = 1, width: Int = 256, height: Int = 192) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for band in 0..<16 {
            context.setFillColor(
                red: Double((band * 37 + seed * 11) % 255) / 255, green: Double((band * 91 + seed) % 255) / 255, blue: 0.5, alpha: 1)
            context.fill(CGRect(x: band * width / 16, y: 0, width: width / 16, height: height))
        }
        return ImageDecoding.jpegData(context.makeImage()!)!
    }

    @Test func monthsAreUTCCalendarMonths() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var timestamp = -2_000_000_000.0
        while timestamp < 4_000_000_000 {
            let parts = calendar.dateComponents([.year, .month], from: Date(timeIntervalSince1970: timestamp))
            #expect(TileCache.month(of: timestamp) == String(format: "%04d-%02d", parts.year!, parts.month!), "\(timestamp)")
            timestamp += 86_400 * 13.37
        }
        #expect(TileCache.month(of: 951_782_400) == "2000-02")  // 2000-02-29
        #expect(TileCache.month(of: 951_868_799) == "2000-02")
        #expect(TileCache.month(of: 951_868_800) == "2000-03")
    }

    @Test func fileRoundTripAndLookups() throws {
        let tiles = TileCache(directory: directory)
        let a = try #require(TileCache.makeTile(from: Self.preview(seed: 1)))
        let b = try #require(TileCache.makeTile(from: Self.preview(seed: 2)))
        try tiles.write(month: "2024-05", tiles: [(7, TileCache.etagHash("e7"), a), (3, TileCache.etagHash("e3"), b)])
        let may = 1_715_000_000.0  // 2024-05-06
        #expect(tiles.data(fileId: 7, etag: "e7", timestamp: may) == a)
        #expect(tiles.data(fileId: 3, etag: "e3", timestamp: may) == b)
        // Another ETag (the photo changed, or its edit), another month, another photo: no tile.
        #expect(tiles.data(fileId: 7, etag: "e7-new", timestamp: may) == nil)
        #expect(tiles.data(fileId: 7, etag: "e7", timestamp: may + 40 * 86_400) == nil)
        #expect(tiles.data(fileId: 8, etag: "e8", timestamp: may) == nil)
        // Decoded: 128 px on the short edge.
        let image = try #require(tiles.image(fileId: 7, etag: "e7", timestamp: may))
        #expect(min(image.width, image.height) == 128)
        #expect(max(image.width, image.height) == 171)
        // A damaged file is no file.
        try Data("NCT1garbage".utf8).write(to: tiles.fileURL(month: "2024-06"))
        #expect(tiles.data(fileId: 7, etag: "e7", timestamp: may + 31 * 86_400) == nil)
    }

    @Test func panoramasAndPortraitsKeepTheirShape() throws {
        let tiles = TileCache(directory: directory)
        let panorama = try #require(TileCache.makeTile(from: Self.preview(width: 256, height: 64)))
        let portrait = try #require(TileCache.makeTile(from: Self.preview(width: 144, height: 256)))
        let small = try #require(TileCache.makeTile(from: Self.preview(width: 64, height: 48)))
        try tiles.write(month: "2024-05", tiles: [(1, 1, panorama), (2, 2, portrait), (3, 3, small)])
        let block = try #require(tiles.block("2024-05"))
        func size(_ id: FileID) throws -> (Int, Int) {
            let source = try #require(CGImageSourceCreateWithData(block.tile(id, etag: UInt64(id))! as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            return (image.width, image.height)
        }
        #expect(try size(1) == (256, 64))  // the long edge stops at 256
        #expect(try size(2) == (128, 228))
        #expect(try size(3) == (64, 48))  // never larger than the preview
    }

    /// Tiles are made from the cached previews, month by month; a second build makes nothing; a changed photo, a new
    /// preview and a deleted month are followed.
    @Test func builderMakesWhatIsMissingAndKeepsWhatIsRight() async throws {
        let database = try AccountDatabase.temporary()
        let library = LibraryStore(database: database)
        let cache = PreviewCache(directory: directory)
        let may = 1_715_000_000.0
        let june = may + 31 * 86_400
        func item(_ id: FileID, _ time: Double, etag: String? = nil) -> MediaItem {
            MediaItem(
                fileId: id, path: "/Photos/\(id).jpg", mimeType: "image/jpeg", etag: etag ?? "e\(id)",
                modifiedAt: Date(timeIntervalSince1970: time), capturedAt: Date(timeIntervalSince1970: time))
        }
        try library.upsert([item(1, may), item(2, may + 60), item(3, june), item(4, june + 60)])
        for id: FileID in [1, 2, 3] { cache.storeFile(Self.preview(seed: Int(id)), fileId: id, etag: "e\(id)", bucket: 256) }
        let builder = TileCacheBuilder(tiles: cache.tiles, cache: cache, store: CacheFillStore(database: database), budget: 1 << 30)

        var outcome = await builder.run()
        #expect(outcome.finished)
        #expect(outcome.tilesMade == 3)
        #expect(outcome.monthsWritten == 2)
        #expect(Set(cache.tiles.files().keys) == ["2024-05", "2024-06"])
        #expect(cache.tileImage(fileId: 1, etag: "e1", timestamp: may) != nil)
        #expect(cache.tileImage(fileId: 4, etag: "e4", timestamp: june + 60) == nil)  // no preview cached yet
        // In memory now: the grid's memory lookup finds it as the 128 px picture.
        #expect(cache.bestMemoryImage(fileId: 1, etag: "e1", upTo: 4096) != nil)

        outcome = await builder.run()
        #expect(outcome.tilesMade == 0)
        #expect(outcome.monthsWritten == 0)
        #expect(outcome.tiles == 3)

        // Photo 4's preview arrives, photo 2 is edited elsewhere (new ETag, its preview not cached yet).
        cache.storeFile(Self.preview(seed: 4), fileId: 4, etag: "e4", bucket: 256)
        try library.upsert([item(2, may + 60, etag: "e2-new")])
        outcome = await builder.run()
        #expect(outcome.tilesMade == 1)
        #expect(outcome.monthsWritten == 2)  // June for 4; May loses 2's old tile (half of its tiles are stale)
        #expect(cache.tiles.data(fileId: 2, etag: "e2", timestamp: may + 60) == nil)
        #expect(cache.tiles.data(fileId: 4, etag: "e4", timestamp: june + 60) != nil)

        // The May photos are deleted: May's file goes.
        try library.delete([1, 2])
        outcome = await builder.run()
        #expect(Set(cache.tiles.files().keys) == ["2024-06"])
    }

    /// Over the budget, the oldest months lose their tiles.
    @Test func budgetKeepsTheNewestMonths() async throws {
        let database = try AccountDatabase.temporary()
        let library = LibraryStore(database: database)
        let cache = PreviewCache(directory: directory)
        var items: [MediaItem] = []
        for month in 0..<6 {
            for n in 0..<5 {
                let id = FileID(month * 10 + n + 1)
                let time = 1_600_000_000 + Double(month) * 32 * 86_400 + Double(n)
                items.append(
                    MediaItem(
                        fileId: id, path: "/Photos/\(id).jpg", mimeType: "image/jpeg", etag: "e\(id)",
                        modifiedAt: Date(timeIntervalSince1970: time), capturedAt: Date(timeIntervalSince1970: time)))
                cache.storeFile(Self.preview(seed: Int(id)), fileId: id, etag: "e\(id)", bucket: 256)
            }
        }
        try library.upsert(items)
        // Just more than the newest month: the month that crosses the budget is the last one kept.
        let newestMonth = items.suffix(5).compactMap { TileCache.makeTile(from: Self.preview(seed: Int($0.fileId))) }
        let budget = Int64(newestMonth.reduce(0) { $0 + $1.count } + 1)
        let builder = TileCacheBuilder(tiles: cache.tiles, cache: cache, store: CacheFillStore(database: database), budget: budget)
        let outcome = await builder.run()
        #expect(outcome.finished)
        let newest = Set(items.suffix(10).map { TileCache.month(of: $0.capturedAt!.timeIntervalSince1970) })
        #expect(Set(cache.tiles.files().keys) == newest)
    }

    /// The trim of the preview cache leaves the tiles alone and keeps their bytes free.
    @Test func trimLeavesTheTilesAndCountsThem() throws {
        let cache = PreviewCache(directory: directory)
        let tile = try #require(TileCache.makeTile(from: Self.preview()))
        try cache.tiles.write(month: "2024-05", tiles: (1...50).map { (FileID($0), UInt64($0), tile) })
        let tileBytes = try #require(cache.tiles.files()["2024-05"])
        for id in FileID(1)...20 { cache.storeFile(Self.preview(seed: Int(id)), fileId: id, etag: "e", bucket: 256) }
        let previews = cache.totalSize() - tileBytes
        // Room for the tiles and half of the previews.
        let remaining = cache.trimNow(toBytes: tileBytes + previews / 2)
        #expect(cache.tiles.files()["2024-05"] == tileBytes)
        #expect(remaining <= tileBytes + previews / 2)
        #expect(cache.totalSize() - tileBytes < previews)
    }

    /// Per tile, a lookup in the tile cache against a read of the 256 px preview from the disk cache, over a synthetic
    /// library of `PHOTOS_TILE_PERF` photos (100 000 when set to 1) in months of 400. `PERF` lines.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PHOTOS_TILE_PERF"] != nil))
    func measureLookups() throws {
        let value = Int(ProcessInfo.processInfo.environment["PHOTOS_TILE_PERF"] ?? "") ?? 1
        let count = value <= 1 ? 100_000 : value
        let cache = PreviewCache(directory: directory)
        let previews = (0..<40).map { Self.preview(seed: $0) }
        let made = previews.compactMap { TileCache.makeTile(from: $0) }
        let start = 1_000_000_000.0
        let perMonth = 400
        var began = ContinuousClock.now
        for month in 0..<(count / perMonth) {
            let tiles = (0..<perMonth).map { n -> (fileId: FileID, etag: UInt64, data: Data) in
                let id = FileID(month * perMonth + n)
                return (id, TileCache.etagHash("e\(id)"), made[Int(id) % made.count])
            }
            try cache.tiles.write(month: TileCache.month(of: start + Double(month) * 31 * 86_400), tiles: tiles)
        }
        let bytes = cache.tiles.files().values.reduce(0, +)
        print(
            "PERF tiles: \(count) tiles in \(count / perMonth) files, \(bytes / 1_048_576) MB, written in \((ContinuousClock.now - began).milliseconds) ms"
        )
        // The disk path: 2 000 preview files (a file per photo), read and decoded at the iPhone tile's 231 px.
        for id in 0..<2000 { cache.storeFile(previews[id % previews.count], fileId: FileID(id), etag: "e\(id)", bucket: 256) }
        var random = SystemRandomNumberGenerator()
        let samples = (0..<5000).map { _ in Int.random(in: 0..<count, using: &random) }
        began = ContinuousClock.now
        var found = 0
        for id in samples {
            let month = id / perMonth
            let timestamp = start + Double(month) * 31 * 86_400
            if cache.tiles.image(fileId: FileID(id), etag: "e\(id)", timestamp: timestamp) != nil { found += 1 }
        }
        let tileTime = (ContinuousClock.now - began).milliseconds / Double(samples.count)
        began = ContinuousClock.now
        for id in samples {
            let file = id % 2000
            _ = cache.diskImage(fileId: FileID(file), etag: "e\(file)", bucket: 256, maxPixelSize: 231)
        }
        let diskTime = (ContinuousClock.now - began).milliseconds / Double(samples.count)
        #expect(found == samples.count)
        print(
            "PERF tiles: lookup + decode \(String(format: "%.3f", tileTime)) ms a tile (\(samples.count) random photos of \(count), every month file opened on first use); disk cache read + decode at 231 px \(String(format: "%.3f", diskTime)) ms"
        )
    }
}

extension Duration {
    fileprivate var milliseconds: Double { Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15 }
}
