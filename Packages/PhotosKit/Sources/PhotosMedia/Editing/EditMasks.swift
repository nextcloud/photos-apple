// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CryptoKit
import Foundation
import Synchronization
import Vision

/// Adjustments of one part of the photo (SPEC §21.6.3): the subject, the background, the sky or the people, found on the
/// device each time the photo is rendered. Only the kind of mask is stored — never the mask itself — so the edit stays a
/// few hundred bytes, follows a better segmentation in a later version, and fits the original at any size.
public struct MaskAdjustment: Hashable, Sendable {
    public enum Target: String, CaseIterable, Sendable {
        /// The main subjects (people, pets, objects in front): Vision's foreground instance mask.
        case subject
        /// Everything but the subject.
        case background
        /// The sky: a colour, smoothness and position heuristic, confirmed by Vision's scene classification.
        case sky
        /// All people: Vision's person segmentation.
        case people
    }

    public var target: Target
    /// Everything but the target (the land under the sky, everybody but the people).
    public var inverted = false
    public var exposure: Double = 0
    public var brightness: Double = 0
    public var contrast: Double = 1
    public var highlights: Double = 1
    public var shadows: Double = 0
    public var saturation: Double = 1
    public var vibrance: Double = 0
    public var warmth: Double = 0
    public var tint: Double = 0
    public var sharpness: Double = 0

    public init(target: Target, inverted: Bool = false) {
        self.target = target
        self.inverted = inverted
    }

    /// The adjustments a mask has, by name, with the value that means "unchanged" (the same names and ranges as the
    /// photo's own adjustments).
    static var adjustments: [(name: String, keyPath: WritableKeyPath<MaskAdjustment, Double>, neutral: Double)] {
        [
            ("exposure", \.exposure, 0), ("brightness", \.brightness, 0), ("contrast", \.contrast, 1), ("highlights", \.highlights, 1),
            ("shadows", \.shadows, 0), ("saturation", \.saturation, 1), ("vibrance", \.vibrance, 0), ("warmth", \.warmth, 0),
            ("tint", \.tint, 0), ("sharpness", \.sharpness, 0),
        ]
    }

    /// No adjustment is set: the mask changes nothing.
    public var isIdentity: Bool {
        Self.adjustments.allSatisfy { self[keyPath: $0.keyPath] == $0.neutral }
    }

    /// The same adjustments as photo edits, for the renderer.
    var edits: PhotoEdits {
        var edits = PhotoEdits()
        edits.exposure = exposure
        edits.brightness = brightness
        edits.contrast = contrast
        edits.highlights = highlights
        edits.shadows = shadows
        edits.saturation = saturation
        edits.vibrance = vibrance
        edits.warmth = warmth
        edits.tint = tint
        edits.sharpness = sharpness
        return edits
    }
}

/// Finds the parts of a photo that masks adjust (SPEC §21.6.3), on the device, with Vision where Apple offers a
/// segmentation and a heuristic for the sky (no public API segments the sky). Masks are computed on a small copy of the
/// picture (at most `workSize` pixels on the long edge) and scaled up along the picture's own edges
/// (`CIEdgePreserveUpsampleFilter`), so a mask costs the same for a tile and for a 48-megapixel export.
public enum EditMasks {
    /// Long edge of the picture the masks are found on.
    static let workSize: CGFloat = 768
    /// Long edge of the picture the sky heuristic reads.
    static let skySize: CGFloat = 192

    /// Masks found already, by target and picture: moving a slider in the editor or drawing tiles does not run Vision
    /// again. Grey, white where the target is, at work size.
    private static let cache = Mutex<[String: CGImage?]>([:])

    /// The mask of `target` on `image` (grey, white where the target is, the extent of `image`), or nil when there is
    /// none (no subject, no sky) or Vision cannot run here (the simulator).
    public static func mask(_ target: MaskAdjustment.Target, inverted: Bool = false, for image: CIImage) -> CIImage? {
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1, extent.width.isFinite, extent.height.isFinite else { return nil }
        let source: MaskAdjustment.Target = target == .background ? .subject : target
        let invert = (target == .background) != inverted
        guard let small = smallMask(source, for: image) else {
            // No subject: the background is the whole picture.
            return invert ? CIImage(color: .white).cropped(to: extent) : nil
        }
        var mask = CIImage(cgImage: small)
        if invert {
            let filter = CIFilter.colorInvert()
            filter.inputImage = mask
            mask = filter.outputImage ?? mask
        }
        let upsample = CIFilter.edgePreserveUpsample()
        upsample.inputImage = image
        upsample.smallImage = mask
        upsample.spatialSigma = 3
        upsample.lumaSigma = 0.15
        let scaled =
            upsample.outputImage
            ?? mask.transformed(
                by: CGAffineTransform(scaleX: extent.width / CGFloat(small.width), y: extent.height / CGFloat(small.height)))
        return scaled.cropped(to: extent)
    }

