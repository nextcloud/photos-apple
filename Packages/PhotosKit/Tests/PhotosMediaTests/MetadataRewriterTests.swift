// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import PhotosMedia

/// Dates and places written into the file for servers without metadata editing (SPEC §16.4).
@Suite(.disabled(if: TestEnvironment.isSimulator, TestEnvironment.noGPU)) struct MetadataRewriterTests {
    func makeJPEG(in directory: URL, gps: Bool) throws -> URL {
        let url = directory.appending(path: "photo.jpg")
        let context = try #require(
            CGContext(
                data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2020:01:01 10:00:00"]]
        if gps {
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: 10.0, kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 20.0,
                kCGImagePropertyGPSLongitudeRef: "E",
            ]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "rewriter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func writesDateOffsetAndPlace() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try makeJPEG(in: folder, gps: false)
        // 2024-06-14 07:12 UTC in +02:00 is 09:12 on the camera's clock.
        let change = MetadataRewriter.Change(
            capturedAt: Date(timeIntervalSince1970: 1_718_349_120), offset: 7200, latitude: -33.86, longitude: 151.21)
        let written = try #require(MetadataRewriter.rewrite(file, with: change, in: folder))
        let read = MetadataRewriter.read(written)
        #expect(read.date == "2024:06:14 09:12:00")
        #expect(read.offset == "+02:00")
        #expect(abs((read.latitude ?? 0) + 33.86) < 0.0001)
        #expect(abs((read.longitude ?? 0) - 151.21) < 0.0001)
    }

    @Test func removesThePlaceAndKeepsTheRest() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try makeJPEG(in: folder, gps: true)
        #expect(MetadataRewriter.read(file).latitude == 10)
        let written = try #require(MetadataRewriter.rewrite(file, with: .init(removeLocation: true), in: folder))
        let read = MetadataRewriter.read(written)
        #expect(read.latitude == nil)
        #expect(read.date == "2020:01:01 10:00:00")
    }

    @Test func refusesWhatItCannotRewrite() throws {
        #expect(!MetadataRewriter.canRewrite(fileName: "clip.mov"))
        #expect(!MetadataRewriter.canRewrite(fileName: "IMG.DNG"))
        #expect(MetadataRewriter.canRewrite(fileName: "IMG.HEIC"))
        #expect(MetadataRewriter.exifStrings(Date(timeIntervalSince1970: 0), offset: nil) == ("1970:01:01 00:00:00", nil))
        #expect(MetadataRewriter.exifStrings(Date(timeIntervalSince1970: 0), offset: -5 * 3600 - 1800).offset == "-05:30")
    }
}
