// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import PhotosMedia

/// Lossless previews of 1024 px and up become HEIC in the background (SPEC §22.4.4).
@Suite(.disabled(if: TestEnvironment.isSimulator, TestEnvironment.noGPU)) struct PreviewCompactionTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "compaction-\(UUID().uuidString)")

    /// A photograph-like picture (gradients and noise: what PNG compresses badly), optionally with a transparent half.
    static func picture(side: Int = 1024, transparentHalf: Bool = false) -> CGImage {
        let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var seed: UInt64 = 7
        for y in stride(from: 0, to: side, by: 4) {
            for x in stride(from: 0, to: side, by: 4) {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1
                let noise = Double(seed >> 58) / 64
                context.setFillColor(
                    red: Double(x) / Double(side), green: Double(y) / Double(side), blue: 0.3 + noise * 0.4, alpha: 1)
                context.fill(CGRect(x: x, y: y, width: 4, height: 4))
            }
        }
        if transparentHalf { context.clear(CGRect(x: side / 2, y: 0, width: side / 2, height: side)) }
        return context.makeImage()!
    }

    static func png(_ image: CGImage) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    func write(_ data: Data, name: String) throws -> URL {
        let url = directory.appending(path: "12").appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    func type(_ url: URL) -> String? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceGetType($0) as String? }
    }

    @Test func pngBecomesSmallerHEICUnderItsNameWithItsDate() throws {
        guard PreviewTranscoding.canWriteHEIC else { return }
        let png = Self.png(Self.picture())
        let url = try write(png, name: "4712-abc-1024.jpg")
        let used = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: used], ofItemAtPath: url.path(percentEncoded: false))

        let sizes = try #require(PreviewCompactor.compact(file: url))
        #expect(sizes.before == png.count)
        #expect(sizes.after < png.count)
        #expect(type(url) == UTType.heic.identifier)
        #expect(try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == used)
        let image = try #require(ImageDecoding.decode(url: url, maxPixelSize: 1024))
        #expect(image.width == 1024)
        // Nothing left behind next to it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path(percentEncoded: false)).count == 1)
    }

    @Test func transparencyIsKept() throws {
        guard PreviewTranscoding.canWriteHEIC else { return }
        let url = try write(Self.png(Self.picture(transparentHalf: true)), name: "4712-abc-4096.jpg")
        #expect(PreviewCompactor.compact(file: url) != nil)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyHasAlpha] as? Bool == true)
        // A pixel of the transparent half is still transparent.
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -900, y: -500, width: 1024, height: 1024))
        #expect(context.data!.assumingMemoryBound(to: UInt8.self)[3] < 10)
    }

    @Test func jpegAndSmallBucketsAreLeftAlone() throws {
        let jpeg = try #require(ImageDecoding.jpegData(Self.picture()))
        let url = try write(jpeg, name: "4712-abc-1024.jpg")
        #expect(PreviewCompactor.compact(file: url) == nil)
        #expect(try Data(contentsOf: url) == jpeg)
        #expect(!PreviewCompactor.isCandidate(directory.appending(path: "12/4712-abc-256.jpg")))
        #expect(PreviewCompactor.isCandidate(directory.appending(path: "12/4712-abc-1024.jpg")))
        #expect(PreviewCompactor.isCandidate(directory.appending(path: "12/4712-abc-4096.jpg")))
    }

    /// Stored through the cache, it is converted a moment later; earlier files are found by the one scan.
    @Test func cacheQueuesWhatItStoresAndTheScanFindsTheRest() async throws {
        guard PreviewTranscoding.canWriteHEIC else { return }
        let png = Self.png(Self.picture())
        let earlier = try write(png, name: "1-old-1024.jpg")
        let small = try write(png, name: "1-old-256.jpg")
        let compactor = PreviewCompactor(directory: directory, startDelay: .zero)
        let suite = "compaction-\(UUID().uuidString)"
        compactor.scanOnce(suiteName: suite)
        try await Task.sleep(for: .milliseconds(200))
        await compactor.waitUntilIdle()
        #expect(type(earlier) == UTType.heic.identifier)
        #expect(type(small) == UTType.png.identifier)
        #expect(UserDefaults(suiteName: suite)?.bool(forKey: compactor.scanKey) == true)

        let stored = try write(png, name: "2-new-1024.jpg")
        compactor.didStore(stored, data: png, bucket: 1024)
        compactor.didStore(stored, data: png, bucket: 1024)  // once is enough
        await compactor.waitUntilIdle()
        #expect(type(stored) == UTType.heic.identifier)
        #expect(compactor.totals.files == 2)
    }

    /// Before/after on real server previews: `PHOTOS_HEIC_SAMPLES` is a folder of 1024/4096 px PNG previews. Prints the
    /// sizes and the decode times at 1024 px (`PERF` lines).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PHOTOS_HEIC_SAMPLES"] != nil))
    func measureServerPreviews() throws {
        let folder = URL(filePath: ProcessInfo.processInfo.environment["PHOTOS_HEIC_SAMPLES"]!)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }.sorted { $0.path < $1.path }
        var before = 0
        var after = 0
        var pngDecode = 0.0
        var heicDecode = 0.0
        for file in files {
            let png = try Data(contentsOf: file)
            guard let heic = PreviewTranscoding.heic(from: png) else {
                print("PERF heic \(file.lastPathComponent): not smaller, kept")
                before += png.count
                after += png.count
                continue
            }
            func decode(_ data: Data) -> Double {
                var best = Double.infinity
                for _ in 0..<5 {
                    let start = ContinuousClock.now
                    _ = ImageDecoding.decode(data: data, maxPixelSize: 1024)
                    let elapsed = ContinuousClock.now - start
                    best = min(best, Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
                }
                return best
            }
            let (p, h) = (decode(png), decode(heic))
            pngDecode += p
            heicDecode += h
            before += png.count
            after += heic.count
            print(
                "PERF heic \(file.lastPathComponent): \(png.count) → \(heic.count) bytes, decode at 1024 px \(String(format: "%.1f", p)) → \(String(format: "%.1f", h)) ms"
            )
        }
        print(
            "PERF heic total \(files.count) previews: \(before) → \(after) bytes (\(after * 100 / max(before, 1)) %), decode \(String(format: "%.1f", pngDecode)) → \(String(format: "%.1f", heicDecode)) ms"
        )
    }
}
