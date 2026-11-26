// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers

@testable import PhotosCore
@testable import PhotosDomain
@testable import PhotosMedia
@testable import PhotosModel
@testable import PhotosNetworking
@testable import PhotosStore

/// Real pictures for the stub server: the fillers decode and re-encode what they download.
private enum Pictures {
    static func encoded(width: Int, height: Int, type: UTType) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for x in stride(from: 0, to: width, by: 8) {
            context.setFillColor(red: Double(x) / Double(width), green: 0.4, blue: 0.7, alpha: 1)
            context.fill(CGRect(x: x, y: 0, width: 8, height: height))
        }
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static let jpeg = encoded(width: 256, height: 170, type: .jpeg)
    static let png = encoded(width: 640, height: 480, type: .png)
}

/// Settings the fillers read, changed by the tests.
private final class FillSetting: Sendable {
    let value = Mutex((enabled: true, allowsCellular: false))
    var current: (enabled: Bool, allowsCellular: Bool) { value.withLock { $0 } }
    func set(enabled: Bool? = nil, cellular: Bool? = nil) {
        value.withLock {
            if let enabled { $0.enabled = enabled }
            if let cellular { $0.allowsCellular = cellular }
        }
    }
}

@Suite(.timeLimit(.minutes(1))) struct LibraryThumbnailFillerTests {
    let sandbox = Sandbox()
    let server = StubServer()
    fileprivate let setting = FillSetting()

    func makeServices() throws -> AccountServices {
        try AccountServices(
            account: makeAccount("alice", server: server.url.absoluteString), appPassword: "password", http: server.http(),
            features: ServerFeatures(serverVersion: ServerVersion(major: 33)), userAgent: "tests", layout: sandbox.layout,
            onUnauthorized: {})
    }

    func makeFiller(_ services: AccountServices, network: NetworkConditions = NetworkConditions()) async -> LibraryThumbnailFiller {
        let filler = LibraryThumbnailFiller(services: services, settings: { [setting] in setting.current })
        await filler.setConditions(network: network, lowPower: false, pipelineIdle: { true }, quiet: 0)
        return filler
    }

    /// Photos 1…count with previews on the server, newest last; photo 90 has no server preview, 91 is archived and 92 is
    /// the video half of a Live Photo.
    func seed(_ services: AccountServices, count: Int) throws {
        let now = Date()
        var items = (1...count).map { index in
            MediaItem(
                fileId: FileID(index), path: "/Photos/p\(index).jpg", mimeType: "image/jpeg", etag: "e\(index)",
                modifiedAt: now.addingTimeInterval(-Double(count - index) * 3600))
        }
        items.append(MediaItem(fileId: 90, path: "/Photos/raw.dng", mimeType: "image/x-adobe-dng", etag: "r", hasPreview: false))
        items.append(MediaItem(fileId: 91, path: "/Photos/old.jpg", mimeType: "image/jpeg", etag: "o", isArchived: true))
        items.append(MediaItem(fileId: 92, path: "/Photos/live.mov", mimeType: "video/quicktime", etag: "l", isLivePhotoVideo: true))
        try services.library.upsert(items)
        server.set { state in
            for index in Array(1...count) + [90, 91, 92] {
                state.downloads["/index.php/apps/photos/api/v1/preview/\(index)"] = Pictures.jpeg
            }
        }
    }

    var previewRequests: Int { server.requests.filter { $0.path.hasPrefix("/index.php/apps/photos/api/v1/preview/") }.count }

    @Test func aPassKeepsBothThumbnailsOfEveryPhotoAndTheNextOneHasNothingToDo() async throws {
        defer { sandbox.remove() }
        let services = try makeServices()
        try seed(services, count: 7)
        let filler = await makeFiller(services)

        let outcome = await filler.run()

        #expect(outcome == LibraryThumbnailFiller.Outcome(downloaded: 7, made: 7, failed: 0, remaining: 0, stopped: false))
        let cache = services.images.cache
        for id in 1...7 {
            #expect(cache.hasDiskImage(fileId: FileID(id), etag: "e\(id)", bucket: 256))
            #expect(cache.hasDiskImage(fileId: FileID(id), etag: "e\(id)", bucket: 64))
        }
        // Only what the timeline shows with a server preview, and only the 256 px preview from the server.
        #expect(!cache.hasDiskImage(fileId: 90, etag: "r", bucket: 256))
        #expect(!cache.hasDiskImage(fileId: 91, etag: "o", bucket: 256))
        #expect(!cache.hasDiskImage(fileId: 92, etag: "l", bucket: 256))
        #expect(previewRequests == 7)
        // Nothing was decoded into the memory cache.
        #expect(cache.memoryImage(fileId: 7, etag: "e7", bucket: 256) == nil)
        let small = try #require(cache.diskImage(fileId: 7, etag: "e7", bucket: 64))
        #expect(max(small.width, small.height) == 64)
        #expect(filler.progress.done == 7 && filler.progress.total == 7 && filler.progress.isComplete)

        let again = await filler.run()
        #expect(again.downloaded == 0 && again.made == 0 && again.remaining == 0)
        #expect(previewRequests == 7)
    }

    @Test func aStoppedPassGoesOnWhereItStopped() async throws {
        defer { sandbox.remove() }
        let services = try makeServices()
        try seed(services, count: 6)
        let filler = await makeFiller(services)
        // The background time ends after three downloads.
        let allowed = Mutex(3)
        let first = await filler.run(shouldContinue: {
            allowed.withLock {
                $0 -= 1; return $0 >= 0
            }
        })
        #expect(first.stopped)
        #expect(first.downloaded == 3)
        #expect(first.remaining == 3)
        // Newest first.
        #expect(services.images.cache.hasDiskImage(fileId: 6, etag: "e6", bucket: 256))
        #expect(!services.images.cache.hasDiskImage(fileId: 1, etag: "e1", bucket: 256))

        let second = await filler.run()
        #expect(second.downloaded == 3)
        #expect(previewRequests == 6)
    }

    @Test func onlyAMissing64IsMadeWithoutTheNetwork() async throws {
        defer { sandbox.remove() }
        let services = try makeServices()
        try seed(services, count: 3)
        let filler = await makeFiller(services)
        await filler.run()
        let cache = services.images.cache
        try FileManager.default.removeItem(at: cache.fileURL(key: PreviewCache.key(fileId: 2, etag: "e2", bucket: 64)))
        // Cellular: no downloads, but making the 64 px preview needs none.
        await filler.setConditions(network: NetworkConditions(isExpensive: true), lowPower: false, pipelineIdle: { true }, quiet: 0)
        let outcome = await filler.run()
        #expect(outcome.made == 1 && outcome.downloaded == 0)
        #expect(cache.hasDiskImage(fileId: 2, etag: "e2", bucket: 64))
        #expect(previewRequests == 3)
    }

    @Test func nothingIsDownloadedOnCellularUnlessAllowedNorWhenOff() async throws {
        defer { sandbox.remove() }
        let services = try makeServices()
        try seed(services, count: 2)
        let filler = await makeFiller(services, network: NetworkConditions(isExpensive: true))
        var outcome = await filler.run()
        #expect(outcome.stopped && outcome.downloaded == 0 && outcome.remaining == 2)
        #expect(filler.progress.isWaitingForConditions)
        await filler.setConditions(network: NetworkConditions(), lowPower: true, pipelineIdle: { true }, quiet: 0)
        outcome = await filler.run()
        #expect(outcome.downloaded == 0)

        setting.set(enabled: false)
        await filler.setConditions(network: NetworkConditions(), lowPower: false, pipelineIdle: { true }, quiet: 0)
        outcome = await filler.run()
        #expect(outcome == LibraryThumbnailFiller.Outcome())

        setting.set(enabled: true, cellular: true)
        await filler.setConditions(network: NetworkConditions(isExpensive: true), lowPower: false, pipelineIdle: { true }, quiet: 0)
        outcome = await filler.run()
        #expect(outcome.downloaded == 2 && !outcome.stopped)
        #expect(!filler.progress.isWaitingForConditions)
    }

    @Test func itWaitsWhileThePipelineLoadsForTheScreen() async throws {
        defer { sandbox.remove() }
        let services = try makeServices()
        try seed(services, count: 2)
        let filler = await makeFiller(services)
        // Busy for the first checks (the grid scrolls), then idle.
        let checks = Mutex(0)
        await filler.setConditions(
            network: NetworkConditions(), lowPower: false,
            pipelineIdle: {
                checks.withLock {
                    $0 += 1; return $0 > 4
                }
            }, quiet: 0.05)
        let start = Date()
        let outcome = await filler.run()
        #expect(outcome.downloaded == 2)
        // Four busy checks half a second apart, then a quiet moment.
        #expect(Date().timeIntervalSince(start) >= 1.5)
        #expect(checks.withLock { $0 } >= 6)

        // Never idle: nothing is downloaded while the screen loads.
        try FileManager.default.removeItem(at: services.images.cache.directory)
        await filler.setConditions(network: NetworkConditions(), lowPower: false, pipelineIdle: { false }, quiet: 0)
        let deadline = Date().addingTimeInterval(1)
        let busy = await filler.run(shouldContinue: { Date() < deadline })
        #expect(busy.downloaded == 0 && busy.stopped)
    }

    @Test func countingAndTheEstimateDownloadNothing() async throws {
        defer { sandbox.remove() }
        let services = try makeServices()
        try seed(services, count: 4)
        let filler = await makeFiller(services)
        let estimate = await filler.estimate()
        #expect(estimate.photos == 4)
        #expect(estimate.bytes == LibraryThumbnailPlan.estimatedBytes(photos: 4))
        await filler.count()
        #expect(filler.progress.total == 4 && filler.progress.done == 0)
        #expect(previewRequests == 0)
    }
}

