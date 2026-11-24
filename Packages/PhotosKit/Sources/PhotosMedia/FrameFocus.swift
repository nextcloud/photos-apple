// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import PhotosDomain
import Vision

/// Where a memory film's camera should look in a picture (SPEC §15.1): the faces in it, else the part that draws the eye
/// (Vision's attention-based saliency). On the device only; the picture never leaves it.
public enum FrameFocus {
    /// Faces are framed with some room around them.
    static let faceMargin = 1.8

    /// The region to frame, in picture coordinates (origin top left, 0…1), or nil when nothing stands out.
    public static func focus(of image: CGImage) async -> FilmCrop? {
        if let faces = try? await DetectFaceRectanglesRequest().perform(on: image), !faces.isEmpty {
            // The larger faces; tiny ones in the background would pull the camera away from the people the photo is of.
            let largest = faces.map { $0.boundingBox.width * $0.boundingBox.height }.max() ?? 0
            let crops = faces.filter { $0.boundingBox.width * $0.boundingBox.height >= largest * 0.25 }
                .map { crop(x: $0.boundingBox.origin.x, y: $0.boundingBox.origin.y, width: $0.boundingBox.width, height: $0.boundingBox.height) }
            if let first = crops.first {
                return crops.dropFirst().reduce(first) { $0.union($1) }.expanded(by: faceMargin)
            }
        }
        if let saliency = try? await GenerateAttentionBasedSaliencyImageRequest().perform(on: image),
            let object = saliency.salientObjects.max(by: { $0.confidence < $1.confidence })
        {
            let box = object.boundingBox
            return crop(x: box.origin.x, y: box.origin.y, width: box.width, height: box.height)
        }
        return nil
    }

    /// Vision's normalised rectangle (origin bottom left) as a crop (origin top left).
    static func crop(x: Double, y: Double, width: Double, height: Double) -> FilmCrop {
        FilmCrop(x: x, y: 1 - y - height, width: width, height: height)
    }
}
