// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// A colour in sRGB, each channel 0…1 (SPEC §16.8.1).
public struct PaletteColor: Hashable, Sendable, Codable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = Self.clamp(red)
        self.green = Self.clamp(green)
        self.blue = Self.clamp(blue)
    }

    /// From 8-bit channels.
    public init(bytes red: UInt8, _ green: UInt8, _ blue: UInt8) {
        self.init(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }

    public static let black = PaletteColor(red: 0, green: 0, blue: 0)
    public static let white = PaletteColor(red: 1, green: 1, blue: 1)

    static func clamp(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }

    /// WCAG 2 relative luminance.
    public var relativeLuminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG 2 contrast ratio (1…21).
    public func contrast(with other: PaletteColor) -> Double {
        let a = relativeLuminance
        let b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// `amount` 0 is this colour, 1 is `other`.
    public func mixed(with other: PaletteColor, amount: Double) -> PaletteColor {
        let t = Self.clamp(amount)
        return PaletteColor(
            red: red + (other.red - red) * t, green: green + (other.green - green) * t, blue: blue + (other.blue - blue) * t)
    }

    // MARK: HSL

    /// Hue 0…1 (fraction of the colour wheel), saturation and lightness 0…1.
    public var hsl: (hue: Double, saturation: Double, lightness: Double) {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let lightness = (maximum + minimum) / 2
        let delta = maximum - minimum
        guard delta > 1e-9 else { return (0, 0, lightness) }
        let saturation = delta / (1 - abs(2 * lightness - 1))
        var hue: Double
        if maximum == red {
            hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
        } else if maximum == green {
            hue = (blue - red) / delta + 2
        } else {
            hue = (red - green) / delta + 4
        }
        hue /= 6
        if hue < 0 { hue += 1 }
        return (hue, min(1, saturation), lightness)
    }

    public init(hue: Double, saturation: Double, lightness: Double) {
        let s = Self.clamp(saturation)
        let l = Self.clamp(lightness)
        let chroma = (1 - abs(2 * l - 1)) * s
        let h = (hue - floor(hue)) * 6
        let x = chroma * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Double, Double, Double)
        switch h {
        case ..<1: (r, g, b) = (chroma, x, 0)
        case ..<2: (r, g, b) = (x, chroma, 0)
        case ..<3: (r, g, b) = (0, chroma, x)
        case ..<4: (r, g, b) = (0, x, chroma)
        case ..<5: (r, g, b) = (x, 0, chroma)
        default: (r, g, b) = (chroma, 0, x)
        }
        let m = l - chroma / 2
        self.init(red: r + m, green: g + m, blue: b + m)
    }

    /// The same hue and saturation at the lightness whose relative luminance is closest to `target`. Luminance grows with
    /// HSL lightness for a fixed hue and saturation, so a bisection finds it.
    public func withLuminance(_ target: Double, saturation: Double? = nil) -> PaletteColor {
        let (hue, ownSaturation, _) = hsl
        let s = saturation ?? ownSaturation
        var low = 0.0
        var high = 1.0
        for _ in 0..<32 {
            let middle = (low + high) / 2
            if PaletteColor(hue: hue, saturation: s, lightness: middle).relativeLuminance < target {
                low = middle
            } else {
                high = middle
            }
        }
        return PaletteColor(hue: hue, saturation: s, lightness: (low + high) / 2)
    }
}

/// Finds the colour that stands for a photo, from a handful of its pixels (a decoded BlurHash or a tiny preview).
public enum PhotoPalette {
    /// Pixels below this chroma count as grey.
    static let neutralChroma = 0.08
    /// A colourful hue must hold at least this share of the weight to win over grey.
    static let colourShare = 0.2

