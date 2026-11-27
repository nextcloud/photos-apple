// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation

/// Where a point of the edited picture (cropped, turned, straightened, flipped) lies on the original, for the Remove
/// tool (SPEC §21.5): the user brushes on what the editor shows, the recipe stores fractions of the original.
///
/// Mirrors the geometry of `PhotoEditor.apply` step by step (straighten, quarter turns, mirror, crop); a test renders
/// marked pictures through `PhotoEditor.apply` to keep the two in step.
public enum RetouchGeometry {
    /// The transform from the original's Core Image coordinates (origin at the bottom left, its extent at the origin) to
    /// the edited picture's, and the edited picture's size.
    public static func transform(_ edits: PhotoEdits, originalSize size: CGSize) -> (transform: CGAffineTransform, size: CGSize) {
        var transform = CGAffineTransform.identity
        var extent = CGRect(origin: .zero, size: size)
        if edits.straighten != 0 {
            let angle = edits.straighten * .pi / 180
            let rotation = CGAffineTransform(rotationAngle: angle)
            transform = transform.concatenating(rotation)
            let rotated = extent.applying(rotation)
            let scale = 1 / (abs(cos(angle)) + abs(sin(angle)) * max(size.width, size.height) / min(size.width, size.height))
            let width = size.width * scale
            let height = size.height * scale
            extent = CGRect(x: rotated.midX - width / 2, y: rotated.midY - height / 2, width: width, height: height)
        }
        if edits.rotation % 4 != 0 {
            let turn = CGAffineTransform(rotationAngle: -CGFloat(edits.rotation % 4) * .pi / 2)
            transform = transform.concatenating(turn)
            extent = extent.applying(turn)
        }
        if edits.flipped {
            let mirror = CGAffineTransform(scaleX: -1, y: 1)
            transform = transform.concatenating(mirror)
            extent = extent.applying(mirror)
        }
        transform = transform.concatenating(CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        extent = CGRect(origin: .zero, size: extent.size)
        if let area = PhotoEditor.cropArea(edits, size: extent.size) {
            let rect = area.rect(in: extent)
            transform = transform.concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            extent = CGRect(origin: .zero, size: rect.size)
        }
        return (transform, extent.size)
    }

    /// A point of the edited picture (fractions, top left origin) on the original (fractions, top left origin); nil
    /// when it falls outside the original.
    public static func originalPoint(_ point: CGPoint, edits: PhotoEdits, originalSize size: CGSize) -> CGPoint? {
        guard size.width > 0, size.height > 0 else { return nil }
        let (transform, edited) = transform(edits, originalSize: size)
        let pixel = CGPoint(x: point.x * edited.width, y: (1 - point.y) * edited.height).applying(transform.inverted())
        let result = CGPoint(x: pixel.x / size.width, y: 1 - pixel.y / size.height)
        let slack = 1e-6
        guard result.x >= -slack, result.x <= 1 + slack, result.y >= -slack, result.y <= 1 + slack else { return nil }
        return CGPoint(x: min(1, max(0, result.x)), y: min(1, max(0, result.y)))
    }

    /// A point of the original (fractions, top left origin) on the edited picture (fractions, top left origin); it may
    /// lie outside 0…1 when the crop cut it off.
    public static func editedPoint(_ point: CGPoint, edits: PhotoEdits, originalSize size: CGSize) -> CGPoint {
        let (transform, edited) = transform(edits, originalSize: size)
        let pixel = CGPoint(x: point.x * size.width, y: (1 - point.y) * size.height).applying(transform)
        return CGPoint(x: pixel.x / max(1, edited.width), y: 1 - pixel.y / max(1, edited.height))
    }
}
