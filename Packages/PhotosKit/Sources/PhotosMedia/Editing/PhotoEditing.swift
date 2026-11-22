// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Non-destructive edit parameters (SPEC §7.16.1).
public struct PhotoEdits: Hashable, Sendable {
    public enum Aspect: String, CaseIterable, Sendable {
        case original, square, fourThree = "4:3", sixteenNine = "16:9", threeTwo = "3:2"

        var ratio: Double? {
            switch self {
            case .original: nil
            case .square: 1
            case .fourThree: 4 / 3
            case .sixteenNine: 16 / 9
            case .threeTwo: 3 / 2
            }
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
    public var flipped = false
    public var aspect: Aspect = .original
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

    public var isIdentity: Bool { self == PhotoEdits() }
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
        if edits.flipped { image = image.transformed(by: CGAffineTransform(scaleX: -1, y: 1)) }
        if edits.rotation % 4 != 0 {
            image = image.transformed(by: CGAffineTransform(rotationAngle: -CGFloat(edits.rotation % 4) * .pi / 2))
        }
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        if let ratio = edits.aspect.ratio {
            let current = image.extent.width / image.extent.height
            let target = image.extent.width >= image.extent.height ? ratio : 1 / ratio
            var rect = image.extent
            if current > target {
                rect.size.width = rect.height * target
                rect.origin.x = (image.extent.width - rect.width) / 2
            } else {
                rect.size.height = rect.width / target
                rect.origin.y = (image.extent.height - rect.height) / 2
            }
            image = image.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        }
        return image
    }

    /// Loads an image file with its orientation applied.
    public static func load(_ url: URL) -> CIImage? {
        CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
    }

    /// Renders and writes the edited image as HEIC (when the original was HEIC/HEIF) or JPEG, keeping EXIF, GPS and dates.
    public static func render(_ edits: PhotoEdits, original: URL, to destinationDirectory: URL) throws -> URL {
        guard let input = load(original) else { throw CocoaError(.fileReadCorruptFile) }
        let output = apply(edits, to: input)
        guard let cgImage = context.createCGImage(output, from: output.extent) else { throw CocoaError(.fileWriteUnknown) }
        let isHEIF = ["heic", "heif"].contains(original.pathExtension.lowercased())
        let type = isHEIF ? UTType.heic : UTType.jpeg
        let base = (original.lastPathComponent as NSString).deletingPathExtension
        let target = destinationDirectory.appending(path: "\(base) (edited).\(isHEIF ? "heic" : "jpg")")
        try? FileManager.default.removeItem(at: target)
        var properties: [CFString: Any] = [:]
        if let source = CGImageSourceCreateWithURL(original as CFURL, nil),
            let original = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        {
            properties = original
        }
        properties[kCGImagePropertyOrientation] = 1
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