@Suite(.timeLimit(.minutes(1))) struct SmartOfflineHEICTests {
    let sandbox = Sandbox()
    let server = StubServer()

    func makeServices() throws -> AccountServices {
        try AccountServices(
            account: makeAccount("alice", server: server.url.absoluteString), appPassword: "password", http: server.http(),
            features: ServerFeatures(serverVersion: ServerVersion(major: 33)), userAgent: "tests", layout: sandbox.layout,
            onUnauthorized: {})
    }

    func makeManager(_ services: AccountServices) async -> SmartOfflineManager {
        let manager = SmartOfflineManager(services: services, settings: { (.small, .screen) })
        await manager.setConditions(network: NetworkConditions(), lowPower: false)
        return manager
    }

    func seed(_ services: AccountServices, previews: [FileID: Data]) throws {
        let now = Date()
        try services.library.upsert(
            previews.keys.map { id in
                MediaItem(fileId: id, path: "/Photos/p\(id).png", mimeType: "image/png", etag: "e\(id)", modifiedAt: now, capturedAt: now)
            })
        server.set { state in
            for (id, data) in previews { state.downloads["/index.php/apps/photos/api/v1/preview/\(id)"] = data }
        }
    }

    @Test(.enabled(if: PreviewTranscoding.canWriteHEIC, "HEIC cannot be written here"))
    func pngPreviewsAreKeptAsHEICAndJPEGPreviewsAsTheyCame() async throws {
        defer { sandbox.remove() }
        let services = try makeServices()
        try seed(services, previews: [1: Pictures.png, 2: Pictures.jpeg])
        let manager = await makeManager(services)
        let outcome = await manager.run(limit: nil)
        #expect(outcome.downloaded == 2)
        let png = try #require(manager.localPreview(fileId: 1, etag: "e1", bucket: 1024))
        #expect(png.pathExtension == "heic")
        #expect(try Data(contentsOf: png).count < Pictures.png.count / 3)
        #expect(ImageDecoding.decode(url: png, maxPixelSize: 4096)?.width == 640)
        let jpeg = try #require(manager.localPreview(fileId: 2, etag: "e2", bucket: 1024))
        #expect(jpeg.pathExtension == "jpg")
        #expect(try Data(contentsOf: jpeg) == Pictures.jpeg)
        // The budget counts what is stored.
        let summary = await manager.summary()
        #expect(summary.bytes < Int64(Pictures.png.count / 3 + Pictures.jpeg.count))
    }

    @Test(.enabled(if: PreviewTranscoding.canWriteHEIC, "HEIC cannot be written here"))
    func pngPreviewsKeptBeforeAreConvertedLaterWithoutTheNetwork() async throws {
        defer { sandbox.remove() }
        let services = try makeServices()
        try seed(services, previews: [1: Pictures.png, 2: Pictures.jpeg])
        // An earlier version kept both as they came, named .jpg.
        let directory = services.layout.accountDirectory(services.account.id).appending(path: "SmartOffline")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = SmartOfflineStore(database: services.database)
        for (id, data) in [(FileID(1), Pictures.png), (FileID(2), Pictures.jpeg)] {
            let name = "\(id)-e\(id)-2048.jpg"
            try data.write(to: directory.appending(path: name))
            try await store.insert(
                SmartOfflineStore.Row(
                    fileId: id, etag: "e\(id)", quality: .screen, localPath: name, bytes: Int64(data.count), keptAt: Date(),
                    reason: .recent))
        }
        let manager = await makeManager(services)
        await manager.setConditions(network: NetworkConditions(isConnected: false), lowPower: false)

        let outcome = await manager.run(limit: nil)

        #expect(outcome.converted == 1)
        #expect(outcome.downloaded == 0)
        let converted = try #require(manager.localPreview(fileId: 1, etag: "e1", bucket: 256))
        #expect(converted.lastPathComponent == "1-e1-2048.heic")
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "1-e1-2048.jpg").path(percentEncoded: false)))
        #expect(manager.localPreview(fileId: 2, etag: "e2", bucket: 256)?.lastPathComponent == "2-e2-2048.jpg")
        let rows = try store.kept().sorted { $0.fileId < $1.fileId }
        #expect(rows.map(\.localPath) == ["1-e1-2048.heic", "2-e2-2048.jpg"])
        #expect(rows[0].bytes < Int64(Pictures.png.count / 3))
        #expect(server.requests.isEmpty)
        // Looked at once: the next pass converts nothing.
        #expect(await manager.run(limit: nil).converted == 0)
    }
}

