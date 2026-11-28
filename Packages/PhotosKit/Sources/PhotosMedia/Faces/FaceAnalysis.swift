// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import CoreImage
import Foundation
import PhotosDomain
import PhotosModel
import PhotosStore
import Vision

/// Finds faces in a picture with Apple's Vision framework, on this device (SPEC §22.3): face rectangles, Vision's face
/// capture quality, and a feature print of each face's crop, turned upright (the face's roll taken out) and widened to
/// head and shoulders. No model of the app's own: Vision's general feature print describes the crop, `FaceClustering`
/// compares what is particular to it. Measured on the Mac: about 25 ms per 1024-pixel photo.
public enum FaceAnalysis {
    /// The crop around a face: this many times the face's box, centred on it (1.8: hair, ears and collar too; that
    /// separated people best on the test library, docs/STATUS.md §22.3).
    public static let cropScale = 1.8
    /// The crop's side in pixels (Vision scales its input down to a few hundred pixels anyway).
    public static let cropSide = 160
    /// The cached tile looked at first: most photos show nobody, and that is known from the small tile.
    public static let detectionBucket = 256
    /// The preview faces are analysed on.
    public static let analysisBucket = 1024

    /// Faces in `image`: their boxes, quality, size and, for the usable ones, their prints.
    public static func analyze(_ image: CGImage) async throws -> [DeviceFaceStore.FoundFace] {
        #if targetEnvironment(simulator)
            // Vision's models do not run in the simulator (they fail or return the same answer for every picture).
            throw SimulatorUnsupported()
        #else
            let rectangles = try await DetectFaceRectanglesRequest().perform(on: image)
            guard !rectangles.isEmpty else { return [] }
            var quality = DetectFaceCaptureQualityRequest()
            quality.inputFaceObservations = rectangles
            let faces = (try? await quality.perform(on: image)) ?? rectangles
            var result: [DeviceFaceStore.FoundFace] = []
            for face in faces {
                let rect = face.boundingBox.cgRect
                let side = Double(rect.width) * Double(image.width)
                let score = face.captureQuality?.score
                var print: [Float]?
                if FaceClustering.isUsable(quality: score, sideInPixels: side),
                    let crop = alignedCrop(image, box: rect, roll: face.roll.converted(to: .radians).value)
                {
                    let observation = try await GenerateImageFeaturePrintRequest().perform(on: crop)
                    let values: [Float] = observation.data.withUnsafeBytes { raw in
                        guard observation.elementType == .float else { return [] }
                        return Array(raw.bindMemory(to: Float.self))
                    }
                    if !values.isEmpty { print = FaceClustering.normalized(values) }
                }
                result.append(
                    DeviceFaceStore.FoundFace(box: topLeft(rect), quality: score, side: side, print: print))
            }
            return result
        #endif
    }

    /// Whether `image` shows a face at all (the small tile: no print, no quality).
    public static func hasFaces(_ image: CGImage) async throws -> Bool {
        #if targetEnvironment(simulator)
            throw SimulatorUnsupported()
        #else
            return !(try await DetectFaceRectanglesRequest().perform(on: image)).isEmpty
        #endif
    }

    /// Vision's normalized rectangle (origin bottom left) as a box with its origin top left, like Recognize's.
    static func topLeft(_ rect: CGRect) -> FaceBox {
        FaceBox(x: Double(rect.minX), y: Double(1 - rect.maxY), width: Double(rect.width), height: Double(rect.height))
    }

    static let context = CIContext(options: [.cacheIntermediates: false])

    /// The square crop around a face, turned so the eyes are level, `cropSide` pixels wide.
    static func alignedCrop(_ image: CGImage, box: CGRect, roll: Double) -> CGImage? {
        let width = Double(image.width)
        let height = Double(image.height)
        let centreX = Double(box.midX) * width
        let centreY = Double(box.midY) * height
        let side = max(Double(box.width) * width, Double(box.height) * height) * cropScale
        guard side >= 1 else { return nil }
        let turn = CGAffineTransform(translationX: -centreX, y: -centreY)
            .concatenating(CGAffineTransform(rotationAngle: -roll))
            .concatenating(CGAffineTransform(translationX: side / 2, y: side / 2))
        let scale = Double(cropSide) / side
        let picture = CIImage(cgImage: image)
            .clampedToExtent()
            .transformed(by: turn)
            .cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(picture, from: CGRect(x: 0, y: 0, width: cropSide, height: cropSide))
    }

    struct SimulatorUnsupported: Error {}
}
