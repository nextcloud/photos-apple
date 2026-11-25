// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import PhotosDomain

/// A film style's look (`FilmLook`, SPEC §16.6) with Core Image: the colour grade of the pictures, and for a whole frame
/// the vignette, the grain, the jittering gate and the flickering light. The player grades its pictures with
/// `graded(_:look:)` once each and draws the rest itself from the same numbers; the video export runs `frame` for every
/// frame.
public enum FilmLookFilter {
    /// The colour grade (`FilmLook.colourMatrix`), applied to sRGB-encoded values as the look was designed.
    public static func graded(_ image: CIImage, look: FilmLook) -> CIImage {
        guard look.gradesColour else { return image }
        let m = look.colourMatrix
        let encode = CIFilter.linearToSRGBToneCurve()
        encode.inputImage = image
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = encode.outputImage
        matrix.rVector = CIVector(x: m[0][0], y: m[0][1], z: m[0][2], w: 0)
        matrix.gVector = CIVector(x: m[1][0], y: m[1][1], z: m[1][2], w: 0)
        matrix.bVector = CIVector(x: m[2][0], y: m[2][1], z: m[2][2], w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        matrix.biasVector = CIVector(x: m[0][3], y: m[1][3], z: m[2][3], w: 0)
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = matrix.outputImage
        let decode = CIFilter.sRGBToneCurveToLinear()
        decode.inputImage = clamp.outputImage
        return (decode.outputImage ?? image).cropped(to: image.extent)
    }

    /// A picture graded for the player (nil: the look does not change colours, or rendering failed).
    public static func graded(_ image: CGImage, look: FilmLook) -> CGImage? {
        guard look.gradesColour else { return nil }
        let input = CIImage(cgImage: image)
        let context = CIContext(options: [.cacheIntermediates: false])
        return context.createCGImage(
            graded(input, look: look), from: input.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    /// The whole-frame effects at `time` over a frame of `size` (origin bottom left): jitter, flicker, vignette, grain.
    public static func frame(_ image: CIImage, look: FilmLook, time: Double, size: CGSize) -> CIImage {
        let bounds = CGRect(origin: .zero, size: size)
        var result = image
        if look.jitter > 0 {
            let offset = look.jitterOffset(at: time)
            let scale = look.overscan
            let transform = CGAffineTransform(translationX: -size.width / 2, y: -size.height / 2)
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(
                    CGAffineTransform(translationX: size.width / 2 + offset.x * size.height, y: size.height / 2 - offset.y * size.height))
            result = result.transformed(by: transform)
        }
        let light = look.light(at: time)
        if light < 1 { result = FilmFrameRenderer.dimmed(result, light) }
        if look.vignette > 0 { result = vignette(look, size: size).composited(over: result) }
        if look.grain > 0 {
            let blend = CIFilter.softLightBlendMode()
            blend.inputImage = grain(look, time: time, size: size)
            blend.backgroundImage = result.cropped(to: bounds)
            result = blend.outputImage ?? result
        }
        return result.composited(over: CIImage(color: .black).cropped(to: bounds)).cropped(to: bounds)
    }

    /// Dark corners: clear in the middle, `FilmLook.vignetteOpacity` black at the corners.
    static func vignette(_ look: FilmLook, size: CGSize) -> CIImage {
        let radii = look.vignetteRadii(width: size.width, height: size.height)
        let gradient = CIFilter.radialGradient()
        gradient.center = CGPoint(x: size.width / 2, y: size.height / 2)
        gradient.radius0 = Float(radii.inner)
        gradient.radius1 = Float(radii.outer)
        gradient.color0 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        gradient.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: look.vignetteOpacity)
        return (gradient.outputImage ?? CIImage.empty()).cropped(to: CGRect(origin: .zero, size: size))
    }

    /// Mid-grey noise whose strength is the look's grain, moved for every film frame; soft-light blended (grey: no change).
    static func grain(_ look: FilmLook, time: Double, size: CGSize, pixel: CGFloat? = nil) -> CIImage {
        let grainPixel = pixel ?? FilmLook.grainSize(frameHeight: size.height)
        let offset = look.grainOffset(at: time)
        let noise = CIFilter.randomGenerator().outputImage ?? CIImage(color: .gray)
        let strength = CGFloat(look.grainStrength)
        let matrix = CIFilter.colorMatrix()
        // Monochrome noise from the red channel, pulled towards grey.
        matrix.inputImage = noise.transformed(by: CGAffineTransform(translationX: offset.x * 512, y: offset.y * 512))
            .transformed(by: CGAffineTransform(scaleX: grainPixel, y: grainPixel))
        matrix.rVector = CIVector(x: strength, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: strength, y: 0, z: 0, w: 0)
        matrix.bVector = CIVector(x: strength, y: 0, z: 0, w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        matrix.biasVector = CIVector(x: 0.5 - strength / 2, y: 0.5 - strength / 2, z: 0.5 - strength / 2, w: 1)
        return (matrix.outputImage ?? CIImage(color: .gray)).cropped(to: CGRect(origin: .zero, size: size))
    }

    /// A tile of the same grain for the player (drawn repeated, soft-light blended, moved with `grainOffset`).
    public static func grainTile(_ look: FilmLook, side: Int = 256) -> CGImage? {
        guard look.grain > 0 else { return nil }
        let size = CGSize(width: side, height: side)
        let context = CIContext(options: [.cacheIntermediates: false])
        return context.createCGImage(
            grain(look, time: 0, size: size, pixel: 1), from: CGRect(origin: .zero, size: size), format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
}

extension FilmLook {
    /// The vignette's clear middle and its darkest edge, from the frame's centre (pixels).
    public func vignetteRadii(width: Double, height: Double) -> (inner: Double, outer: Double) {
        let half = hypot(width, height) / 2
        return (half * 0.45, half * 1.05)
    }

    /// How dark the corners get.
    public var vignetteOpacity: Double { min(1, vignette * 0.85) }

    /// How far the grain's noise is pulled away from mid grey.
    public var grainStrength: Double { min(1, grain * 0.55) }

    /// Grain is this many pixels big in a 1080p video (Super 8 is coarse).
    public static let grainScale: CGFloat = 2

    /// How big a grain is in a frame of this height (points or pixels): the same share of the frame as in the video.
    public static func grainSize(frameHeight: Double) -> Double { max(0.5, frameHeight / 540) }
}

#if canImport(AVFoundation)
    import AVFoundation

    extension FilmLookFilter {
        /// The style's colours on a clip playing in the film (videos, Live Photo motion); nil when the look keeps them.
        public static func videoComposition(for asset: AVAsset, look: FilmLook) async -> AVVideoComposition? {
            guard look.gradesColour else { return nil }
            return try? await AVVideoComposition.videoComposition(with: asset) { (request: AVAsynchronousCIImageFilteringRequest) in
                request.finish(with: graded(request.sourceImage, look: look), context: nil)
            }
        }
    }
#endif