@Suite(.timeLimit(.minutes(1))) struct BackgroundPreparationTests {
    let sandbox = Sandbox()
    let server = StubServer()

    func makeServices() throws -> AccountServices {
        try AccountServices(
            account: makeAccount("alice", server: server.url.absoluteString), appPassword: "password", http: server.http(),
            features: ServerFeatures(serverVersion: ServerVersion(major: 33)), userAgent: "tests", layout: sandbox.layout,
            onUnauthorized: {})
    }

    let tiles = PreparationPlan.Tiles(side: 77, scale: 2, square: true, perScreen: 4)

    /// Twelve photos of the last hours, 4:3; an album opened yesterday with photos 1 and 2 (cover 2).
    func seed(_ services: AccountServices) throws {
        let now = Date()
        let items = (1...12).map { index in
            MediaItem(
                fileId: FileID(index), path: "/Photos/p\(index).jpg", mimeType: "image/jpeg", etag: "e\(index)",
                modifiedAt: now.addingTimeInterval(-Double(12 - index) * 60), width: 4000, height: 3000)
        }
        try services.library.upsert(items)
        try services.database.writer.write { db in
            try db.execute(
                sql: "INSERT INTO album(id, kind, name, title, coverFileId, itemCount) VALUES ('own:Trip', 'own', 'Trip', 'Trip', 2, 2)")
            try db.execute(
                sql: "INSERT INTO albumItem(albumId, fileId, childName) VALUES ('own:Trip', 1, 'p1.jpg'), ('own:Trip', 2, 'p2.jpg')")
        }
        try SmartOfflineStore(database: services.database).noteAlbumViewed("own:Trip", at: now.addingTimeInterval(-86_400))
        server.set { state in
            for index in 1...12 { state.downloads["/index.php/apps/photos/api/v1/preview/\(index)"] = Pictures.jpeg }
        }
    }

    @Test func theFirstScreensAndRecentAlbumsArePreparedOnce() async throws {
        defer { sandbox.remove() }
        let services = try makeServices()
        try seed(services)
        let outcome = await BackgroundPreparation.prepare(
            services: services, excludedFolders: [], tiles: tiles, network: NetworkConditions(), isLowPowerMode: false)
        // Two screens of four tiles (photos 12…5) at 256 px, the album's cover (2) at 1024 px, its photos 2 and 1 at 256 px.
        #expect(outcome.planned == 11)
        #expect(outcome.downloaded == 11)
        let cache = services.images.cache
        for id in 5...12 { #expect(cache.hasDiskImage(fileId: FileID(id), etag: "e\(id)", bucket: 256)) }
        #expect(!cache.hasDiskImage(fileId: 4, etag: "e4", bucket: 256))
        #expect(cache.hasDiskImage(fileId: 2, etag: "e2", bucket: 1024))
        #expect(cache.hasDiskImage(fileId: 1, etag: "e1", bucket: 256))
        #expect(cache.memoryImage(fileId: 12, etag: "e12", bucket: 256) == nil)

        let again = await BackgroundPreparation.prepare(
            services: services, excludedFolders: [], tiles: tiles, network: NetworkConditions(), isLowPowerMode: false)
        #expect(again.present == 11 && again.downloaded == 0)
    }

    @Test func nothingIsDownloadedOnCellularOrInLowPowerMode() async throws {
        defer { sandbox.remove() }
        let services = try makeServices()
        try seed(services)
        var outcome = await BackgroundPreparation.prepare(
            services: services, excludedFolders: [], tiles: tiles, network: NetworkConditions(isExpensive: true), isLowPowerMode: false)
        #expect(outcome.skipped && outcome.downloaded == 0)
        outcome = await BackgroundPreparation.prepare(
            services: services, excludedFolders: [], tiles: tiles, network: NetworkConditions(), isLowPowerMode: true)
        #expect(outcome.skipped && outcome.downloaded == 0)
        #expect(server.requests.filter { $0.path.contains("/preview/") }.isEmpty)
    }

    @Test @MainActor func theTilesFollowTheStoredZoomStep() throws {
        let defaults = try #require(UserDefaults(suiteName: "preparation-\(UUID().uuidString)"))
        let standard = BackgroundPreparation.tiles(defaults)
        #expect(standard.square)
        #if os(macOS)
            // Eight columns at 1056 pt: 130 pt tiles, 1024 px previews.
            #expect(standard.bucket(aspectRatio: 4.0 / 3.0) == 1024)
        #endif
        defaults.set(16, forKey: "gridColumns")
        defaults.set(false, forKey: "squareTiles")
        let small = BackgroundPreparation.tiles(defaults)
        #expect(small.side < standard.side)
        #expect(small.perScreen > standard.perScreen)
        #expect(!small.square)
    }
}
