// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Noise reduction of developed pictures (JPEG, HEIC, the preview of a RAW) (SPEC §21.6.4). A RAW file is denoised
/// better while it is decoded (`RAWAdjustments.noiseReduction`, `.colorNoiseReduction`); this is for everything else.
///
/// Both strengths are relative to the picture's size, so a tile, the editor's proxy and the full-resolution export look
/// alike: the radius of the colour smoothing is a fraction of the long edge.
public enum NoiseReduction {
    /// Radius of the colour smoothing at full strength, as a fraction of the picture's long edge (≈ 10 px on 4000 px).
    static let colorRadius = 0.0025

    /// - Parameters:
    ///   - luminance: 0 … 1; grain in brightness, with Core Image's edge-aware `CINoiseReduction`.
    ///   - color: 0 … 1; blotches of colour: the picture's colours are blurred and put back under its own luminance
    ///     (`CIColorBlendMode`), so detail stays sharp.
    public static func apply(luminance: Double, color: Double, to input: CIImage) -> CIImage {
        var image = input
        let extent = input.extent
        let longEdge = max(extent.width, extent.height)
        guard longEdge.isFinite, longEdge > 0 else { return input }
        if color > 0 {
            let radius = Float(min(1, color) * colorRadius * longEdge)
            if radius >= 0.5 {
                let blur = CIFilter.gaussianBlur()
                blur.inputImage = image.clampedToExtent()
                blur.radius = radius
                if let blurred = blur.outputImage?.cropped(to: extent) {
                    let blend = CIFilter.colorBlendMode()
                    blend.inputImage = blurred
                    blend.backgroundImage = image
                    image = blend.outputImage?.cropped(to: extent) ?? image
                }
            }
        }
        if luminance > 0 {
            let filter = CIFilter.noiseReduction()
            filter.inputImage = image
            // The filter's noise level is in absolute values: 0.06 removes heavy grain, more smears.
            filter.noiseLevel = Float(min(1, luminance) * 0.06)
            filter.sharpness = Float(0.6 - min(1, luminance) * 0.3)
            image = filter.outputImage?.cropped(to: extent) ?? image
        }
        return image
    }
}
