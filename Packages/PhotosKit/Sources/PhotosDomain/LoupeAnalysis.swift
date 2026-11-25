// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// 8-bit RGBA pixels, row after row (`width * 4` bytes per row), as the loupe analyses them (SPEC §16.5.2). Alpha is
/// ignored.
public struct RGBAPixels: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var bytes: [UInt8]

    public init(width: Int, height: Int, bytes: [UInt8]) {
        precondition(bytes.count == width * height * 4, "RGBA bytes do not match the size")
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    /// A picture of one colour (tests, placeholders).
    public init(width: Int, height: Int, fill: (UInt8, UInt8, UInt8)) {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            bytes[index] = fill.0
            bytes[index + 1] = fill.1
            bytes[index + 2] = fill.2
        }
        self.init(width: width, height: height, bytes: bytes)
    }
}

/// The histogram of a photo: 256 counts per channel and for the luminance.
public struct LoupeHistogram: Sendable, Equatable {
    public var red: [Int]
    public var green: [Int]
    public var blue: [Int]
    public var luminance: [Int]

    public init(red: [Int], green: [Int], blue: [Int], luminance: [Int]) {
        self.red = red
        self.green = green
        self.blue = blue
        self.luminance = luminance
    }

    public static let empty = LoupeHistogram(
        red: Array(repeating: 0, count: 256), green: Array(repeating: 0, count: 256), blue: Array(repeating: 0, count: 256),
        luminance: Array(repeating: 0, count: 256))

    /// The highest count, for scaling the chart. The ends (pure black and white) are left out: one clipped sky
    /// otherwise flattens everything else.
    public var scale: Int {
        let inner = [red, green, blue, luminance].flatMap { $0.dropFirst().dropLast() }
        return max(inner.max() ?? 0, 1)
    }
}

/// What the loupe draws over a photo: where highlights or shadows are clipped, where it is sharp.
public struct LoupeOverlay: Sendable, Equatable {
    public var pixels: RGBAPixels
    /// How much of the photo is marked (0…1).
    public var coverage: Double

    public init(pixels: RGBAPixels, coverage: Double) {
        self.pixels = pixels
        self.coverage = coverage
    }
}

/// Histogram, clipping warnings and focus peaking computed on the device from a photo's pixels (SPEC §16.5.2). Plain
/// arithmetic on the CPU: no GPU, no Vision, so it works the same in every environment.
public enum LoupeAnalysis {
    /// Rec. 709 luma weights in 1/1024 (integer arithmetic).
    static func luma(_ red: Int, _ green: Int, _ blue: Int) -> Int {
        (red * 218 + green * 732 + blue * 74) >> 10
    }

    public static func histogram(_ image: RGBAPixels) -> LoupeHistogram {
        var red = [Int](repeating: 0, count: 256)
        var green = [Int](repeating: 0, count: 256)
        var blue = [Int](repeating: 0, count: 256)
        var luminance = [Int](repeating: 0, count: 256)
        image.bytes.withUnsafeBufferPointer { bytes in
            var index = 0
            let count = bytes.count
            while index < count {
                let r = Int(bytes[index])
                let g = Int(bytes[index + 1])
                let b = Int(bytes[index + 2])
                red[r] += 1
                green[g] += 1
                blue[b] += 1
                luminance[min(luma(r, g, b), 255)] += 1
                index += 4
            }
        }
        return LoupeHistogram(red: red, green: green, blue: blue, luminance: luminance)
    }

    /// A highlight is clipped when a channel is at the top (a blown sky shows in red as Lightroom does); a shadow when
    /// all three are at the bottom (shown in blue).
    public static let highlightLimit: UInt8 = 254
    public static let shadowLimit: UInt8 = 1

    /// Red over clipped highlights, blue over clipped shadows, transparent elsewhere.
    public static func clipping(_ image: RGBAPixels) -> LoupeOverlay {
        var output = [UInt8](repeating: 0, count: image.bytes.count)
        var marked = 0
        image.bytes.withUnsafeBufferPointer { bytes in
            output.withUnsafeMutableBufferPointer { out in
                var index = 0
                let count = bytes.count
                while index < count {
                    let r = bytes[index]
                    let g = bytes[index + 1]
                    let b = bytes[index + 2]
                    if r >= highlightLimit || g >= highlightLimit || b >= highlightLimit {
                        out[index] = 255
                        out[index + 1] = 0
                        out[index + 2] = 0
                        out[index + 3] = 255
                        marked += 1
                    } else if r <= shadowLimit && g <= shadowLimit && b <= shadowLimit {
                        out[index] = 0
                        out[index + 1] = 90
                        out[index + 2] = 255
                        out[index + 3] = 255
                        marked += 1
                    }
                    index += 4
                }
            }
        }
        let total = max(image.width * image.height, 1)
        return LoupeOverlay(
            pixels: RGBAPixels(width: image.width, height: image.height, bytes: output), coverage: Double(marked) / Double(total))
    }

    /// The gradient strength below which nothing is marked, whatever the photo: a soft photo shows no peaking at all
    /// instead of its least soft edges.
    public static let peakingFloor = 120
    /// The share of a photo's pixels at most marked: the sharpest edges, not every texture.
    public static let peakingShare = 0.06

