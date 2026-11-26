// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import ImageIO
import PhotosDomain
import PhotosModel
import Testing
import UniformTypeIdentifiers

@testable import PhotosMedia

/// Test pictures: a photo-like gradient with some texture, as PNG or JPEG.
enum TestPictures {
    static func image(width: Int, height: Int) -> CGImage {
        // Smooth colours with a little grain, like a photo (a flat picture would make any format look good).
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var seed: UInt32 = 12345
        for y in 0..<height {
            for x in 0..<width {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let grain = Double(seed >> 28) - 8
                let wave = (sin(Double(x) / 23) + cos(Double(y) / 17)) * 40 + 128
                let values = [Double(x) / Double(width) * 255, wave, Double(y) / Double(height) * 255]
                for channel in 0..<3 {
                    pixels[(y * width + x) * 4 + channel] = UInt8(max(0, min(255, values[channel] + grain)))
                }
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func encoded(_ image: CGImage, type: UTType, quality: Double = 0.8) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static func png(width: Int = 512, height: Int = 384) -> Data { encoded(image(width: width, height: height), type: .png) }
    static func jpeg(width: Int = 512, height: Int = 384) -> Data { encoded(image(width: width, height: height), type: .jpeg) }

    /// Peak signal-to-noise ratio of two images of the same size, in dB.
    static func psnr(_ a: CGImage, _ b: CGImage) -> Double {
        func pixels(_ image: CGImage) -> [UInt8] {
            var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = CGContext(
                data: &buffer, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return buffer
        }
        let (x, y) = (pixels(a), pixels(b))
        var squared = 0.0
        var count = 0
        for index in stride(from: 0, to: x.count, by: 4) {
            for channel in 0..<3 {
                let difference = Double(x[index + channel]) - Double(y[index + channel])
                squared += difference * difference
                count += 1
            }
        }
        let mse = squared / Double(count)
        return mse == 0 ? 99 : 10 * log10(255 * 255 / mse)
    }
}

@Suite struct PreviewTranscodingTests {
    @Test(
        .enabled(if: PreviewTranscoding.canWriteHEIC, "HEIC cannot be written here"),
        .disabled(if: TestEnvironment.isSimulator, TestEnvironment.noGPU))
    func aPNGPreviewIsStoredAsASmallHEICThatLooksTheSame() throws {
        let png = TestPictures.png()
        let stored = PreviewTranscoding.storage(for: png)
        #expect(stored.isHEIC)
        #expect(PreviewTranscoding.type(of: stored.data)?.conforms(to: .heic) == true)
        #expect(stored.data.count * 3 < png.count)
        let original = try #require(ImageDecoding.decode(data: png, maxPixelSize: 4096))
        let round = try #require(ImageDecoding.decode(data: stored.data, maxPixelSize: 4096))
        #expect(round.width == 512 && round.height == 384)
        // The server's JPEG previews are about 38 dB from their originals.
        #expect(TestPictures.psnr(original, round) > 38)
    }

    @Test func jpegPreviewsAndWhatIsNoImageAreKeptAsTheyAre() {
        let jpeg = TestPictures.jpeg()
        let stored = PreviewTranscoding.storage(for: jpeg)
        #expect(!stored.isHEIC)
        #expect(stored.data == jpeg)
        let junk = Data(repeating: 7, count: 100)
        #expect(PreviewTranscoding.storage(for: junk).data == junk)
        #expect(!PreviewTranscoding.shouldStoreAsHEIC(nil))
        #expect(!PreviewTranscoding.shouldStoreAsHEIC(.heic))
        #expect(PreviewTranscoding.shouldStoreAsHEIC(.png))
    }

    @Test(
        .enabled(if: PreviewTranscoding.canWriteHEIC, "HEIC cannot be written here"),
        .disabled(if: TestEnvironment.isSimulator, TestEnvironment.noGPU))
    func theOrientationIsCarriedOver() throws {
        // A TIFF (lossless) whose pixels are landscape but which is to be shown rotated.
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(
            destination, TestPictures.image(width: 64, height: 32), [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let heic = try #require(PreviewTranscoding.heic(from: data as Data))
        let shown = try #require(ImageDecoding.decode(data: heic, maxPixelSize: 64))
        #expect(shown.width == 32 && shown.height == 64)
    }
}

@Suite struct CacheFillStorageTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "fill-\(UUID().uuidString)")

    @Test func storedFilesAreOnDiskButNotDecodedIntoMemory() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = PreviewCache(directory: directory)
        let jpeg = TestPictures.jpeg(width: 256, height: 192)
        #expect(cache.storeFile(jpeg, fileId: 7, etag: "abc", bucket: 256))
        #expect(cache.hasDiskImage(fileId: 7, etag: "abc", bucket: 256))
        #expect(cache.memoryImage(fileId: 7, etag: "abc", bucket: 256) == nil)
        #expect(cache.diskData(fileId: 7, etag: "abc", bucket: 256) == jpeg)
        #expect(cache.diskImage(fileId: 7, etag: "abc", bucket: 256)?.width == 256)
        // Another version of the photo is another file.
        #expect(!cache.hasDiskImage(fileId: 7, etag: "new", bucket: 256))
    }

    @Test(
        .enabled(if: PreviewTranscoding.canWriteHEIC, "HEIC cannot be written here"),
        .disabled(if: TestEnvironment.isSimulator, TestEnvironment.noGPU))
    func aHEICFileInTheCacheIsReadLikeAJPEG() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = PreviewCache(directory: directory)
        let heic = PreviewTranscoding.storage(for: TestPictures.png(width: 256, height: 192)).data
        #expect(cache.storeFile(heic, fileId: 8, etag: "e", bucket: 256))
        let image = try #require(cache.diskImage(fileId: 8, etag: "e", bucket: 256, maxPixelSize: 128))
        #expect(image.width == 128)
    }

    @Test func aSmallerPreviewIsMadeFromALargerOne() throws {
        let small = try #require(ImageDecoding.smallerPreview(from: TestPictures.jpeg(width: 256, height: 170), maxPixelSize: 64))
        let image = try #require(ImageDecoding.decode(data: small, maxPixelSize: 4096))
        // Aspect-fit like the server's: the long edge is 64.
        #expect(image.width == 64)
        #expect(image.height == 43 || image.height == 42)
    }

    @Test func averageSizesComeFromCachedFilesOfEachBucket() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = PreviewCache(directory: directory)
        for id in 1...4 {
            cache.storeFile(Data(count: 1000 * id), fileId: FileID(id), etag: "e", bucket: 256)
            cache.storeFile(Data(count: 100), fileId: FileID(id), etag: "e", bucket: 64)
        }
        cache.storeFile(Data(count: 99_999), fileId: 9, etag: "e", bucket: 1024)
        #expect(cache.averageFileSizes(buckets: [256, 64], minimum: 1) == [256: 2500, 64: 100])
        // Too few files say nothing.
        #expect(cache.averageFileSizes(buckets: [256, 64], minimum: 30).isEmpty)
    }

    @Test func theSettingHasThePlatformsDefaultUntilChosen() throws {
        let defaults = try #require(UserDefaults(suiteName: "thumbnails-\(UUID().uuidString)"))
        #expect(LibraryThumbnailSettings.isEnabled(defaults) == LibraryThumbnailPlan.defaultEnabled)
        #expect(!LibraryThumbnailSettings.allowsCellular(defaults))
        defaults.set(!LibraryThumbnailPlan.defaultEnabled, forKey: CacheLimits.wholeLibraryThumbnailsKey)
        #expect(LibraryThumbnailSettings.isEnabled(defaults) == !LibraryThumbnailPlan.defaultEnabled)
        let fresh = try #require(UserDefaults(suiteName: "thumbnails-\(UUID().uuidString)"))
        LibraryThumbnailSettings.registerDefault(fresh)
        #expect(fresh.bool(forKey: "cacheWholeLibraryThumbnails") == LibraryThumbnailPlan.defaultEnabled)
    }
}

@Suite(.timeLimit(.minutes(1))) struct PipelineIdleTests {
    let server = PreviewStubServer()
    let directory = FileManager.default.temporaryDirectory.appending(path: "idle-\(UUID().uuidString)")

    @Test func thePipelineIsIdleOnlyWhenNothingLoadsFromTheServer() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let api = server.api
        let pipeline = ImagePipeline(
            api: api, cache: PreviewCache(directory: directory.appending(path: "previews")),
            originals: OriginalStore(directory: directory.appending(path: "originals"), dav: api.dav))
        #expect(await pipeline.isNetworkIdle)
        server.hold()
        let load = Task { await pipeline.preview(ImagePipeline.Request(fileId: 1, etag: "e", bucket: 256)) }
        for _ in 0..<1000 where server.started.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await !pipeline.isNetworkIdle)
        server.release()
        _ = await load.value
        // A prefetch counts too: the grid wants it soon.
        server.hold()
        await pipeline.prefetch([ImagePipeline.Request(fileId: 2, etag: "e", bucket: 256)])
        #expect(await !pipeline.isNetworkIdle)
        server.release()
        for _ in 0..<1000 where !(await pipeline.isNetworkIdle) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await pipeline.isNetworkIdle)
    }
}
