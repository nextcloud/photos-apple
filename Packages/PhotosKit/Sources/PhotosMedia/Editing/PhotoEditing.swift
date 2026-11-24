// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Non-destructive edit parameters (SPEC §7.16.1).
public struct PhotoEdits: Hashable, Sendable {
    /// Crop presets. `free` and `original` do not fix a ratio of their own: a free crop has none, "Original" the photo's.
    public enum Aspect: String, CaseIterable, Sendable {
        case free, original, square, fourThree = "4:3", sixteenNine = "16:9", threeTwo = "3:2"

        var ratio: Double? {
            switch self {
            case .free, .original: nil
            case .square: 1
            case .fourThree: 4 / 3
            case .sixteenNine: 16 / 9
            case .threeTwo: 3 / 2
            }
        }

        /// The pixel aspect (width over height) of this preset on a picture of `size`: the ratios follow the picture's
        /// orientation (4:3 on a landscape photo, 3:4 on a portrait one); nil for a free crop.
        public func pixelAspect(for size: CGSize) -> Double? {
            guard size.width > 0, size.height > 0 else { return nil }
            if self == .original { return Double(size.width / size.height) }
            guard let ratio else { return nil }
            return size.width >= size.height ? ratio : 1 / ratio
        }
    }

    public enum Filter: String, CaseIterable, Sendable {
        case none, vivid, vividWarm, vividCool, dramatic, mono, silvertone, noir

        var name: String? {
            switch self {
            case .none: nil
            case .vivid: "CIPhotoEffectChrome"
            case .vividWarm: "CIPhotoEffectTransfer"
            case .vividCool: "CIPhotoEffectProcess"
            case .dramatic: "CIPhotoEffectFade"
            case .mono: "CIPhotoEffectMono"
            case .silvertone: "CIPhotoEffectTonal"
            case .noir: "CIPhotoEffectNoir"
            }
        }
    }

    /// Quarter turns clockwise.
    public var rotation = 0
    public var straighten: Double = 0
    /// Mirrored left to right as the picture is shown (after the quarter turns).
    public var flipped = false
    /// The crop preset; without a `crop` of its own the largest area of its ratio in the middle is kept.
    public var aspect: Aspect = .original
    /// The free-form crop (drag handles); nil for the whole picture or the preset's area.
    public var crop: CropRect?
    /// Resizing the crop keeps its aspect (the lock in the crop tool; presets turn it on).
    public var aspectLocked = false
    public var autoEnhance = false
    public var filter: Filter = .none
    public var exposure: Double = 0
    public var contrast: Double = 1
    public var brightness: Double = 0
    public var highlights: Double = 1
    public var shadows: Double = 0
    public var saturation: Double = 1
    public var vibrance: Double = 0
    public var warmth: Double = 0
    public var tint: Double = 0
    public var sharpness: Double = 0
    public var vignette: Double = 0

    public init() {}

    public var isIdentity: Bool {
        var normalized = self
        // A lock alone or a crop of the whole picture changes nothing in the photo.
        normalized.aspectLocked = false
        if normalized.crop?.isFull == true { normalized.crop = nil }
        if normalized.aspect == .free && normalized.crop == nil { normalized.aspect = .original }
        return normalized == PhotoEdits()
    }

    /// Turns the picture a quarter as the user sees it; the crop turns with it.
    public mutating func rotate(clockwise: Bool) {
        // The mirror is applied after the turns: on a mirrored picture a turn to the right is a turn to the left underneath.
        let step = clockwise != flipped ? 1 : 3
        rotation = (rotation + step) % 4
        crop = crop.map { clockwise ? $0.rotatedClockwise() : $0.rotatedCounterclockwise() }
    }

    /// Mirrors the picture left to right as the user sees it; the crop is mirrored with it.
    public mutating func flip() {
        flipped.toggle()
        crop = crop?.flippedHorizontally()
    }
}

/// Applies edits with Core Image and writes the result keeping the original's metadata.
public enum PhotoEditor {
    public static let context = CIContext(options: [.useSoftwareRenderer: false])

    public static func apply(_ edits: PhotoEdits, to input: CIImage) -> CIImage {
        var image = input
        if edits.autoEnhance {
            for filter in image.autoAdjustmentFilters() {
                filter.setValue(image, forKey: kCIInputImageKey)
                image = filter.outputImage ?? image
            }
        }
        if edits.exposure != 0 {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = image
            filter.ev = Float(edits.exposure)
            image = filter.outputImage ?? image
        }
        if edits.contrast != 1 || edits.brightness != 0 || edits.saturation != 1 {
            let filter = CIFilter.colorControls()
            filter.inputImage = image
            filter.contrast = Float(edits.contrast)
            filter.brightness = Float(edits.brightness)
            filter.saturation = Float(edits.saturation)
            image = filter.outputImage ?? image
        }
        if edits.highlights != 1 || edits.shadows != 0 {
            let filter = CIFilter.highlightShadowAdjust()
            filter.inputImage = image
            filter.highlightAmount = Float(edits.highlights)
            filter.shadowAmount = Float(edits.shadows)
            image = filter.outputImage ?? image
        }
        if edits.vibrance != 0 {
            let filter = CIFilter.vibrance()
            filter.inputImage = image
            filter.amount = Float(edits.vibrance)
            image = filter.outputImage ?? image
        }
        if edits.warmth != 0 || edits.tint != 0 {
            let filter = CIFilter.temperatureAndTint()
            filter.inputImage = image
            filter.neutral = CIVector(x: 6500, y: 0)
            filter.targetNeutral = CIVector(x: 6500 - edits.warmth * 2000, y: edits.tint * 50)
            image = filter.outputImage ?? image
        }
        if let name = edits.filter.name, let filter = CIFilter(name: name) {
            filter.setValue(image, forKey: kCIInputImageKey)
            image = filter.outputImage ?? image
        }
        if edits.sharpness > 0 {
            let filter = CIFilter.sharpenLuminance()
            filter.inputImage = image
            filter.sharpness = Float(edits.sharpness)
            image = filter.outputImage ?? image
        }
        if edits.vignette > 0 {
            let filter = CIFilter.vignette()
            filter.inputImage = image
            filter.intensity = Float(edits.vignette)
            filter.radius = 2
            image = filter.outputImage ?? image
        }
        // Geometry
        let extent = image.extent
        if edits.straighten != 0 {
            let angle = edits.straighten * .pi / 180
            let rotated = image.transformed(by: CGAffineTransform(rotationAngle: angle))
            // Crop to the largest axis-aligned rectangle inside the rotated image.
            let scale = 1 / (abs(cos(angle)) + abs(sin(angle)) * max(extent.width, extent.height) / min(extent.width, extent.height))
            let width = extent.width * scale
            let height = extent.height * scale
            image = rotated.cropped(
                to: CGRect(x: rotated.extent.midX - width / 2, y: rotated.extent.midY - height / 2, width: width, height: height))
        }
        if edits.rotation % 4 != 0 {
            image = image.transformed(by: CGAffineTransform(rotationAngle: -CGFloat(edits.rotation % 4) * .pi / 2))
        }
        // Mirrored after the turns, so "Flip" mirrors left to right as the picture is shown.
        if edits.flipped { image = image.transformed(by: CGAffineTransform(scaleX: -1, y: 1)) }
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        return crop(image, edits)
    }

