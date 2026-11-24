// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import ImageIO
import PhotosModel
import Testing
import UniformTypeIdentifiers

@testable import PhotosMedia

/// Spatial photos and panoramas for Vision Pro (SPEC §6.2, M5).
@Suite struct SpatialMediaTests {
    func image() throws -> CGImage {
        let context = try #require(
            CGContext(
                data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        return try #require(context.makeImage())
    }

    /// A HEIC as iPhone writes a spatial photo: two images in a stereo pair group.
    func writeHEIC(stereo: Bool) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "spatial-\(UUID().uuidString).heic")
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, stereo ? 2 : 1, nil))
        let image = try image()
        if stereo {
            for left in [true, false] {
                let group: [CFString: Any] = [
                    kCGImagePropertyGroupIndex: 0, kCGImagePropertyGroupType: kCGImagePropertyGroupTypeStereoPair,
                    left ? kCGImagePropertyGroupImageIsLeftImage : kCGImagePropertyGroupImageIsRightImage: true,
                ]
                CGImageDestinationAddImage(destination, image, [kCGImagePropertyGroups: group] as CFDictionary)
            }
        } else {
            CGImageDestinationAddImage(destination, image, nil)
        }
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test func aStereoPairIsASpatialPhoto() throws {
        let stereo = try writeHEIC(stereo: true)
        let flat = try writeHEIC(stereo: false)
        defer {
            try? FileManager.default.removeItem(at: stereo)
            try? FileManager.default.removeItem(at: flat)
        }
        #expect(SpatialMedia.isStereoPair(file: stereo))
        #expect(!SpatialMedia.isStereoPair(file: flat))
        #expect(!SpatialMedia.isStereoPair(file: URL(filePath: "/nonexistent.heic")))
    }

    @Test func aGroupOfAnotherTypeIsNotAStereoPair() {
        let alternate: [CFString: Any] = [
            kCGImagePropertyGroups: [[kCGImagePropertyGroupType: "Alternate", kCGImagePropertyGroupImageIndexLeft: 0]]
        ]
        #expect(!SpatialMedia.isStereoPair(properties: alternate))
        #expect(!SpatialMedia.isStereoPair(properties: [:]))
    }

    @Test func onlyHEICCanBeSpatial() {
        #expect(SpatialMedia.maySpatial(MediaItem(fileId: 1, path: "/a.HEIC", mimeType: "image/heic")))
        #expect(!SpatialMedia.maySpatial(MediaItem(fileId: 2, path: "/a.jpg", mimeType: "image/jpeg")))
        #expect(!SpatialMedia.maySpatial(MediaItem(fileId: 3, path: "/a.mov", mimeType: "video/quicktime")))
    }

    @Test func wideLargeStillsArePanoramas() {
        func item(_ width: Int?, _ height: Int?, mime: String = "image/jpeg") -> MediaItem {
            MediaItem(fileId: 1, path: "/p.jpg", mimeType: mime, width: width, height: height)
        }
        #expect(SpatialMedia.isPanorama(item(12_000, 3_000)))
        #expect(SpatialMedia.isPanorama(item(8_192, 4_096)))
        #expect(!SpatialMedia.isPanorama(item(4_032, 3_024)))
        #expect(!SpatialMedia.isPanorama(item(2_400, 600)))
        #expect(!SpatialMedia.isPanorama(item(nil, nil)))
        #expect(!SpatialMedia.isPanorama(item(12_000, 0)))
        #expect(!SpatialMedia.isPanorama(item(12_000, 3_000, mime: "video/mp4")))
    }

    @Test func aPanoramaReachesAsFarAsItIsWide() {
        #expect(abs(SpatialMedia.panoramaArc(width: 3, height: 1) - .pi) < 0.0001)
        #expect(SpatialMedia.panoramaArc(width: 20, height: 1) == 2 * .pi)
        #expect(SpatialMedia.panoramaArc(width: 0, height: 0) == .pi / 2)
    }
}
