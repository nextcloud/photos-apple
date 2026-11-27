// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CryptoKit
import Foundation
import Synchronization

/// Fills in the masked part of a square picture (`DiffusionFill`; tests use engines of their own).
public protocol InpaintingEngine: Sendable {
    /// Names the engine and its version in the keys of filled areas: another engine never reuses another's result.
    var identifier: String { get }
    /// The side of the square picture the engine works on, in pixels.
    var side: Int { get }
    /// `image` is side × side RGBA (sRGB), `mask` side × side grey (not black: fill in). Returns the picture with the
    /// masked part filled in; only that part is used.
    func fill(image: CGImage, mask: CGImage) throws -> CGImage
}

/// The Remove tool's rendering step (SPEC §21.5): fills in the strokes of `RetouchSteps` on any picture of the photo —
/// the editor's proxy, the grid's preview, the original at full resolution on save.
///
/// Each stroke is filled in a window around it with room for context (at least the engine's side at the picture's own
/// resolution, so small objects are filled at full detail; larger ones are filled scaled down), and only its area is
/// blended in, softly. Strokes apply in order, each on the result of the ones before. Filled areas are cached by what
/// they were made from, so adjusting colours, undo and redo, and the next rendition never fill again.
public enum Inpainting {
    /// The fill the app uses: classic image processing, no machine-learning model (SPEC §21).
    public static var engine: any InpaintingEngine { DiffusionFill() }

    /// The steps filled in on `input`. On the main thread a filled area made for a slightly different picture (another
    /// RAW development of the same photo) is used rather than filling again while the user waits; elsewhere it is
    /// always made for exactly this picture.
    public static func apply(_ steps: RetouchSteps?, to input: CIImage) -> CIImage {
        apply(steps, to: input, engine: engine, allowStale: Thread.isMainThread)
    }

    public static func apply(
        _ steps: RetouchSteps?, to input: CIImage, engine: any InpaintingEngine, allowStale: Bool = false
    ) -> CIImage {
        guard let steps, !steps.isIdentity, !input.extent.isInfinite, !input.extent.isEmpty else { return input }
        var image = input
        var key = "\(engine.identifier)|\(fingerprint(input))"
        var looseKey = "\(engine.identifier)|\(Int(input.extent.width))x\(Int(input.extent.height))"
        for (index, stroke) in steps.strokes.enumerated() {
            let digest = Self.digest(stroke)
            key = Self.hash(key + "|" + digest)
            looseKey = Self.hash(looseKey + "|" + digest)
            let patch: CIImage?
            if let cached = cache.patch(key: key, looseKey: allowStale ? looseKey : nil) {
                patch = cached
            } else {
                patch = try? makePatch(for: stroke, earlier: Array(steps.strokes[..<index]), on: image, engine: engine)
                if let patch { cache.store(patch, key: key, looseKey: looseKey) }
            }
            if let patch { image = patch.composited(over: image).cropped(to: input.extent) }
        }
        return image
    }

    /// Fills in the steps on `input` off the main thread so that the next `apply` on the main thread finds them ready
    /// (the editor calls this before it shows a new stroke).
    public static func prepare(_ steps: RetouchSteps, on input: CIImage) async {
        let engine = engine
        await Task.detached(priority: .userInitiated) {
            _ = apply(steps, to: input, engine: engine, allowStale: false)
        }.value
    }

    // MARK: Filling one stroke

    /// The window a stroke is filled in: the stroke with twice its size around it, at least `side` pixels when the
    /// picture is that large, and inside the picture.
    static func window(around rect: CGRect, in extent: CGRect, side: Int) -> CGRect {
        let wanted = max(max(rect.width, rect.height) * 2.2, CGFloat(side))
        let width = min(wanted, extent.width)
        let height = min(wanted, extent.height)
        let x = min(max(rect.midX - width / 2, extent.minX), extent.maxX - width)
        let y = min(max(rect.midY - height / 2, extent.minY), extent.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height).integral.intersection(extent)
    }

    /// The stroke's bounds in the picture's Core Image coordinates.
    static func pixelBounds(of stroke: RetouchStroke, in extent: CGRect) -> CGRect? {
        guard let bounds = stroke.bounds(in: extent.size) else { return nil }
        let rect = CGRect(
            x: extent.minX + bounds.minX * extent.width, y: extent.minY + (1 - bounds.maxY) * extent.height,
            width: bounds.width * extent.width, height: bounds.height * extent.height)
        let visible = rect.intersection(extent)
        return visible.isNull || visible.isEmpty ? nil : visible
    }