    /// Focus peaking: the sharpest edges (Sobel gradient of the luma) in a bright colour, so the plane of focus stands
    /// out. The threshold adapts to the photo (its sharpest `peakingShare`) but never goes below `peakingFloor`.
    public static func focusPeaking(_ image: RGBAPixels, color: (UInt8, UInt8, UInt8) = (255, 40, 200)) -> LoupeOverlay {
        let width = image.width
        let height = image.height
        var output = [UInt8](repeating: 0, count: image.bytes.count)
        guard width >= 3, height >= 3 else {
            return LoupeOverlay(pixels: RGBAPixels(width: width, height: height, bytes: output), coverage: 0)
        }
        // Luma first, then the gradient magnitude (|gx| + |gy|, 0…2040).
        var lumaPlane = [Int16](repeating: 0, count: width * height)
        image.bytes.withUnsafeBufferPointer { bytes in
            lumaPlane.withUnsafeMutableBufferPointer { plane in
                for pixel in 0..<(width * height) {
                    let index = pixel * 4
                    plane[pixel] = Int16(luma(Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2])))
                }
            }
        }
        var magnitude = [UInt16](repeating: 0, count: width * height)
        var counts = [Int](repeating: 0, count: 2041)
        lumaPlane.withUnsafeBufferPointer { plane in
            magnitude.withUnsafeMutableBufferPointer { out in
                for y in 1..<(height - 1) {
                    let above = (y - 1) * width
                    let row = y * width
                    let below = (y + 1) * width
                    for x in 1..<(width - 1) {
                        let a = Int(plane[above + x - 1])
                        let b = Int(plane[above + x])
                        let c = Int(plane[above + x + 1])
                        let d = Int(plane[row + x - 1])
                        let f = Int(plane[row + x + 1])
                        let g = Int(plane[below + x - 1])
                        let h = Int(plane[below + x])
                        let i = Int(plane[below + x + 1])
                        let gx = (c + 2 * f + i) - (a + 2 * d + g)
                        let gy = (g + 2 * h + i) - (a + 2 * b + c)
                        let value = min(abs(gx) + abs(gy), 2040)
                        out[row + x] = UInt16(value)
                        counts[value] += 1
                    }
                }
            }
        }
        // The threshold: the strength above which the sharpest share lies, at least the floor.
        let allowed = Int(Double(width * height) * peakingShare)
        var threshold = 2040
        var above = 0
        while threshold > peakingFloor {
            above += counts[threshold]
            if above > allowed { break }
            threshold -= 1
        }
        threshold = max(threshold + 1, peakingFloor)
        var marked = 0
        magnitude.withUnsafeBufferPointer { values in
            output.withUnsafeMutableBufferPointer { out in
                for pixel in 0..<(width * height) where Int(values[pixel]) >= threshold {
                    let index = pixel * 4
                    out[index] = color.0
                    out[index + 1] = color.1
                    out[index + 2] = color.2
                    out[index + 3] = 255
                    marked += 1
                }
            }
        }
        return LoupeOverlay(
            pixels: RGBAPixels(width: width, height: height, bytes: output), coverage: Double(marked) / Double(width * height))
    }
}

// MARK: - Loupe geometry

/// Where the loupe looks: the zoom that shows the photo's own pixels (100 %), and the point under the pointer kept in
/// place while zooming in (SPEC §16.5.2).
public enum LoupeGeometry {
    /// The scale at which a picture of `pixels` fits in `area` (points per pixel).
    public static func fitScale(pixels: CGSize, area: CGSize) -> CGFloat {
        guard pixels.width > 0, pixels.height > 0, area.width > 0, area.height > 0 else { return 1 }
        return min(area.width / pixels.width, area.height / pixels.height)
    }

    /// The zoom (relative to "fit") at which one pixel of the photo is one pixel of the screen. Never below 1: a photo
    /// smaller than the area is shown whole.
    public static func actualPixelsZoom(pixels: CGSize, area: CGSize, displayScale: CGFloat) -> CGFloat {
        let fit = fitScale(pixels: pixels, area: area)
        guard fit > 0, displayScale > 0 else { return 1 }
        return max(1, 1 / (displayScale * fit))
    }

    /// The point of the photo (fractions of its width and height) under `location` in the area, with the photo fitted and
    /// centred; clamped into the photo.
    public static func photoPoint(at location: CGPoint, pixels: CGSize, area: CGSize) -> CGPoint {
        let fit = fitScale(pixels: pixels, area: area)
        let shown = CGSize(width: pixels.width * fit, height: pixels.height * fit)
        guard shown.width > 0, shown.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        let origin = CGPoint(x: (area.width - shown.width) / 2, y: (area.height - shown.height) / 2)
        let x = (location.x - origin.x) / shown.width
        let y = (location.y - origin.y) / shown.height
        return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    /// The centre (fractions of the picture) kept so that the zoomed picture covers its area wherever it can.
    public static func clampedCenter(_ center: CGPoint, shown: CGSize, area: CGSize) -> CGPoint {
        func clamp(_ value: CGFloat, shownLength: CGFloat, areaLength: CGFloat) -> CGFloat {
            guard shownLength > areaLength, shownLength > 0 else { return 0.5 }
            let half = areaLength / 2 / shownLength
            return min(max(value, half), 1 - half)
        }
        return CGPoint(
            x: clamp(center.x, shownLength: shown.width, areaLength: area.width),
            y: clamp(center.y, shownLength: shown.height, areaLength: area.height))
    }

    /// The photos the filmstrip keeps loaded around the current one.
    public static func window(around index: Int, count: Int, radius: Int) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let lower = max(0, min(index, count - 1) - radius)
        let upper = min(count, max(index, 0) + radius + 1)
        return lower..<max(lower, upper)
    }

    /// The photo after a rating key with auto-advance: the next one, or the same at the end.
    public static func advanced(from index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(index + 1, count - 1)
    }
}
