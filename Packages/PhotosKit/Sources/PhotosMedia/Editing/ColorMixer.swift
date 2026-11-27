// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Synchronization

/// Hue, saturation and luminance of eight colour ranges (SPEC §21.6.2), as in Lightroom's and Photos' colour mixers:
/// "make the sky a deeper blue", "calm the oranges of a face", "turn the greens to autumn".
///
/// Rendered as a 3-D colour lookup table (`CIColorCubeWithColorSpace`, 32³ entries in sRGB) computed once per setting.
/// The formula is in docs/EDIT-FORMAT.md, so other apps render the same picture.
public struct ColorMixer: Hashable, Sendable {
    /// The eight ranges, by the hue at their centre (degrees). Neighbouring ranges overlap: a hue between two centres
    /// belongs to both, in proportion to how close it is, so a change never shows an edge.
    public enum Band: String, CaseIterable, Sendable {
        case red, orange, yellow, green, aqua, blue, purple, magenta

        public var hue: Double {
            switch self {
            case .red: 0
            case .orange: 30
            case .yellow: 60
            case .green: 120
            case .aqua: 180
            case .blue: 225
            case .purple: 270
            case .magenta: 315
            }
        }
    }

    /// The change of one range; each value −1 … 1, 0 is unchanged.
    public struct Adjustment: Hashable, Sendable {
        /// Moves the hue toward the neighbouring range: −1 / +1 is `ColorMixer.maximumHueShift` degrees.
        public var hue: Double = 0
        /// −1 removes the colour, +1 doubles its saturation.
        public var saturation: Double = 0
        /// −1 darkens the colour, +1 brightens it (greys and whites stay as they are).
        public var luminance: Double = 0

        public init(hue: Double = 0, saturation: Double = 0, luminance: Double = 0) {
            self.hue = hue
            self.saturation = saturation
            self.luminance = luminance
        }

        public var isIdentity: Bool { hue == 0 && saturation == 0 && luminance == 0 }

        /// Values from a file: not finite is 0, the rest kept to −1 … 1.
        func clamped() -> Adjustment {
            func clamp(_ value: Double) -> Double { value.isFinite ? min(1, max(-1, value)) : 0 }
            return Adjustment(hue: clamp(hue), saturation: clamp(saturation), luminance: clamp(luminance))
        }
    }

    /// How far a hue of ±1 turns the colour, in degrees.
    public static let maximumHueShift = 30.0
    /// Entries per side of the lookup table.
    static let cubeSize = 32

    public var bands: [Band: Adjustment] = [:]

    public init(_ bands: [Band: Adjustment] = [:]) {
        self.bands = bands.filter { !$0.value.isIdentity }
    }

    public subscript(band: Band) -> Adjustment {
        get { bands[band] ?? Adjustment() }
        set { bands[band] = newValue.isIdentity ? nil : newValue }
    }

    public var isIdentity: Bool { bands.values.allSatisfy(\.isIdentity) }

    // MARK: The formula

    /// How much of each range a hue (degrees) belongs to: 1 at the range's centre, falling linearly to 0 at the
    /// neighbouring centres; the weights of a hue add up to 1.
    static func weights(hue: Double) -> [(Band, Double)] {
        let bands = Band.allCases
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        for (index, band) in bands.enumerated() {
            let next = bands[(index + 1) % bands.count]
            let start = band.hue
            var end = next.hue
            if end <= start { end += 360 }
            var x = h
            if x < start { x += 360 }
            if x >= start && x < end {
                let t = (x - start) / (end - start)
                return [(band, 1 - t), (next, t)]
            }
        }
        return [(.red, 1)]
    }

    /// One colour (sRGB, 0 … 1) through the mixer.
    func map(red: Double, green: Double, blue: Double) -> (Double, Double, Double) {
        let (hue, saturation, lightness) = Self.hsl(red, green, blue)
        guard saturation > 0.0001 else { return (red, green, blue) }
        var hueShift = 0.0
        var saturationChange = 0.0
        var luminanceChange = 0.0
        for (band, weight) in Self.weights(hue: hue) where weight > 0 {
            let adjustment = self[band]
            hueShift += weight * adjustment.hue
            saturationChange += weight * adjustment.saturation
            luminanceChange += weight * adjustment.luminance
        }
        let newHue = hue + hueShift * Self.maximumHueShift
        let newSaturation = min(1, max(0, saturation * (1 + saturationChange)))
        // Weighted by the colour's saturation so greys stay grey; toward white or black by the room there is.
        let room = luminanceChange > 0 ? 1 - lightness : lightness
        let newLightness = min(1, max(0, lightness + luminanceChange * 0.5 * saturation * room))
        return Self.rgb(newHue, newSaturation, newLightness)
    }

    static func hsl(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let maximum = max(r, g, b)
        let minimum = min(r, g, b)
        let lightness = (maximum + minimum) / 2
        let delta = maximum - minimum
        guard delta > 0 else { return (0, 0, lightness) }
        let saturation = delta / (1 - abs(2 * lightness - 1))
        var hue: Double
        if maximum == r {
            hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        } else if maximum == g {
            hue = (b - r) / delta + 2
        } else {
            hue = (r - g) / delta + 4
        }
        hue *= 60
        if hue < 0 { hue += 360 }
        return (hue, min(1, saturation), lightness)
    }

    static func rgb(_ hue: Double, _ saturation: Double, _ lightness: Double) -> (Double, Double, Double) {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let x = chroma * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = lightness - chroma / 2
        let (r, g, b): (Double, Double, Double)
        switch h {
        case ..<1: (r, g, b) = (chroma, x, 0)
        case ..<2: (r, g, b) = (x, chroma, 0)
        case ..<3: (r, g, b) = (0, chroma, x)
        case ..<4: (r, g, b) = (0, x, chroma)
        case ..<5: (r, g, b) = (x, 0, chroma)
        default: (r, g, b) = (chroma, 0, x)
        }
        return (min(1, max(0, r + m)), min(1, max(0, g + m)), min(1, max(0, b + m)))
    }

    // MARK: Rendering

    /// The lookup table: RGBA floats, red changing fastest, as `CIColorCube` reads it.
    func cube() -> Data {
        let size = Self.cubeSize
        var values = [Float](repeating: 1, count: size * size * size * 4)
        let step = 1 / Double(size - 1)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let mapped = map(red: Double(r) * step, green: Double(g) * step, blue: Double(b) * step)
                    let offset = ((b * size + g) * size + r) * 4
                    values[offset] = Float(mapped.0)
                    values[offset + 1] = Float(mapped.1)
                    values[offset + 2] = Float(mapped.2)
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Tables already made: moving a slider in the editor makes one per step, the grid reuses them for every tile.
    private static let cubes = Mutex<[ColorMixer: Data]>([:])

    func cachedCube() -> Data {
        if let known = Self.cubes.withLock({ $0[self] }) { return known }
        let made = cube()
        Self.cubes.withLock { cache in
            if cache.count >= 32 { cache.removeAll(keepingCapacity: true) }
            cache[self] = made
        }
        return made
    }

    public func apply(to image: CIImage) -> CIImage {
        guard !isIdentity else { return image }
        let filter = CIFilter.colorCubeWithColorSpace()
        filter.inputImage = image
        filter.cubeDimension = Float(Self.cubeSize)
        filter.cubeData = cachedCube()
        filter.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        filter.extrapolate = false
        return filter.outputImage ?? image
    }
}
