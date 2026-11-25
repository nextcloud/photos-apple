// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import ImageIO
import PhotosModel
import Testing

@testable import PhotosMedia

@Suite(.timeLimit(.minutes(1))) struct SmartOfflinePipelineTests {
    let server = PreviewStubServer()
    let directory = FileManager.default.temporaryDirectory.appending(path: "smart-pipeline-\(UUID().uuidString)")

    /// A preview kept by smart offline is decoded instead of asking the server, at the size asked for, and not copied
    /// into the preview cache.
    @Test func keptPreviewsAreUsedWithoutTheServer() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let api = server.api
        let cache = PreviewCache(directory: directory.appending(path: "previews"))
        let pipeline = ImagePipeline(
            api: api, cache: cache, originals: OriginalStore(directory: directory.appending(path: "originals"), dav: api.dav))
        let kept = directory.appending(path: "kept.jpg")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try StickerTestImages.jpeg(width: 400, height: 300).write(to: kept)
        await pipeline.setLocalPreviewProvider { fileId, etag, bucket in
            fileId == 1 && etag == "e1" && bucket <= 2048 ? kept : nil
        }
        let image = await pipeline.preview(ImagePipeline.Request(fileId: 1, etag: "e1", bucket: 256, maxPixelSize: 200))
        #expect(image?.width == 200)
        #expect(server.started.isEmpty)
        #expect(!cache.hasDiskImage(fileId: 1, etag: "e1", bucket: 256))
        // A larger preview than what is kept comes from the server.
        _ = await pipeline.preview(ImagePipeline.Request(fileId: 1, etag: "e1", bucket: 4096))
        #expect(server.started == [1])
    }
}

/// Pictures for the sticker tests.
enum StickerTestImages {
    static func jpeg(width: Int, height: Int) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: 0.8, green: 0.3, blue: 0.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ImageDecoding.jpegData(context.makeImage()!)!
    }

    /// A transparent square with an opaque red disc in the middle: what a lifted subject looks like.
    static func cutout(size: Int = 200) -> CGImage {
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.clear(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fillEllipse(in: CGRect(x: size / 4, y: size / 4, width: size / 2, height: size / 2))
        return context.makeImage()!
    }

    /// RGBA of one pixel (origin top left).
    static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        var data = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (data[0], data[1], data[2], data[3])
    }
}

@Suite(.timeLimit(.minutes(2)), .disabled(if: TestEnvironment.isSimulator, TestEnvironment.noGPU)) struct StickerStyleTests {
    @Test(arguments: StickerStyle.allCases) func everyStyleKeepsTheBackgroundTransparent(style: StickerStyle) throws {
        let styled = try #require(StickerMaker.styled(StickerTestImages.cutout(), style: style))
        #expect(StickerTestImages.pixel(styled, x: 0, y: 0).a == 0)
        let centre = StickerTestImages.pixel(styled, x: styled.width / 2, y: styled.height / 2)
        #expect(centre.a == 255)
    }

    @Test func theOutlineIsWhiteAroundTheSubject() throws {
        let styled = try #require(StickerMaker.styled(StickerTestImages.cutout(), style: .outline))
        // Just outside the red disc on its left, halfway down: the white border.
        let row = styled.height / 2
        var x = 0
        while x < styled.width && StickerTestImages.pixel(styled, x: x, y: row).r < 250
            || StickerTestImages.pixel(styled, x: x, y: row).g < 250
        {
            x += 1
            if x >= styled.width / 2 { break }
        }
        let border = StickerTestImages.pixel(styled, x: x, y: row)
        #expect(border.a > 200)
        #expect(border.g > 240 && border.b > 240)
    }

    @Test func theShadowFallsBelowTheSubject() throws {
        let original = try #require(StickerMaker.styled(StickerTestImages.cutout(), style: .original))
        let shadowed = try #require(StickerMaker.styled(StickerTestImages.cutout(), style: .shadow))
        // The shadow makes the sticker taller than the subject alone.
        #expect(shadowed.height > original.height)
    }

    @Test func largeCutoutsAreScaledDown() throws {
        let styled = try #require(StickerMaker.styled(StickerTestImages.cutout(size: 2400), style: .original))
        #expect(max(styled.width, styled.height) <= StickerMaker.maxSize)
    }

    @Test func pngAndHEICKeepTheTransparency() throws {
        let styled = try #require(StickerMaker.styled(StickerTestImages.cutout(), style: .outline))
        for data in [StickerMaker.pngData(styled), StickerMaker.heicData(styled)] {
            let encoded = try #require(data)
            let source = try #require(CGImageSourceCreateWithData(encoded as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(StickerTestImages.pixel(image, x: 0, y: 0).a == 0)
        }
    }

    @Test func aPictureWithoutFacesOrSubjectsKeepsItWhole() {
        let context = CGContext(
            data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let focus = FocusFinder.focus(in: context.makeImage()!)
        #expect(focus.width > 0 && focus.height > 0)
        #expect(CGRect(x: 0, y: 0, width: 1, height: 1).contains(focus))
    }
}

/// Lifts the subjects of real photos with Vision (needs a Mac or device with the Neural Engine; not the simulator). Runs only
/// with `PHOTOS_STICKER_SAMPLES=<folder of JPEGs>`; writes every style as `<name>-<style>.png` and a collage focus report
/// into `PHOTOS_STICKER_OUTPUT` (default: the same folder).
@Suite(.timeLimit(.minutes(2)), .disabled(if: TestEnvironment.isSimulator, TestEnvironment.noGPU)) struct StickerSampleTests {
    @Test func liftsTheSubjectsOfSamplePhotos() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let folder = environment["PHOTOS_STICKER_SAMPLES"], !folder.isEmpty else { return }
        let output = URL(fileURLWithPath: environment["PHOTOS_STICKER_OUTPUT"] ?? folder)
        let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "jpg" }
        #expect(!files.isEmpty)
        var lifted = 0
        for file in files {
            let image = try #require(ImageDecoding.decode(url: file, maxPixelSize: 4096))
            let name = file.deletingPathExtension().lastPathComponent
            let focus = FocusFinder.focus(in: image)
            try "\(name): focus \(focus)\n".write(to: output.appending(path: "\(name)-focus.txt"), atomically: true, encoding: .utf8)
            guard let cutout = try? StickerMaker.lift(image) else { continue }
            lifted += 1
            for style in StickerStyle.allCases {
                let styled = try #require(StickerMaker.styled(cutout, style: style))
                try #require(StickerMaker.pngData(styled)).write(to: output.appending(path: "\(name)-\(style.rawValue).png"))
            }
        }
        #expect(lifted > 0)
    }
}
