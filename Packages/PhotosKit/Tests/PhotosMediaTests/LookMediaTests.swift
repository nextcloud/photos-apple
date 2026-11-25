// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import PhotosDomain
import Testing

@testable import PhotosMedia

/// Photo colours and subject masks on the device (SPEC §16.8.1, §16.8.2).
@Suite struct LookMediaTests {
    static let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~")

    static func encode83(_ value: Int, length: Int) -> String {
        var result = ""
        var rest = value
        for _ in 0..<length {
            result = String(digits[rest % 83]) + result
            rest /= 83
        }
        return result
    }

    /// The BlurHash of a single colour (one component).
    static func solidHash(red: Int, green: Int, blue: Int) -> String {
        "00" + encode83((red << 16) | (green << 8) | blue, length: 4)
    }

    @Test func dominantColourComesFromTheBlurHash() throws {
        let color = try #require(PhotoColors.dominant(blurhash: Self.solidHash(red: 200, green: 40, blue: 30)))
        #expect(abs(color.red - 200.0 / 255) < 0.02)
        #expect(abs(color.green - 40.0 / 255) < 0.02)
        #expect(abs(color.blue - 30.0 / 255) < 0.02)
        #expect(PhotoColors.dominant(blurhash: nil) == nil)
        #expect(PhotoColors.dominant(blurhash: "") == nil)
        #expect(PhotoColors.dominant(blurhash: "not a hash") == nil)
    }

    @Test func aRealBlurHashGivesAColour() throws {
        // The example of blurha.sh.
        let color = try #require(PhotoColors.dominant(blurhash: "LEHV6nWB2yk8pyo0adR*.7kCMdnj"))
        #expect(color.relativeLuminance > 0 && color.relativeLuminance < 1)
    }

    @Test func ambientGlowKeepsWhiteTextReadable() throws {
        let image = try #require(PhotoColors.ambientImage(blurhash: "LEHV6nWB2yk8pyo0adR*.7kCMdnj"))
        #expect(image.width == 6 && image.height == 6)
        let pixels = PhotoColors.pixels(ofDecoded: image)
        #expect(pixels.count == 36)
        // 8-bit rounding may cost a hair of contrast.
        for pixel in pixels { #expect(pixel.contrast(with: .white) >= 6.9) }
        #expect(PhotoColors.ambientImage(blurhash: nil) == nil)
    }

    @Test(.disabled(if: TestEnvironment.isSimulator, TestEnvironment.noGPU))
    func dominantColourOfAPreview() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(
            CGContext(
                data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        context.setFillColor(CGColor(srgbRed: 0.1, green: 0.3, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 24))
        let image = try #require(context.makeImage())
        let color = try #require(PhotoColors.dominant(image: image))
        #expect(color.blue > 0.7 && color.red < 0.3)
    }

    @Test func maskImageRoundTripsAndMeasuresTheTitle() throws {
        // Subject in the lower 60 %: the title band is free.
        let width = 40
        let height = 40
        let alpha: [UInt8] = (0..<(width * height)).map { $0 / width >= 16 ? 255 : 0 }
        let mask = try SubjectMasking.make(alpha: alpha, width: width, height: height)
        #expect(mask.image.width == width && mask.image.height == height)
        #expect(mask.squareCoverage < 0.01)
        #expect(mask.placement == .behindSubject)
        #expect(SubjectMasking.alpha(of: mask.image) == alpha)
        #expect(SubjectMasking.maskImage(alpha: [], width: 4, height: 4) == nil)
        #expect(throws: StickerMaker.Failure.noSubject) { try SubjectMasking.make(alpha: [], width: 0, height: 0) }
    }

    @Test func cacheKeysAreSafeFileNames() {
        #expect(SubjectMaskCache.key(fileId: 42, etag: "\"abc-123\"") == "42-abc123")
        #expect(SubjectMaskCache.key(fileId: 42, etag: "") == "42")
        #expect(SubjectMaskCache.key(fileId: 42, etag: "../..") == "42")
    }

    @Test(.disabled(if: TestEnvironment.isSimulator, TestEnvironment.noGPU))
    func storedMasksAreReadBackWithoutVision() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "mask-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let alpha: [UInt8] = (0..<(32 * 32)).map { $0 / 32 >= 4 ? 255 : 0 }
        let made = try SubjectMasking.make(alpha: alpha, width: 32, height: 32)
        let png = try #require(StickerMaker.pngData(made.image))
        try png.write(to: directory.appending(path: "\(SubjectMaskCache.key(fileId: 7, etag: "e1")).png"))
        let cache = SubjectMaskCache(directory: directory)
        guard case .mask(let read) = try #require(await cache.cached(fileId: 7, etag: "e1")) else {
            Issue.record("no mask")
            return
        }
        #expect(abs(read.squareCoverage - made.squareCoverage) < 0.01)
        #expect(read.placement == .inFront)
        // Another version of the photo has no mask yet.
        #expect(await cache.cached(fileId: 7, etag: "e2") == nil)
        // The picture source is not asked for a known mask.
        let result = await cache.mask(fileId: 7, etag: "e1") {
            Issue.record("asked for the picture")
            return nil
        }
        if case .none = result { Issue.record("mask lost") }
        await cache.removeAll()
        #expect(!FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))
    }

    @Test(.disabled(if: TestEnvironment.isSimulator, TestEnvironment.noVision))
    func aPhotoWithoutSubjectIsRememberedOnDisk() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "mask-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(
            CGContext(
                data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 512, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.6, green: 0.6, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
        let flat = try #require(context.makeImage())
        let cache = SubjectMaskCache(directory: directory)
        let result = await cache.mask(fileId: 9, etag: "x") { flat }
        guard case .none = result else {
            Issue.record("a flat grey picture has no subject")
            return
        }
        // A fresh cache (next launch) knows it without running Vision.
        let again = SubjectMaskCache(directory: directory)
        let known = await again.cached(fileId: 9, etag: "x")
        if case .mask = known { Issue.record("no mask expected") }
        #expect(known != nil)
    }
}

extension SubjectMaskCache.Result: Equatable {
    public static func == (lhs: SubjectMaskCache.Result, rhs: SubjectMaskCache.Result) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none): true
        case (.mask(let a), .mask(let b)): a.squareCoverage == b.squareCoverage
        default: false
        }
    }
}
