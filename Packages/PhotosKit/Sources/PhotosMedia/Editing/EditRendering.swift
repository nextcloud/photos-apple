// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Renders edit recipes (SPEC §16.3): on previews for the grid and the viewer, on the original for the editor and for
/// export, and RAW files developed with Core Image's RAW decoder.
public enum EditRendering {
    // MARK: RAW

    /// The file is a camera RAW (DNG, CR3, NEF, ARW…), by its name.
    public static func isRAW(name: String) -> Bool {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .rawImage)
    }

    /// What the RAW decoder offers for a file: the camera's white balance and which settings the camera supports.
    public struct RAWInfo: Sendable, Equatable {
        public var temperature: Double
        public var tint: Double
        public var supportsHighlightRecovery: Bool
        public var supportsNoiseReduction: Bool
        public var nativeSize: CGSize
        public var supportsColorNoiseReduction = false
        public var supportsDetail = false
    }

    public static func rawInfo(_ url: URL) -> RAWInfo? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        return RAWInfo(
            temperature: Double(filter.neutralTemperature), tint: Double(filter.neutralTint),
            supportsHighlightRecovery: filter.isHighlightRecoverySupported,
            supportsNoiseReduction: filter.isLuminanceNoiseReductionSupported, nativeSize: filter.nativeSize,
            supportsColorNoiseReduction: filter.isColorNoiseReductionSupported, supportsDetail: filter.isDetailSupported)
    }

    /// Develops a RAW file with the recipe's RAW settings, no larger than `maxPixelSize` (long edge) when given.
    public static func developRAW(_ url: URL, raw: RAWAdjustments?, maxPixelSize: Int? = nil, draft: Bool = false) -> CIImage? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        let native = max(filter.nativeSize.width, filter.nativeSize.height)
        if let maxPixelSize, native > 0 { filter.scaleFactor = Float(min(1, CGFloat(maxPixelSize) / native)) }
        filter.isDraftModeEnabled = draft
        if let raw { configure(filter, raw) }
        return filter.outputImage
    }

    public static func configure(_ filter: CIRAWFilter, _ raw: RAWAdjustments) {
        filter.exposure = Float(raw.exposure)
        if let temperature = raw.temperature { filter.neutralTemperature = Float(temperature) }
        if let tint = raw.tint { filter.neutralTint = Float(tint) }
        if filter.isHighlightRecoverySupported { filter.isHighlightRecoveryEnabled = raw.highlightRecovery }
        if raw.shadowBoost > 0 { filter.boostShadowAmount = Float(min(1, max(0, raw.shadowBoost))) }
        if let noise = raw.noiseReduction, filter.isLuminanceNoiseReductionSupported {
            filter.luminanceNoiseReductionAmount = Float(min(1, max(0, noise)))
        }
        if let noise = raw.colorNoiseReduction, filter.isColorNoiseReductionSupported {
            filter.colorNoiseReductionAmount = Float(min(1, max(0, noise)))
        }
        if let detail = raw.detail, filter.isDetailSupported { filter.detailAmount = Float(min(1, max(0, detail))) }
    }

    /// The camera's white balance a preview approximation assumes when it does not know the file's own.
    public static let assumedAsShotTemperature = 5500.0

    /// RAW settings approximated on a picture that is developed already (the server's preview of the RAW, or the JPEG
    /// the camera wrote beside it): what the grid shows until the RAW itself is decoded.
    public static func approximate(_ raw: RAWAdjustments, on input: CIImage, asShotTemperature: Double? = nil) -> CIImage {
        var image = input
        if raw.exposure != 0 {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = image
            filter.ev = Float(raw.exposure)
            image = filter.outputImage ?? image
        }
        if raw.temperature != nil || raw.tint != nil {
            // A higher temperature renders warmer, as the RAW decoder (and every RAW developer) does.
            let shot = asShotTemperature ?? assumedAsShotTemperature
            let filter = CIFilter.temperatureAndTint()
            filter.inputImage = image
            filter.neutral = CIVector(x: 6500, y: 0)
            filter.targetNeutral = CIVector(x: 6500 - ((raw.temperature ?? shot) - shot), y: raw.tint ?? 0)
            image = filter.outputImage ?? image
        }
        if raw.highlightRecovery || raw.shadowBoost > 0 {
            let filter = CIFilter.highlightShadowAdjust()
            filter.inputImage = image
            filter.highlightAmount = raw.highlightRecovery ? 0.75 : 1
            filter.shadowAmount = Float(min(1, max(0, raw.shadowBoost)) * 0.6)
            image = filter.outputImage ?? image
        }
        if let noise = raw.noiseReduction, noise > 0 {
            let filter = CIFilter.noiseReduction()
            filter.inputImage = image
            filter.noiseLevel = Float(noise * 0.04)
            filter.sharpness = 0.4
            image = filter.outputImage ?? image
        }
        if let noise = raw.colorNoiseReduction, noise > 0 { image = NoiseReduction.apply(luminance: 0, color: noise, to: image) }
        return image
    }

    // MARK: Recipes

    /// The recipe on a picture of any size. `developed`: the RAW settings were applied while decoding (the picture is
    /// the RAW itself); otherwise they are approximated.
    ///
    /// The order (docs/EDIT-FORMAT.md): RAW settings, removed objects (`retouch`), colour and tone (`PhotoEditor.applyColor`: noise, adjustments, curves,
    /// colour mixer, masks, filter, sharpness, vignette), then straighten, turns, mirror and crop.
    /// - Parameter crops: false for the crop tool, which shows the whole picture with the crop's frame over it.
    public static func apply(_ recipe: EditRecipe, to input: CIImage, developed: Bool = false, crops: Bool = true) -> CIImage {
        var image = input
        if let raw = recipe.raw, !raw.isIdentity, !developed { image = approximate(raw, on: image) }
        // Removed objects (SPEC §21.5) before colour: the fill sees the photo's own pixels, and changing colours later never
        // fills again (the filled areas are cached by the picture they were made from).
        image = Inpainting.apply(recipe.retouch, to: image)
        image = PhotoEditor.applyColor(recipe.edits, to: image)
        var geometry = recipe.edits
        if !crops {
            geometry.crop = nil
            geometry.aspect = .free
        }
        return PhotoEditor.applyGeometry(geometry, to: image)
    }

    /// The edited version of a preview, no larger than `maxPixelSize`: what the grid and the viewer show.
    public static func rendition(of base: CGImage, recipe: EditRecipe, maxPixelSize: Int) -> CGImage? {
        let input = CIImage(cgImage: base)
        let output = apply(recipe, to: input)
        let longEdge = max(output.extent.width, output.extent.height)
        let scale = longEdge > CGFloat(maxPixelSize) && longEdge > 0 ? CGFloat(maxPixelSize) / longEdge : 1
        let scaled = scale < 1 ? output.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : output
        let extent = scaled.extent.integral
        return PhotoEditor.context.createCGImage(scaled, from: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    /// The original with its orientation applied, a RAW developed with `raw` (`developed` tells which it was).
    public static func loadOriginal(_ url: URL, name: String, raw: RAWAdjustments?, maxPixelSize: Int? = nil) -> (
        image: CIImage, developed: Bool
    )? {
        if isRAW(name: name), let developed = developRAW(url, raw: raw ?? RAWAdjustments(), maxPixelSize: maxPixelSize) {
            return (developed, true)
        }
        guard var image = PhotoEditor.load(url) else { return nil }
        if let maxPixelSize {
            let scale = min(1, CGFloat(maxPixelSize) / max(image.extent.width, image.extent.height, 1))
            if scale < 1 { image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        }
        return (image, false)
    }

    /// Renders the recipe on the original at full resolution and writes it next to `destinationDirectory`, keeping the
    /// original's metadata (export, share, "Save as copy"): `<name> (edited)` as HEIC for HEIC originals, else JPEG.
    /// - Parameter still: the still of a Live Photo effect (long exposure, another key photo) instead of the original.
    public static func renderFile(
        _ recipe: EditRecipe, original: URL, name: String, still: CGImage? = nil, replacingOriginal: Bool = false,
        to destinationDirectory: URL
    ) throws -> URL {
        let output: CIImage
        if let still {
            output = apply(recipe, to: CIImage(cgImage: still))
        } else {
            guard let loaded = loadOriginal(original, name: name, raw: recipe.raw) else { throw CocoaError(.fileReadCorruptFile) }
            output = apply(recipe, to: loaded.image, developed: loaded.developed)
        }
        return try PhotoEditor.write(
            output, metadataFrom: original, name: name, replacingOriginal: replacingOriginal, to: destinationDirectory)
    }
}
