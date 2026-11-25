// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import PhotosDomain

/// Between Core Graphics images and the pixels `LoupeAnalysis` works on (SPEC §16.5.2). Drawing into a bitmap context on
/// the CPU; no filters, no GPU.
public enum LoupeImages {
    /// What the loupe shows over a photo.
    public struct Analysis: Sendable {
        public var histogram: LoupeHistogram
        /// Red over blown highlights, blue over blocked shadows; nil when nothing is clipped.
        public var clipping: CGImage?
        public var clippedShare: Double
        /// The sharpest edges in a bright colour; nil when nothing is sharp.
        public var peaking: CGImage?
    }

    /// The image drawn into sRGB RGBA pixels, scaled down so its long side is at most `maxPixels`.
    public static func pixels(of image: CGImage, maxPixels: Int) -> RGBAPixels? {
        let longSide = max(image.width, image.height)
        guard longSide > 0, maxPixels > 0 else { return nil }
        let scale = min(1, Double(maxPixels) / Double(longSide))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? RGBAPixels(width: width, height: height, bytes: bytes) : nil
    }

    /// An overlay's pixels as an image (premultiplied: the marks are opaque, the rest fully transparent).
    public static func image(from pixels: RGBAPixels) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), let provider = CGDataProvider(data: Data(pixels.bytes) as CFData)
        else { return nil }
        return CGImage(
            width: pixels.width, height: pixels.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: pixels.width * 4,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// The long side the overlays are computed at: fine enough for a full screen, fast enough for each photo.
    public static let overlayPixels = 2048
    /// The histogram needs far fewer pixels.
    public static let histogramPixels = 512

    /// Histogram, clipping and peaking of a photo. Call off the main thread.
    public static func analyse(_ image: CGImage, clipping: Bool, peaking: Bool) -> Analysis? {
        guard let small = pixels(of: image, maxPixels: histogramPixels) else { return nil }
        var analysis = Analysis(histogram: LoupeAnalysis.histogram(small), clipping: nil, clippedShare: 0, peaking: nil)
        guard clipping || peaking, let large = pixels(of: image, maxPixels: overlayPixels) else { return analysis }
        if clipping {
            let overlay = LoupeAnalysis.clipping(large)
            analysis.clippedShare = overlay.coverage
            if overlay.coverage > 0 { analysis.clipping = Self.image(from: overlay.pixels) }
        }
        if peaking {
            let overlay = LoupeAnalysis.focusPeaking(large)
            if overlay.coverage > 0 { analysis.peaking = Self.image(from: overlay.pixels) }
        }
        return analysis
    }
}
