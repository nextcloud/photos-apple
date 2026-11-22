// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation

/// Decodes BlurHash strings (https://blurha.sh, algorithm description) into small images.
public enum BlurHash {
    private static let characters = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~")
    private static let lookup: [Character: Int] = {
        var map: [Character: Int] = [:]
        for (index, character) in characters.enumerated() { map[character] = index }
        return map
    }()

    static func decode83(_ string: Substring) -> Int? {
        var value = 0
        for character in string {
            guard let digit = lookup[character] else { return nil }
            value = value * 83 + digit
        }
        return value
    }

    static func sRGBToLinear(_ value: Int) -> Double {
        let v = Double(value) / 255
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    static func linearToSRGB(_ value: Double) -> UInt8 {
        let v = max(0, min(1, value))
        let s = v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
        return UInt8(max(0, min(255, (s * 255 + 0.5).rounded(.down))))
    }

    static func signPow(_ value: Double, _ exponent: Double) -> Double {
        copysign(pow(abs(value), exponent), value)
    }

    /// Decodes into an RGB image of `width × height` pixels (32×32 is plenty for a placeholder).
    public static func decode(_ hash: String, width: Int = 32, height: Int = 32, punch: Double = 1) -> CGImage? {
        guard hash.count >= 6 else { return nil }
        let chars = Array(hash)
        guard let sizeFlag = decode83(hash.prefix(1)) else { return nil }
        let numY = sizeFlag / 9 + 1
        let numX = sizeFlag % 9 + 1
        guard hash.count == 4 + 2 * numX * numY, let quantisedMax = decode83(Substring(String(chars[1]))) else { return nil }
        let maxValue = Double(quantisedMax + 1) / 166

        var colors: [(Double, Double, Double)] = []
        for index in 0..<(numX * numY) {
            if index == 0 {
                guard let value = decode83(Substring(String(chars[2..<6]))) else { return nil }
                colors.append((sRGBToLinear(value >> 16), sRGBToLinear((value >> 8) & 255), sRGBToLinear(value & 255)))
            } else {
                let start = 4 + index * 2
                guard let value = decode83(Substring(String(chars[start..<start + 2]))) else { return nil }
                let r = value / (19 * 19)
                let g = (value / 19) % 19
                let b = value % 19
                colors.append(
                    (
                        signPow((Double(r) - 9) / 9, 2) * maxValue * punch,
                        signPow((Double(g) - 9) / 9, 2) * maxValue * punch,
                        signPow((Double(b) - 9) / 9, 2) * maxValue * punch
                    ))
            }
        }

        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var r = 0.0
                var g = 0.0
                var b = 0.0
                for j in 0..<numY {
                    for i in 0..<numX {
                        let basis =
                            cos(Double.pi * Double(x) * Double(i) / Double(width)) * cos(Double.pi * Double(y) * Double(j) / Double(height))
                        let color = colors[i + j * numX]
                        r += color.0 * basis
                        g += color.1 * basis
                        b += color.2 * basis
                    }
                }
                let offset = (y * width + x) * 4
                pixels[offset] = linearToSRGB(r)
                pixels[offset + 1] = linearToSRGB(g)
                pixels[offset + 2] = linearToSRGB(b)
            }
        }
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
