// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import Testing

@testable import PhotosDomain
@testable import PhotosMedia

/// The loupe's overlays from real Core Graphics images (SPEC §16.5.2). They draw into bitmap contexts: Mac only, like the
/// other rendering tests.
@Suite(.disabled(if: TestEnvironment.isSimulator, TestEnvironment.noGPU), .timeLimit(.minutes(1)))
struct LoupeImagesTests {
    /// Black on the left, white on the right.
    static func edgeImage(width: Int, height: Int) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        return try #require(context.makeImage())
    }

    @Test func pixelsAreScaledDownToTheLimit() throws {
        let image = try Self.edgeImage(width: 400, height: 200)
        let pixels = try #require(LoupeImages.pixels(of: image, maxPixels: 100))
        #expect(pixels.width == 100 && pixels.height == 50)
        #expect(pixels.bytes[0] == 0 && pixels.bytes[(99) * 4] == 255)
        let full = try #require(LoupeImages.pixels(of: image, maxPixels: 4000))
        #expect(full.width == 400 && full.height == 200)
    }

    @Test func overlaysRoundTripIntoImages() throws {
        let overlay = LoupeAnalysis.clipping(RGBAPixels(width: 3, height: 2, fill: (255, 255, 255)))
        let image = try #require(LoupeImages.image(from: overlay.pixels))
        #expect(image.width == 3 && image.height == 2)
        let back = try #require(LoupeImages.pixels(of: image, maxPixels: 3))
        #expect(Array(back.bytes[0..<4]) == [255, 0, 0, 255])
    }

    @Test func analysisOfAPhoto() throws {
        let image = try Self.edgeImage(width: 600, height: 300)
        let quick = try #require(LoupeImages.analyse(image, clipping: false, peaking: false))
        #expect(quick.histogram.luminance[0] > 0 && quick.histogram.luminance[255] > 0)
        #expect(quick.clipping == nil && quick.peaking == nil)
        let full = try #require(LoupeImages.analyse(image, clipping: true, peaking: true))
        // Everything is pure black or white: all clipped. The one edge is sharp.
        #expect(full.clippedShare > 0.99)
        #expect(full.clipping?.width == 600)
        #expect(full.peaking != nil)
    }
}