    /// The stroke filled in: the engine's result in the stroke's area, transparent elsewhere, in `image`'s coordinates.
    /// Earlier strokes that touch it are filled in again together with it: a person and then their reflection, or an
    /// object and then the shadow it left, are filled as one hole, so the first fill's guess at the edge of what was
    /// still there does not stay.
    static func makePatch(
        for stroke: RetouchStroke, earlier: [RetouchStroke] = [], on image: CIImage, engine: any InpaintingEngine
    ) throws -> CIImage? {
        let extent = image.extent
        guard let own = pixelBounds(of: stroke, in: extent) else { return nil }
        // Earlier strokes touching this one are filled again with it; the window holds all of them, so none is cut by
        // the window's edge (which would leave a seam).
        let near = own.insetBy(dx: -own.width / 4 - 2, dy: -own.height / 4 - 2)
        let touching = earlier.filter { pixelBounds(of: $0, in: extent)?.intersects(near) ?? false }
        let bounds = touching.reduce(own) { $0.union(pixelBounds(of: $1, in: extent) ?? $0) }
        let side = engine.side
        let window = window(around: bounds, in: extent, side: side)
        guard window.width >= 2, window.height >= 2 else { return nil }
        let sx = CGFloat(side) / window.width
        let sy = CGFloat(side) / window.height
        let square = CGRect(x: 0, y: 0, width: side, height: side)
        let toSquare = CGAffineTransform(translationX: -window.minX, y: -window.minY).concatenating(CGAffineTransform(scaleX: sx, y: sy))
        let scaled = image.clampedToExtent().transformed(by: toSquare).cropped(to: square)
        guard let picture = PhotoEditor.context.createCGImage(scaled, from: square, format: .RGBA8, colorSpace: sRGB),
            let mask = mask(of: touching + [stroke], extent: extent, toSquare: toSquare, side: side)
        else { return nil }
        let filled = try engine.fill(image: picture, mask: mask)
        // The area blended in: the mask a little larger, with a soft edge (outside the mask the engine returns the
        // picture it was given, so the soft edge never shows a seam).
        let maskImage = CIImage(cgImage: mask)
        let grown = maskImage.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 2])
        let alpha = grown.clampedToExtent().applyingGaussianBlur(sigma: 1.5).cropped(to: square)
        let blend = CIFilter.blendWithMask()
        blend.inputImage = CIImage(cgImage: filled).cropped(to: square)
        blend.backgroundImage = CIImage.empty()
        blend.maskImage = alpha
        guard let output = blend.outputImage else { return nil }
        // Rendered now: the patch is reused many times and must not keep the engine's buffers alive.
        guard let rendered = PhotoEditor.context.createCGImage(output, from: square, format: .RGBA8, colorSpace: sRGB) else { return nil }
        return CIImage(cgImage: rendered).transformed(by: toSquare.inverted()).cropped(to: window)
    }

    /// The strokes as one side × side grey mask of the window `toSquare` maps to the square.
    static func mask(of strokes: [RetouchStroke], extent: CGRect, toSquare: CGAffineTransform, side: Int) -> CGImage? {
        let square = CGRect(x: 0, y: 0, width: side, height: side)
        var combined: CIImage?
        for stroke in strokes {
            guard let mask = mask(of: stroke, extent: extent, toSquare: toSquare, side: side) else { continue }
            combined = combined.map { mask.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: $0]) } ?? mask
        }
        guard let combined, let space = CGColorSpace(name: CGColorSpace.linearGray) else { return nil }
        return PhotoEditor.context.createCGImage(combined.cropped(to: square), from: square, format: .L8, colorSpace: space)
    }

    /// One stroke as a side × side mask of the window, grown.
    static func mask(of stroke: RetouchStroke, extent: CGRect, toSquare: CGAffineTransform, side: Int) -> CIImage? {
        guard let space = CGColorSpace(name: CGColorSpace.linearGray),
            let context = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side, space: space,
                bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.setFillColor(gray: 1, alpha: 1)
        context.setStrokeColor(gray: 1, alpha: 1)
        context.concatenate(toSquare)
        let short = min(extent.width, extent.height)
        func pixel(_ point: RetouchPoint) -> CGPoint {
            CGPoint(x: extent.minX + point.x * extent.width, y: extent.minY + (1 - point.y) * extent.height)
        }
        switch stroke {
        case .brush(let brush):
            let radius = brush.radius * short
            if brush.points.count == 1, let point = brush.points.first {
                let center = pixel(point)
                context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            } else {
                context.setLineWidth(radius * 2)
                context.setLineCap(.round)
                context.setLineJoin(.round)
                context.addLines(between: brush.points.map(pixel))
                context.strokePath()
            }
        case .area(let area):
            guard let cells = area.cells, let image = grey(cells, width: area.width, height: area.height) else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: extent)
        }
        guard let drawn = context.makeImage() else { return nil }
        // Smoothly scaled cells cut at half; grown by `grow`, and every stroke by a few of the engine's pixels at least:
        // the fill must not see the object's soft edge (`RetouchStroke.Area.defaultGrow`).
        var growth = minimumGrowth
        if case .area(let area) = stroke { growth = max(growth, area.grow * short * (toSquare.a + toSquare.d) / 2) }
        let threshold = CIFilter.colorThreshold()
        threshold.inputImage = CIImage(cgImage: drawn)
        threshold.threshold = 0.5
        guard let cut = threshold.outputImage else { return nil }
        return cut.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: growth])
            .cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
    }

    /// How much every stroke grows, in the engine's pixels: a brushed object's soft edge goes with it.
    static let minimumGrowth: CGFloat = 4

    static func grey(_ bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.linearGray), let provider = CGDataProvider(data: Data(bytes) as CFData) else {
            return nil
        }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: true,
            intent: .defaultIntent)
    }

    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    // MARK: Keys

    /// A short fingerprint of a picture: its size and 8 × 8 samples. Two renditions of the same photo at the same size
    /// differ in it as soon as their pixels differ (another RAW development, another key photo).
    static func fingerprint(_ image: CIImage) -> String {
        let extent = image.extent
        var bytes = [UInt8](repeating: 0, count: 8 * 8 * 4)
        let small = image.transformed(
            by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
                .concatenating(CGAffineTransform(scaleX: 8 / extent.width, y: 8 / extent.height)))
        PhotoEditor.context.render(
            small, toBitmap: &bytes, rowBytes: 8 * 4, bounds: CGRect(x: 0, y: 0, width: 8, height: 8), format: .RGBA8, colorSpace: sRGB)
        return hash("\(Int(extent.width))x\(Int(extent.height))|" + Data(bytes).base64EncodedString())
    }

    static func digest(_ stroke: RetouchStroke) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return hash(String(decoding: (try? encoder.encode(stroke)) ?? Data(), as: UTF8.self))
    }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Cache

    static let cache = PatchCache()

    /// Filled areas by what they were made from. A few dozen stay in memory (each is at most the engine's side squared,
    /// a few megabytes); the oldest go first.
    final class PatchCache: Sendable {
        struct Entry {
            var patch: CIImage
            var used: Int
        }

        struct State {
            var entries: [String: Entry] = [:]
            var loose: [String: String] = [:]
            var clock = 0
        }

        let limit: Int
        private let state = Mutex(State())

        init(limit: Int = 24) {
            self.limit = limit
        }

        func patch(key: String, looseKey: String?) -> CIImage? {
            state.withLock { state in
                state.clock += 1
                let found = state.entries[key] != nil ? key : looseKey.flatMap { state.loose[$0] }
                guard let found, var entry = state.entries[found] else { return nil }
                entry.used = state.clock
                state.entries[found] = entry
                return entry.patch
            }
        }

        func store(_ patch: CIImage, key: String, looseKey: String) {
            state.withLock { state in
                state.clock += 1
                state.entries[key] = Entry(patch: patch, used: state.clock)
                state.loose[looseKey] = key
                while state.entries.count > limit, let oldest = state.entries.min(by: { $0.value.used < $1.value.used })?.key {
                    state.entries[oldest] = nil
                    state.loose = state.loose.filter { $0.value != oldest }
                }
            }
        }

        var count: Int { state.withLock { $0.entries.count } }

        func removeAll() {
            state.withLock { $0 = State() }
        }
    }
}