    /// The dominant colour: the mean of the hue family that carries most weight, where colourful pixels weigh more than
    /// grey ones (a red coat on a grey street gives red, not grey). Grey photos give their mean grey. Nil for no pixels.
    public static func dominant(_ pixels: [PaletteColor]) -> PaletteColor? {
        guard !pixels.isEmpty else { return nil }
        // 12 hue families of 30°, and one for greys.
        var weights = [Double](repeating: 0, count: 13)
        var sums = [(r: Double, g: Double, b: Double)](repeating: (0, 0, 0), count: 13)
        for pixel in pixels {
            let (hue, saturation, lightness) = pixel.hsl
            let chroma = saturation * (1 - abs(2 * lightness - 1))
            let bin = chroma < neutralChroma ? 12 : min(11, Int(hue * 12))
            let weight = 0.15 + chroma * 2
            weights[bin] += weight
            sums[bin].r += pixel.red * weight
            sums[bin].g += pixel.green * weight
            sums[bin].b += pixel.blue * weight
        }
        let total = weights.reduce(0, +)
        let colourful = (0..<12).max { weights[$0] < weights[$1] } ?? 12
        let chosen = weights[colourful] >= total * colourShare ? colourful : 12
        let weight = weights[chosen]
        guard weight > 0 else { return nil }
        return PaletteColor(red: sums[chosen].r / weight, green: sums[chosen].g / weight, blue: sums[chosen].b / weight)
    }
}

/// Where a photo's colour is used, and how it is toned for that place so text on it stays readable (SPEC §16.8.1).
public enum PhotoTintRole: Sendable, CaseIterable {
    /// The viewer's backdrop behind the photo, under white bars and buttons.
    case backdrop
    /// The base of the viewer's ambient glow (a little brighter than `backdrop`).
    case ambient
    /// The wash behind a header in Light Mode, under black text.
    case headerLight
    /// The wash behind a header in Dark Mode, under white text.
    case headerDark
    /// The gradient under white titles on a memory card.
    case scrim

    /// The text colour drawn on it.
    public var text: PaletteColor {
        switch self {
        case .headerLight: .black
        default: .white
        }
    }

    /// The least contrast with `text` the toned colour keeps (WCAG AAA for normal text: 7:1).
    public var minimumContrast: Double { 7 }

    /// Relative luminance the toned colour aims for.
    var luminance: Double {
        switch self {
        case .backdrop: 0.012
        case .ambient: 0.03
        case .headerLight: 0.72
        case .headerDark: 0.028
        case .scrim: 0.012
        }
    }

    /// The luminance for a photo of this saturation. On a dark role a grey photo stays close to black: a dark grey
    /// backdrop only looks washed out; the tint is there to carry a colour.
    func luminance(saturation: Double) -> Double {
        guard text == .white else { return luminance }
        return luminance * (0.35 + 0.65 * min(1, saturation / 0.3))
    }

    /// Highest saturation: deep, not loud.
    var maximumSaturation: Double {
        switch self {
        case .backdrop: 0.55
        case .ambient: 0.7
        case .headerLight: 0.45
        case .headerDark: 0.5
        case .scrim: 0.6
        }
    }
}

extension PhotoTintRole {
    /// The photo's dominant colour toned for this role: its hue, a calmer saturation, a fixed luminance, and never less
    /// contrast with the text on it than `minimumContrast`.
    public func tone(_ dominant: PaletteColor) -> PaletteColor {
        let saturation = min(dominant.hsl.saturation, maximumSaturation)
        var toned = dominant.withLuminance(luminance(saturation: dominant.hsl.saturation), saturation: saturation)
        // The bisection lands within a hair of the target; make sure rounding never costs readability.
        var step = 0
        while toned.contrast(with: text) < minimumContrast, step < 20 {
            toned = toned.mixed(with: text == .white ? .black : .white, amount: 0.15)
            step += 1
        }
        return toned
    }
}

/// The viewer's ambient glow (SPEC §16.8.1): the photo's own colours, each kept dark enough that white text on any of them
/// keeps 7:1. Brighter parts of the photo glow a little brighter, so the light seems to come from the photo.
public enum AmbientField {
    static let floor = 0.012
    static let range = 0.03
    static let maximumSaturation = 0.6

    public static func tone(_ pixels: [PaletteColor]) -> [PaletteColor] {
        pixels.map { pixel in
            let target = floor + range * pixel.relativeLuminance
            let toned = pixel.withLuminance(target, saturation: min(pixel.hsl.saturation, maximumSaturation))
            return toned.contrast(with: .white) >= 7 ? toned : PhotoTintRole.ambient.tone(pixel)
        }
    }
}
