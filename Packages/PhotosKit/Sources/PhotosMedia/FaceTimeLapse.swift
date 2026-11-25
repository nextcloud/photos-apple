// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import PhotosDomain
import Vision

/// The faces of "through the years" (SPEC §16.6), found on the device: Vision's face landmarks give the pupils of the
/// person's face (the face Recognize marked, when there are several), and each photo is drawn turned and scaled so the
/// eyes sit on the same line in every frame.
public enum FaceTimeLapse {
    /// The eyes of the face nearest to `hint` (Recognize's box, 0…1 from the top left), else of the largest face; when
    /// Vision finds no landmarks there, the eyes are estimated from the box. Pixels, origin top left.
    public static func eyes(in image: CGImage, near hint: FilmCrop?) async -> ThroughTheYears.Eyes? {
        let size = CGSize(width: image.width, height: image.height)
        let faces = (try? await DetectFaceLandmarksRequest().perform(on: image)) ?? []
        let boxes = faces.map { face in
            let box = face.boundingBox
            return FilmCrop(x: box.origin.x, y: 1 - box.origin.y - box.height, width: box.width, height: box.height)
        }
        guard let index = bestFace(boxes, hint: hint) else {
            // Vision did not find Recognize's face: the box alone, when it is large enough to be a clear face.
            guard let hint, hint.width >= 0.08 else { return nil }
            return ThroughTheYears.Eyes.estimated(in: hint, imageWidth: size.width, imageHeight: size.height)
        }
        // A face turned away (in profile) cannot be lined up on its eyes: another photo of the period is taken.
        guard isFrontal(yaw: faces[index].yaw.converted(to: .degrees).value) else { return nil }
        if let landmarks = faces[index].landmarks, let eyes = pupils(landmarks, size: size) {
            // Eyes much closer together than the face is wide: a face in profile the yaw did not tell.
            guard eyes.distance >= boxes[index].width * size.width * 0.2 else { return nil }
            return eyes
        }
        return ThroughTheYears.Eyes.estimated(in: boxes[index], imageWidth: size.width, imageHeight: size.height)
    }

    /// Turned no further than this from the camera (degrees).
    static let largestYaw = 35.0

    static func isFrontal(yaw: Double) -> Bool { !yaw.isFinite || abs(yaw) <= largestYaw }

    /// The face that is the person: the one overlapping Recognize's box most (when any does), else the largest.
    static func bestFace(_ boxes: [FilmCrop], hint: FilmCrop?) -> Int? {
        guard !boxes.isEmpty else { return nil }
        if let hint {
            let overlaps = boxes.map { overlap($0, hint) }
            if let best = overlaps.indices.max(by: { overlaps[$0] < overlaps[$1] }), overlaps[best] > 0.1 { return best }
            // Recognize saw the face, Vision did not find it there: the box is better than someone else's face.
            return nil
        }
        return boxes.indices.max { boxes[$0].width * boxes[$0].height < boxes[$1].width * boxes[$1].height }
    }

    /// Intersection over union of two boxes.
    static func overlap(_ a: FilmCrop, _ b: FilmCrop) -> Double {
        let width = min(a.maxX, b.maxX) - max(a.x, b.x)
        let height = min(a.maxY, b.maxY) - max(a.y, b.y)
        guard width > 0, height > 0 else { return 0 }
        let intersection = width * height
        return intersection / (a.width * a.height + b.width * b.height - intersection)
    }

    /// The pupils, else the middle of each eye's outline.
    static func pupils(_ landmarks: FaceObservation.Landmarks2D, size: CGSize) -> ThroughTheYears.Eyes? {
        func centre(_ region: FaceObservation.Landmarks2D.Region) -> ThroughTheYears.Point? {
            let points = region.pointsInImageCoordinates(size, origin: .upperLeft)
            guard !points.isEmpty else { return nil }
            let x = points.map(\.x).reduce(0, +) / Double(points.count)
            let y = points.map(\.y).reduce(0, +) / Double(points.count)
            return ThroughTheYears.Point(x: x, y: y)
        }
        guard let left = centre(landmarks.leftPupil) ?? centre(landmarks.leftEye),
            let right = centre(landmarks.rightPupil) ?? centre(landmarks.rightEye)
        else { return nil }
        let eyes = ThroughTheYears.Eyes(left: left, right: right)
        return eyes.distance > 2 ? eyes : nil
    }

    /// The alignment as a Core Image transform (both pictures with the origin bottom left).
    public static func coreImageTransform(_ transform: ThroughTheYears.Transform, imageHeight: Double, frameHeight: Double)
        -> CGAffineTransform
    {
        // Top-left y = H − bottom-left y, in the photo and in the frame.
        CGAffineTransform(
            a: transform.a, b: -transform.b, c: transform.b, d: transform.a, tx: transform.tx - transform.b * imageHeight,
            ty: frameHeight - transform.a * imageHeight - transform.ty)
    }

    /// One frame: the photo aligned on its eyes over a blurred, darkened copy of itself that fills the rest of the frame.
    public static func frame(_ image: CGImage, eyes: ThroughTheYears.Eyes, size: CGSize, look: FilmLook = .none) -> CGImage? {
        let bounds = CGRect(origin: .zero, size: size)
        let transform = ThroughTheYears.alignment(eyes, width: size.width, height: size.height)
        let aligned = CIImage(cgImage: image).transformed(
            by: coreImageTransform(transform, imageHeight: Double(image.height), frameHeight: size.height))
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = aligned.clampedToExtent()
        blur.radius = Float(size.height / 18)
        let fill = FilmFrameRenderer.dimmed((blur.outputImage ?? aligned).cropped(to: bounds), 0.45)
        var picture = aligned.composited(over: fill).cropped(to: bounds)
        picture = FilmLookFilter.graded(picture, look: look)
        let context = CIContext(options: [.cacheIntermediates: false])
        return context.createCGImage(
            picture.composited(over: CIImage(color: .black).cropped(to: bounds)), from: bounds, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
}