// MARK: - Basic fill

/// The Erase tool's fill: the surroundings pulled smoothly into the hole ("push–pull" over an image pyramid). Good for
/// spots, dust and small things on even backgrounds; it does not invent detail, so large objects on busy backgrounds
/// leave a soft patch.
public struct DiffusionFill: InpaintingEngine {
    public let identifier = "diffusion-1"
    public let side: Int

    public init(side: Int = 512) {
        self.side = side
    }

    public func fill(image: CGImage, mask: CGImage) throws -> CGImage {
        let n = side
        guard let pixels = Self.rgba(image, side: n), let holes = Self.grey(mask, side: n) else { throw CocoaError(.coderReadCorrupt) }
        // Level 0: colours weighted by "known" (1 outside the mask, 0 inside).
        var weights = [Float](repeating: 0, count: n * n)
        var colours = [Float](repeating: 0, count: n * n * 3)
        for index in 0..<(n * n) where holes[index] == 0 {
            weights[index] = 1
            for channel in 0..<3 { colours[index * 3 + channel] = Float(pixels[index * 4 + channel]) }
        }
        // Push: sums of 2 × 2 blocks up to one pixel.
        var levels: [(weights: [Float], colours: [Float], size: Int)] = [(weights, colours, n)]
        while let last = levels.last, last.size > 1 {
            let size = (last.size + 1) / 2
            var w = [Float](repeating: 0, count: size * size)
            var c = [Float](repeating: 0, count: size * size * 3)
            for y in 0..<last.size {
                for x in 0..<last.size {
                    let from = y * last.size + x
                    let to = (y / 2) * size + x / 2
                    w[to] += last.weights[from]
                    for channel in 0..<3 { c[to * 3 + channel] += last.colours[from * 3 + channel] }
                }
            }
            levels.append((w, c, size))
        }
        // Pull: each level's known colour where it has one, the coarser level's (smoothly scaled) elsewhere.
        var coarse = [Float](repeating: 0, count: 3)
        var coarseSize = 1
        for level in levels.reversed() {
            var result = [Float](repeating: 0, count: level.size * level.size * 3)
            for y in 0..<level.size {
                for x in 0..<level.size {
                    let index = y * level.size + x
                    let weight = level.weights[index]
                    let confidence = min(1, weight)
                    let up = Self.sample(coarse, size: coarseSize, x: (Float(x) + 0.5) / 2 - 0.5, y: (Float(y) + 0.5) / 2 - 0.5)
                    for channel in 0..<3 {
                        let own = weight > 0 ? level.colours[index * 3 + channel] / weight : 0
                        result[index * 3 + channel] = confidence * own + (1 - confidence) * up[channel]
                    }
                }
            }
            coarse = result
            coarseSize = level.size
        }
        var output = pixels
        for index in 0..<(n * n) where holes[index] != 0 {
            for channel in 0..<3 { output[index * 4 + channel] = UInt8(max(0, min(255, coarse[index * 3 + channel].rounded()))) }
            output[index * 4 + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(output) as CFData),
            let result = CGImage(
                width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4, space: Inpainting.sRGB,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil,
                shouldInterpolate: true, intent: .defaultIntent)
        else { throw CocoaError(.coderInvalidValue) }
        return result
    }

    /// Bilinear sample of an RGB float image, clamped at the edges.
    static func sample(_ image: [Float], size: Int, x: Float, y: Float) -> [Float] {
        let fx = min(Float(size - 1), max(0, x))
        let fy = min(Float(size - 1), max(0, y))
        let x0 = Int(fx)
        let y0 = Int(fy)
        let x1 = min(size - 1, x0 + 1)
        let y1 = min(size - 1, y0 + 1)
        let tx = fx - Float(x0)
        let ty = fy - Float(y0)
        var result = [Float](repeating: 0, count: 3)
        for channel in 0..<3 {
            let a = image[(y0 * size + x0) * 3 + channel] * (1 - tx) + image[(y0 * size + x1) * 3 + channel] * tx
            let b = image[(y1 * size + x0) * 3 + channel] * (1 - tx) + image[(y1 * size + x1) * 3 + channel] * tx
            result[channel] = a * (1 - ty) + b * ty
        }
        return result
    }

    /// The picture as RGBA bytes, row by row from the top.
    static func rgba(_ image: CGImage, side: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: Inpainting.sRGB,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn ? bytes : nil
    }

    static func grey(_ image: CGImage, side: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: side * side)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.linearGray),
                let context = CGContext(
                    data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side, space: space,
                    bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn ? bytes : nil
    }
}
