// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation

/// A free-form crop (SPEC §7.16.1) as fractions of the picture the user sees in the editor — straightened, turned and
/// flipped — with the origin at the top left, as on screen. Fractions and not pixels: the editor works on a smaller proxy
/// of the photo and the full original is rendered on save.
public struct CropRect: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let full = CropRect(x: 0, y: 0, width: 1, height: 1)

    /// The smallest side, as a fraction of the picture's side: the handles cannot be pushed onto each other.
    public static let minimumSide = 0.05

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    /// Nothing is cut off (within rounding).
    public var isFull: Bool {
        abs(x) < 1e-6 && abs(y) < 1e-6 && abs(width - 1) < 1e-6 && abs(height - 1) < 1e-6
    }

    /// Width over height in pixels of a picture of `size`.
    public func pixelAspect(in size: CGSize) -> Double {
        guard height > 0, size.height > 0 else { return 1 }
        return (width * Double(size.width)) / (height * Double(size.height))
    }

    /// The same area after the picture is turned a quarter to the right.
    public func rotatedClockwise() -> CropRect {
        CropRect(x: 1 - maxY, y: x, width: height, height: width)
    }

    /// The same area after the picture is turned a quarter to the left.
    public func rotatedCounterclockwise() -> CropRect {
        CropRect(x: y, y: 1 - maxX, width: height, height: width)
    }

    /// The same area after the picture is mirrored left to right.
    public func flippedHorizontally() -> CropRect {
        CropRect(x: 1 - maxX, y: y, width: width, height: height)
    }

    /// The area in Core Image coordinates (origin at the bottom left) of an image with `extent`, on whole pixels.
    public func rect(in extent: CGRect) -> CGRect {
        let width = Double(extent.width)
        let height = Double(extent.height)
        let left = (x * width).rounded()
        let right = (maxX * width).rounded()
        let top = (y * height).rounded()
        let bottom = (maxY * height).rounded()
        let rect = CGRect(
            x: Double(extent.minX) + left, y: Double(extent.minY) + height - bottom, width: max(1, right - left),
            height: max(1, bottom - top))
        return rect.intersection(extent)
    }

    /// The largest area with `aspect` (pixel width over height) in the middle of a picture of `size`.
    public static func centered(aspect: Double, in size: CGSize) -> CropRect {
        guard aspect > 0, size.width > 0, size.height > 0 else { return .full }
        let pictureAspect = Double(size.width / size.height)
        if pictureAspect > aspect {
            let width = aspect / pictureAspect
            return CropRect(x: (1 - width) / 2, y: 0, width: width, height: 1)
        } else {
            let height = pictureAspect / aspect
            return CropRect(x: 0, y: (1 - height) / 2, width: 1, height: height)
        }
    }

    /// The area made larger or smaller by `factor` around its middle, keeping its aspect and staying on the picture (the
    /// adjustable action of the crop frame for VoiceOver and Voice Control).
    public func scaled(by factor: Double) -> CropRect {
        let largest = min(1 / width, 1 / height)
        let smallest = max(Self.minimumSide / width, Self.minimumSide / height)
        let scale = min(max(factor, min(smallest, largest)), largest)
        let newWidth = width * scale
        let newHeight = height * scale
        let newX = min(max(0, x + width / 2 - newWidth / 2), 1 - newWidth)
        let newY = min(max(0, y + height / 2 - newHeight / 2), 1 - newHeight)
        return CropRect(x: newX, y: newY, width: newWidth, height: newHeight)
    }

    /// What the user drags: a corner, an edge or the whole area.
    public enum Handle: CaseIterable, Sendable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, move

        var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
        var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
        var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
        var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
        public var isCorner: Bool { (movesLeft || movesRight) && (movesTop || movesBottom) }
    }

    /// The area after `handle` was dragged by `dx`, `dy` (fractions of the picture's width and height) from this one.
    ///
    /// - Parameters:
    ///   - lockedAspect: keep this pixel aspect (width over height) while resizing; nil for a free crop.
    ///   - size: the picture's size in pixels, needed to keep an aspect.
    public func dragged(_ handle: Handle, dx: Double, dy: Double, lockedAspect: Double? = nil, in size: CGSize) -> CropRect {
        if handle == .move {
            return CropRect(
                x: min(max(0, x + dx), 1 - width), y: min(max(0, y + dy), 1 - height), width: width, height: height)
        }
        if let lockedAspect, lockedAspect > 0, size.width > 0, size.height > 0 {
            return resized(handle, dx: dx, dy: dy, keeping: Double(size.width / size.height) / lockedAspect)
        }
        let minimum = Self.minimumSide
        var left = x
        var right = maxX
        var top = y
        var bottom = maxY
        if handle.movesLeft { left = min(max(0, left + dx), right - minimum) }
        if handle.movesRight { right = max(min(1, right + dx), left + minimum) }
        if handle.movesTop { top = min(max(0, top + dy), bottom - minimum) }
        if handle.movesBottom { bottom = max(min(1, bottom + dy), top + minimum) }
        return CropRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// Resizing with a fixed aspect: `ratio` is height over width in fractions (`height = width × ratio`). A corner keeps
    /// the opposite corner in place; an edge keeps the opposite edge and the middle of the other direction.
    private func resized(_ handle: Handle, dx: Double, dy: Double, keeping ratio: Double) -> CropRect {
        let minimum = max(Self.minimumSide, Self.minimumSide / ratio)
        let horizontal = handle.movesLeft || handle.movesRight
        let vertical = handle.movesTop || handle.movesBottom
        // The width the pointer asks for, from the direction it moved most.
        let fromX: Double = handle.movesLeft ? width - dx : width + dx
        let fromY: Double = (handle.movesTop ? height - dy : height + dy) / ratio
        var newWidth: Double
        if horizontal && vertical {
            newWidth = abs(fromX - width) >= abs(fromY - width) ? fromX : fromY
        } else {
            newWidth = horizontal ? fromX : fromY
        }
        // The room there is: up to the picture's edges from what stays in place.
        var maxWidth: Double = 1
        var maxHeight: Double = 1
        let centerX = x + width / 2
        let centerY = y + height / 2
        if handle.movesLeft { maxWidth = maxX } else if handle.movesRight { maxWidth = 1 - x } else { maxWidth = 2 * min(centerX, 1 - centerX) }
        if handle.movesTop { maxHeight = maxY } else if handle.movesBottom { maxHeight = 1 - y } else { maxHeight = 2 * min(centerY, 1 - centerY) }
        newWidth = min(newWidth, maxWidth, maxHeight / ratio)
        newWidth = max(newWidth, min(minimum, maxWidth, maxHeight / ratio))
        let newHeight = newWidth * ratio
        let newX: Double = handle.movesLeft ? maxX - newWidth : handle.movesRight ? x : centerX - newWidth / 2
        let newY: Double = handle.movesTop ? maxY - newHeight : handle.movesBottom ? y : centerY - newHeight / 2
        return CropRect(x: newX, y: newY, width: newWidth, height: newHeight)
    }
}
