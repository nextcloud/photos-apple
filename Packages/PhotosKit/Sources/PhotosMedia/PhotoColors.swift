// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import PhotosDomain
import Synchronization

/// The dominant colour of a photo, without any extra network (SPEC §16.8.1): from its BlurHash (in the index already), or
/// else from a preview that is in memory anyway. A few dozen pixels are enough.
public enum PhotoColors {
    /// Side of the picture the colour is taken from.
    static let side = 8

    private static let cache = Mutex<[String: PaletteColor]>([:])
    static let cacheLimit = 4000

    /// From a BlurHash: decoded at 8×8 (pure arithmetic, no drawing). Cached by hash.
    public static func dominant(blurhash: String?) -> PaletteColor? {
        guard let blurhash, !blurhash.isEmpty else { return nil }
        if let cached = cache.withLock({ $0[blurhash] }) { return cached }
        guard let image = BlurHash.decode(blurhash, width: side, height: side), let color = PhotoPalette.dominant(pixels(ofDecoded: image))
        else { return nil }
        cache.withLock { cache in
            if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
            cache[blurhash] = color
        }
        return color
    }

    /// From any picture: scaled down to 8×8 by Core Graphics on the CPU.
    public static func dominant(image: CGImage) -> PaletteColor? {
        PhotoPalette.dominant(pixels(of: image))
    }

    /// The pixels of an image made by `BlurHash.decode` (8-bit RGBX, sRGB), read straight from its bytes.
    static func pixels(ofDecoded image: CGImage) -> [PaletteColor] {
        guard image.bitsPerPixel == 32, image.bitsPerComponent == 8, let data = image.dataProvider?.data,
            let bytes = CFDataGetBytePtr(data)
        else { return pixels(of: image) }
        let count = min(CFDataGetLength(data), image.bytesPerRow * image.height)
        var result: [PaletteColor] = []
        result.reserveCapacity(image.width * image.height)
        for y in 0..<image.height {
            for x in 0..<image.width {
                let offset = y * image.bytesPerRow + x * 4
                guard offset + 2 < count else { continue }
                result.append(PaletteColor(bytes: bytes[offset], bytes[offset + 1], bytes[offset + 2]))
            }
        }
        return result
    }

    /// Any image drawn into an 8×8 sRGB bitmap.
    static func pixels(of image: CGImage) -> [PaletteColor] {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return [] }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return [] }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        return (0..<(side * side)).map { index in
            PaletteColor(bytes: bytes[index * 4], bytes[index * 4 + 1], bytes[index * 4 + 2])
        }
    }
}

extension PhotoColors {
    /// The viewer's ambient glow from a BlurHash: 6×6 of the photo's colours toned dark (`AmbientField`), to be scaled up
    /// and blurred. Made from numbers only, no drawing.
    public static func ambientImage(blurhash: String?) -> CGImage? {
        guard let blurhash, !blurhash.isEmpty, let decoded = BlurHash.decode(blurhash, width: 6, height: 6) else { return nil }
        let toned = AmbientField.tone(pixels(ofDecoded: decoded))
        guard toned.count == 36 else { return nil }
        var bytes = [UInt8](repeating: 255, count: toned.count * 4)
        for (index, color) in toned.enumerated() {
            bytes[index * 4] = UInt8((color.red * 255).rounded())
            bytes[index * 4 + 1] = UInt8((color.green * 255).rounded())
            bytes[index * 4 + 2] = UInt8((color.blue * 255).rounded())
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }
        return CGImage(
            width: 6, height: 6, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 24, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil,
            shouldInterpolate: true, intent: .defaultIntent)
    }
}