    /// The mask at work size, from the cache or found now.
    static func smallMask(_ target: MaskAdjustment.Target, for image: CIImage) -> CGImage? {
        guard let key = fingerprint(image).map({ "\(target.rawValue)-\($0)" }) else { return nil }
        if let known = cache.withLock({ $0[key] }) { return known }
        let made = makeMask(target, for: image)
        cache.withLock { cache in
            if cache.count >= 24 { cache.removeAll(keepingCapacity: true) }
            cache[key] = made
        }
        return made
    }

    /// A short fingerprint of a picture: its size and an 8 × 8 thumbnail. The same photo gives the same key in every
    /// render; another photo (or another key photo, or another RAW development) a different one.
    static func fingerprint(_ image: CIImage) -> String? {
        let extent = image.extent
        let scale = CGAffineTransform(scaleX: 8 / extent.width, y: 8 / extent.height)
        let thumbnail = image.transformed(by: scale)
        var bytes = [UInt8](repeating: 0, count: 8 * 8 * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        PhotoEditor.context.render(
            thumbnail, toBitmap: &bytes, rowBytes: 8 * 4,
            bounds: CGRect(x: thumbnail.extent.minX, y: thumbnail.extent.minY, width: 8, height: 8),
            format: .RGBA8, colorSpace: space)
        var hasher = SHA256()
        hasher.update(data: Data(bytes))
        hasher.update(data: Data("\(Int(extent.width))x\(Int(extent.height))".utf8))
        return hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The picture at work size, as Vision and the heuristic read it.
    static func workImage(_ image: CIImage, longEdge: CGFloat) -> CGImage? {
        let extent = image.extent
        let scale = min(1, longEdge / max(extent.width, extent.height))
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return PhotoEditor.context.createCGImage(
            scaled, from: scaled.extent.integral, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    static func makeMask(_ target: MaskAdjustment.Target, for image: CIImage) -> CGImage? {
        switch target {
        case .subject, .background:
            guard let work = workImage(image, longEdge: workSize) else { return nil }
            return subjectMask(work)
        case .people:
            guard let work = workImage(image, longEdge: workSize) else { return nil }
            return peopleMask(work)
        case .sky:
            guard let work = workImage(image, longEdge: skySize) else { return nil }
            if let likely = skyLikelihood(work), likely < 0.05 { return nil }
            guard let pixels = rgba(of: work) else { return nil }
            guard let alpha = skyMask(rgba: pixels, width: work.width, height: work.height) else { return nil }
            return greyImage(alpha, width: work.width, height: work.height)
        }
    }

    // MARK: Vision

    static func subjectMask(_ image: CGImage) -> CGImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil, let observation = request.results?.first, !observation.allInstances.isEmpty,
            let buffer = try? observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler),
            let (alpha, width, height) = SubjectMasking.alphaBytes(of: buffer)
        else { return nil }
        return greyImage(alpha, width: width, height: height)
    }

    static func peopleMask(_ image: CGImage) -> CGImage? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent32Float
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil, let buffer = request.results?.first?.pixelBuffer,
            let (alpha, width, height) = SubjectMasking.alphaBytes(of: buffer)
        else { return nil }
        // No person: an empty mask is no mask.
        guard alpha.contains(where: { $0 > 128 }) else { return nil }
        return greyImage(alpha, width: width, height: height)
    }

    /// How sure Vision's scene classification is that the photo shows sky; nil when it cannot run here.
    static func skyLikelihood(_ image: CGImage) -> Double? {
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil, let results = request.results else { return nil }
        let sky = results.filter { $0.identifier == "sky" || $0.identifier.contains("sky") || $0.identifier == "sunset_sunrise" }
        return Double(sky.map(\.confidence).max() ?? 0)
    }

    // MARK: Sky

    /// The sky of a small picture (RGBA, rows from the top): pixels that look like sky — blue, or bright and nearly
    /// colourless (an overcast sky), or bright warm (a sunset) — that are smooth (no texture of leaves or walls), and
    /// that connect to the top edge through such pixels. 255 for sky, 0 elsewhere, slightly softened; nil when less
    /// than 2 % of the picture is sky.
    static func skyMask(rgba: [UInt8], width: Int, height: Int) -> [UInt8]? {
        guard width > 2, height > 2, rgba.count >= width * height * 4 else { return nil }
        let count = width * height
        var luma = [Double](repeating: 0, count: count)
        var candidate = [Bool](repeating: false, count: count)
        for index in 0..<count {
            let r = Double(rgba[index * 4]) / 255
            let g = Double(rgba[index * 4 + 1]) / 255
            let b = Double(rgba[index * 4 + 2]) / 255
            luma[index] = 0.299 * r + 0.587 * g + 0.114 * b
        }
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                let r = Double(rgba[index * 4]) / 255
                let g = Double(rgba[index * 4 + 1]) / 255
                let b = Double(rgba[index * 4 + 2]) / 255
                let maximum = max(r, g, b)
                let minimum = min(r, g, b)
                let saturation = maximum > 0 ? (maximum - minimum) / maximum : 0
                let (hue, _, _) = ColorMixer.hsl(r, g, b)
                let blue = hue >= 185 && hue <= 255 && b >= r && maximum > 0.3
                let overcast = saturation < 0.16 && maximum > 0.62
                let warm = (hue <= 50 || hue >= 330) && maximum > 0.55 && y < height / 2
                let left = luma[y * width + max(0, x - 1)]
                let right = luma[y * width + min(width - 1, x + 1)]
                let up = luma[max(0, y - 1) * width + x]
                let down = luma[min(height - 1, y + 1) * width + x]
                let gradient = abs(right - left) + abs(down - up)
                candidate[index] = (blue || overcast || warm) && gradient < 0.07
            }
        }
        // Grown from the top edge through candidates whose brightness changes slowly.
        var sky = [Bool](repeating: false, count: count)
        var queue: [Int] = (0..<width).filter { candidate[$0] }
        for index in queue { sky[index] = true }
        var head = 0
        while head < queue.count {
            let index = queue[head]
            head += 1
            let x = index % width
            let y = index / width
            let neighbours = [
                x > 0 ? index - 1 : -1, x < width - 1 ? index + 1 : -1, y > 0 ? index - width : -1, y < height - 1 ? index + width : -1,
            ]
            for next in neighbours where next >= 0 && !sky[next] && candidate[next] && abs(luma[next] - luma[index]) < 0.05 {
                sky[next] = true
                queue.append(next)
            }
        }
        let skyCount = sky.lazy.filter { $0 }.count
        guard Double(skyCount) >= Double(count) * 0.02 else { return nil }
        // Holes: what is not sky and does not reach the bottom edge through other such pixels lies inside the sky — a
        // textured cloud, a bird, a contrail — and is sky too. Buildings, trees and hills stand on the ground and stay out.
        var ground = [Bool](repeating: false, count: count)
        var stack: [Int] = ((height - 1) * width..<count).filter { !sky[$0] }
        for index in stack { ground[index] = true }
        while let index = stack.popLast() {
            let x = index % width
            let y = index / width
            let neighbours = [
                x > 0 ? index - 1 : -1, x < width - 1 ? index + 1 : -1, y > 0 ? index - width : -1, y < height - 1 ? index + width : -1,
            ]
            for next in neighbours where next >= 0 && !sky[next] && !ground[next] {
                ground[next] = true
                stack.append(next)
            }
        }
        for index in 0..<count where !ground[index] { sky[index] = true }
        // Softened by a 3 × 3 average: the edge-preserving upsampling then follows the picture's own edges.
        var mask = [UInt8](repeating: 0, count: count)
        for y in 0..<height {
            for x in 0..<width {
                var sum = 0
                var samples = 0
                for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = x + dx
                        let ny = y + dy
                        guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                        samples += 1
                        if sky[ny * width + nx] { sum += 255 }
                    }
                }
                mask[y * width + x] = UInt8(sum / max(1, samples))
            }
        }
        return mask
    }

    // MARK: Pixels

    static func rgba(of image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    /// A grey picture from bytes (rows from the top).
    static func greyImage(_ values: [UInt8], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, values.count >= width * height, let provider = CGDataProvider(data: Data(values) as CFData) else {
            return nil
        }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: true,
            intent: .defaultIntent)
    }

    // MARK: Rendering

    /// The masks' adjustments on `image`; `source` is the picture the masks are found on (the photo before any edit, so
    /// a mask stays the same while sliders move).
    static func apply(_ masks: [MaskAdjustment], to image: CIImage, source: CIImage) -> CIImage {
        var output = image
        for adjustment in masks where !adjustment.isIdentity {
            guard let mask = mask(adjustment.target, inverted: adjustment.inverted, for: source) else { continue }
            let adjusted = PhotoEditor.applyAdjustments(adjustment.edits, to: output)
            let blend = CIFilter.blendWithRedMask()
            blend.inputImage = adjusted
            blend.backgroundImage = output
            blend.maskImage = mask
            output = blend.outputImage?.cropped(to: output.extent) ?? output
        }
        return output
    }
}