    /// Everything but the crop: what the crop tool shows, with the crop's frame over it.
    public static func applyWithoutCrop(_ edits: PhotoEdits, to input: CIImage) -> CIImage {
        var uncropped = edits
        uncropped.crop = nil
        uncropped.aspect = .free
        return apply(uncropped, to: input)
    }

    /// The area `edits` keep of a picture of `size`: their own crop, else the preset's area in the middle; nil for all of it.
    public static func cropArea(_ edits: PhotoEdits, size: CGSize) -> CropRect? {
        if let crop = edits.crop { return crop.isFull ? nil : crop }
        guard edits.aspect != .original, let aspect = edits.aspect.pixelAspect(for: size) else { return nil }
        let area = CropRect.centered(aspect: aspect, in: size)
        return area.isFull ? nil : area
    }

    static func crop(_ image: CIImage, _ edits: PhotoEdits) -> CIImage {
        guard let area = cropArea(edits, size: image.extent.size) else { return image }
        let rect = area.rect(in: image.extent)
        return image.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
    }

    /// Loads an image file with its orientation applied.
    public static func load(_ url: URL) -> CIImage? {
        CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
    }

    /// Image types the edited photo can be written back in over the original ("Overwrite original", Rotate): what
    /// Image I/O can write. Other originals (RAW, GIF, WebP…) can only be saved as a copy.
    static let rewritableTypes: [UTType] = [.jpeg, .heic, .heif, .png, .tiff]

    /// The original can be replaced by an edited version in its own format.
    public static func canRewrite(fileName: String) -> Bool {
        guard let type = UTType(filenameExtension: (fileName as NSString).pathExtension) else { return false }
        return rewritableTypes.contains { type.conforms(to: $0) }
    }

    /// Renders and writes the edited image, keeping EXIF, GPS and dates.
    ///
    /// - Parameters:
    ///   - name: the photo's file name on the server (the original's local copy has a cache name).
    ///   - replacingOriginal: written in the original's own format under its own name, to replace it; otherwise as
    ///     `<name> (edited)` in HEIC (when the original was HEIC/HEIF) or JPEG, to be saved as a copy.
    public static func render(
        _ edits: PhotoEdits, original: URL, name: String, replacingOriginal: Bool = false, to destinationDirectory: URL
    ) throws -> URL {
        guard let input = load(original) else { throw CocoaError(.fileReadCorruptFile) }
        let output = apply(edits, to: input)
        guard let cgImage = context.createCGImage(output, from: output.extent) else { throw CocoaError(.fileWriteUnknown) }
        let ext = (name as NSString).pathExtension.lowercased()
        let base = (name as NSString).deletingPathExtension
        let type: UTType
        let target: URL
        if replacingOriginal {
            guard canRewrite(fileName: name), let own = UTType(filenameExtension: ext) else {
                throw CocoaError(.fileWriteUnsupportedScheme)
            }
            type = own.conforms(to: .heif) ? .heic : own
            target = destinationDirectory.appending(path: name)
        } else {
            let isHEIF = ["heic", "heif"].contains(ext)
            type = isHEIF ? .heic : .jpeg
            target = destinationDirectory.appending(path: "\(base) (edited).\(isHEIF ? "heic" : "jpg")")
        }
        try? FileManager.default.removeItem(at: target)
        var properties: [CFString: Any] = [:]
        if let source = CGImageSourceCreateWithURL(original as CFURL, nil),
            let original = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        {
            properties = original
        }
        // The pixels are turned upright now; the copies of the orientation and size inside TIFF and EXIF must agree.
        properties[kCGImagePropertyOrientation] = 1
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = cgImage.width
            exif[kCGImagePropertyExifPixelYDimension] = cgImage.height
            properties[kCGImagePropertyExifDictionary] = exif
        }
        properties[kCGImageDestinationLossyCompressionQuality] = 0.92
        properties[kCGImagePropertyPixelWidth] = cgImage.width
        properties[kCGImagePropertyPixelHeight] = cgImage.height
        guard let destination = CGImageDestinationCreateWithURL(target as CFURL, type.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return target
    }
}
