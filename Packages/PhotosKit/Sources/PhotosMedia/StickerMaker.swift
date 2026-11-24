// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import PhotosDomain
import UniformTypeIdentifiers
import Vision

/// How a sticker looks (SPEC §15.8.2).
public enum StickerStyle: String, CaseIterable, Sendable, Codable {
    /// Only the subject.
    case original
    /// A white border and a faint shadow, like a printed sticker.
    case outline
    /// A soft drop shadow.
    case shadow
    /// Drawn like a comic, with a white border.
    case comic
}

/// Makes stickers on the device: lifts the subjects of a photo with Vision's foreground instance mask, styles the cut-out
/// with Core Image and encodes it with transparency. Nothing leaves the device.
public enum StickerMaker {
    public enum Failure: Error, Equatable {
        /// Vision found no person, pet or object in front.
        case noSubject
        /// Segmentation is not available on this device (the simulator, an old Mac).
        case unavailable
    }

    /// Long edge of a sticker in pixels (the cut-out is scaled down to it; small ones stay as they are).
    public static let maxSize = 1024

    /// Cuts out the subjects of `image` with a transparent background, cropped to them.
    ///
    /// - Parameter face: with a face (unit coordinates, origin top left) only the subject that holds it is lifted; that is
    ///   how a person's sticker pack leaves out the people standing next to them.
    /// Synchronous and slow (a few hundred milliseconds): call it off the main thread.
    public static func lift(_ image: CGImage, face: CGRect? = nil) throws -> CGImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw Failure.unavailable
        }
        guard let observation = request.results?.first else { throw Failure.noSubject }
        let subjects = Self.subjects(of: observation)
        let chosen = StickerSubjects.choose(subjects, face: face)
        guard !chosen.isEmpty else { throw Failure.noSubject }
        let buffer = try observation.generateMaskedImage(
            ofInstances: IndexSet(chosen), from: handler, croppedToInstancesExtent: true)
        let cutout = CIImage(cvPixelBuffer: buffer)
        guard let result = context.createCGImage(cutout, from: cutout.extent, format: .RGBA8, colorSpace: sRGB) else {
            throw Failure.noSubject
        }
        return result
    }

    /// Bounding box and share of the picture of every instance, read from the low-resolution label mask.
    static func subjects(of observation: VNInstanceMaskObservation) -> [StickerSubject] {
        let mask = observation.instanceMask
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return [] }
        let width = CVPixelBufferGetWidth(mask)
        let height = CVPixelBufferGetHeight(mask)
        let stride = CVPixelBufferGetBytesPerRow(mask)
        var boxes: [Int: (minX: Int, minY: Int, maxX: Int, maxY: Int, count: Int)] = [:]
        for y in 0..<height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let label = Int(row[x])
                guard label > 0 else { continue }
                if var box = boxes[label] {
                    box.minX = min(box.minX, x)
                    box.maxX = max(box.maxX, x)
                    box.minY = min(box.minY, y)
                    box.maxY = max(box.maxY, y)
                    box.count += 1
                    boxes[label] = box
                } else {
                    boxes[label] = (x, y, x, y, 1)
                }
            }
        }
        let total = Double(max(1, width * height))
        return observation.allInstances.compactMap { instance in
            guard let box = boxes[instance] else { return nil }
            let rect = CGRect(
                x: Double(box.minX) / Double(width), y: Double(box.minY) / Double(height),
                width: Double(box.maxX - box.minX + 1) / Double(width), height: Double(box.maxY - box.minY + 1) / Double(height))
            return StickerSubject(instance: instance, box: rect, coverage: Double(box.count) / total)
        }
    }

    // MARK: Styles

    static let context = CIContext(options: [.cacheIntermediates: false])
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// The cut-out in a style: scaled to `maxSize`, with room around it for the border and shadow, cropped to what is drawn.
    public static func styled(_ cutout: CGImage, style: StickerStyle) -> CGImage? {
        var subject = CIImage(cgImage: cutout)
        let long = max(subject.extent.width, subject.extent.height)
        if long > CGFloat(maxSize) {
            let scale = CGFloat(maxSize) / long
            subject = subject.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        subject = subject.transformed(by: CGAffineTransform(translationX: -subject.extent.minX, y: -subject.extent.minY))
        let side = max(subject.extent.width, subject.extent.height)
        let border = max(3, (side * 0.03).rounded())
        let clear = CIImage(color: .clear)
        var output: CIImage
        switch style {
        case .original:
            output = subject
        case .outline:
            output = subject.composited(over: whiteBorder(of: subject, radius: border))
            output = output.composited(over: shadow(of: output, radius: border * 0.8, offset: border * 0.4, opacity: 0.25))
        case .shadow:
            output = subject.composited(over: shadow(of: subject, radius: border * 1.6, offset: border, opacity: 0.45))
        case .comic:
            let drawn = subject.applyingFilter("CIComicEffect").cropped(to: subject.extent)
            let masked = drawn.applyingFilter(
                "CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: subject])
            output = masked.composited(over: whiteBorder(of: subject, radius: border * 1.3))
        }
        // Everything that is drawn, plus a margin, and no more.
        let extent =
            output.extent.isInfinite ? subject.extent : output.extent.intersection(subject.extent.insetBy(dx: -border * 4, dy: -border * 4))
        let canvas = extent.integral
        return context.createCGImage(output.cropped(to: canvas), from: canvas, format: .RGBA8, colorSpace: sRGB)
    }

    /// A white shape like the subject, `radius` larger all around.
    static func whiteBorder(of subject: CIImage, radius: CGFloat) -> CIImage {
        subject
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: radius])
            .applyingGaussianBlur(sigma: 0.6)
            .applyingFilter(
                "CIColorMatrix",
                parameters: [
                    "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                    "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 0),
                ])
    }

    /// A blurred dark copy of the shape, moved down.
    static func shadow(of shape: CIImage, radius: CGFloat, offset: CGFloat, opacity: CGFloat) -> CIImage {
        shape
            .applyingFilter(
                "CIColorMatrix",
                parameters: [
                    "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity),
                    "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                ]
            )
            .applyingGaussianBlur(sigma: radius)
            .transformed(by: CGAffineTransform(translationX: 0, y: -offset))
    }

    // MARK: Encoding

    /// PNG with transparency (what share sheets and the pasteboard take everywhere).
    public static func pngData(_ image: CGImage) -> Data? { encode(image, type: .png) }

    /// HEIC with transparency (smaller; Messages and Photos read it).
    public static func heicData(_ image: CGImage) -> Data? { encode(image, type: .heic) }

    static func encode(_ image: CGImage, type: UTType) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

/// Finds the part of a photo that a collage cell must keep in view (SPEC §15.8.3): faces when there are any, else what
/// draws the eye (Vision's attention-based saliency). On the device, from a preview.
public enum FocusFinder {
    /// In the picture's unit coordinates, origin top left; the whole picture when nothing stands out.
    public static func focus(in image: CGImage) -> CGRect {
        let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
        let faces = VNDetectFaceRectanglesRequest()
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([faces, saliency])) != nil else { return whole }
        let faceBoxes = (faces.results ?? []).map(\.boundingBox)
        if let union = faceBoxes.dropFirst().reduce(faceBoxes.first, { $0?.union($1) }) {
            // A little room above and around the faces: hair and shoulders.
            return topLeft(union.insetBy(dx: -union.width * 0.3, dy: -union.height * 0.4)).intersection(whole)
        }
        let salient = (saliency.results?.first?.salientObjects ?? []).map(\.boundingBox)
        if let union = salient.dropFirst().reduce(salient.first, { $0?.union($1) }) {
            return topLeft(union).intersection(whole)
        }
        return whole
    }

    /// Vision's normalised rectangles have their origin at the bottom left.
    static func topLeft(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
    }
}
