// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// A window onto a picture, in the picture's own coordinates: 0…1 across and down, the origin at the top left. A window
/// may reach outside the picture (a portrait photo fitted into a landscape film); the part outside is filled with a
/// blurred copy of the picture.
public struct FilmCrop: Hashable, Sendable {
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

    public static let full = FilmCrop(x: 0, y: 0, width: 1, height: 1)

    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    /// The window between `self` (0) and `other` (1).
    public func interpolated(to other: FilmCrop, _ amount: Double) -> FilmCrop {
        FilmCrop(
            x: x + (other.x - x) * amount, y: y + (other.y - y) * amount, width: width + (other.width - width) * amount,
            height: height + (other.height - height) * amount)
    }

    /// The smallest window containing both.
    public func union(_ other: FilmCrop) -> FilmCrop {
        let left = min(x, other.x)
        let top = min(y, other.y)
        return FilmCrop(x: left, y: top, width: max(maxX, other.maxX) - left, height: max(maxY, other.maxY) - top)
    }

    /// Grown around its middle by `factor`, kept inside the picture.
    public func expanded(by factor: Double) -> FilmCrop {
        let grownWidth = min(1, width * factor)
        let grownHeight = min(1, height * factor)
        let left = min(max(0, midX - grownWidth / 2), 1 - grownWidth)
        let top = min(max(0, midY - grownHeight / 2), 1 - grownHeight)
        return FilmCrop(x: left, y: top, width: grownWidth, height: grownHeight)
    }
}

/// The slow camera move over a still picture of a memory film (SPEC §15.1): it zooms in on the faces or the most salient
/// part of the picture, pulls back from them, or pans across to them. Pure geometry, shared by the player and the video
/// export so both show the same film.
public enum KenBurns {
    /// A move from one window to another while the picture is on screen.
    public struct Motion: Hashable, Sendable {
        public var from: FilmCrop
        public var to: FilmCrop
        /// The picture is shown whole (letterboxed with a blurred fill), because filling the frame would cut away too much.
        public var fits: Bool

        public init(from: FilmCrop, to: FilmCrop, fits: Bool) {
            self.from = from
            self.to = to
            self.fits = fits
        }

        /// The window at `progress` (0…1) of the picture's time on screen, eased so the move starts and ends gently.
        public func crop(at progress: Double) -> FilmCrop {
            from.interpolated(to: to, KenBurns.ease(min(max(progress, 0), 1)))
        }
    }

    /// Filling the frame must keep at least this share of a picture; otherwise it is shown whole.
    public static let minimumCoverage = 0.55
    /// How far the camera zooms in (1.15: the closer window is 1/1.15 of the wide one).
    public static let zoom = 1.15
    /// The zoom of a pan: just enough to have room to move.
    public static let panZoom = 1.08

    /// Smoothstep: slow at both ends.
    public static func ease(_ value: Double) -> Double { value * value * (3 - 2 * value) }

    /// The window that fills the frame with the picture, or (`fits`) shows all of it.
    public static func base(imageAspect: Double, viewportAspect: Double) -> (crop: FilmCrop, fits: Bool) {
        let image = imageAspect > 0 && imageAspect.isFinite ? imageAspect : 1
        let viewport = viewportAspect > 0 && viewportAspect.isFinite ? viewportAspect : 16 / 9
        // Cover: one side is the whole picture, the other a part of it.
        let coverWidth = image >= viewport ? viewport / image : 1
        let coverHeight = image >= viewport ? 1 : image / viewport
        if coverWidth * coverHeight >= minimumCoverage {
            return (FilmCrop(x: (1 - coverWidth) / 2, y: (1 - coverHeight) / 2, width: coverWidth, height: coverHeight), false)
        }
        // Fit: one side is the whole picture, the other reaches beyond it.
        let fitWidth = image >= viewport ? 1 : viewport / image
        let fitHeight = image >= viewport ? image / viewport : 1
        return (FilmCrop(x: (1 - fitWidth) / 2, y: (1 - fitHeight) / 2, width: fitWidth, height: fitHeight), true)
    }

    /// The move for a picture. `focus` is the region to frame (faces, else the salient part), in picture coordinates;
    /// `seed` varies the kind of move from picture to picture; `still` (Reduce Motion) keeps the camera still; `closeness`
    /// is how far the camera moves in (a film style's, `FilmStyle.zoom`).
    public static func motion(
        imageAspect: Double, viewportAspect: Double, focus: FilmCrop?, seed: Int, still: Bool, closeness: Double = zoom
    ) -> Motion {
        let (base, fits) = base(imageAspect: imageAspect, viewportAspect: viewportAspect)
        guard !still else { return Motion(from: base, to: base, fits: fits) }
        let target = focus.flatMap { valid($0) }
        let close = window(in: base, zoom: closeness, around: target)
        let panZoom = min(panZoom, closeness)
        switch abs(seed) % 3 {
        case 0:
            return Motion(from: base, to: close, fits: fits)
        case 1:
            return Motion(from: close, to: base, fits: fits)
        default:
            // A pan ends on the focus; it starts on the far side of the picture from it.
            let end = window(in: base, zoom: panZoom, around: target)
            let startCentre = FilmCrop(x: 2 * base.midX - end.midX, y: 2 * base.midY - end.midY, width: 0, height: 0)
            var start = window(in: base, zoom: panZoom, around: startCentre)
            if abs(start.midX - end.midX) < 0.02 && abs(start.midY - end.midY) < 0.02 {
                // Nothing to pan across (the focus is in the middle): drift sideways instead.
                let side = seed % 2 == 0 ? 1.0 : -1.0
                start = window(
                    in: base, zoom: panZoom,
                    around: FilmCrop(x: base.midX + side * base.width, y: base.midY, width: 0, height: 0))
            }
            return Motion(from: start, to: end, fits: fits)
        }
    }

    /// A window `zoom` times closer than `base`, centred on `focus` (else the middle) as far as `base` allows, and
    /// never so close that the focus does not fit in it.
    static func window(in base: FilmCrop, zoom: Double, around focus: FilmCrop?) -> FilmCrop {
        var factor = zoom
        if let focus, focus.width > 0, focus.height > 0 {
            factor = min(factor, base.width / focus.width, base.height / focus.height)
        }
        factor = max(1, factor)
        let width = base.width / factor
        let height = base.height / factor
        let centreX = focus?.midX ?? base.midX
        let centreY = focus?.midY ?? base.midY
        let left = min(max(base.x, centreX - width / 2), base.maxX - width)
        let top = min(max(base.y, centreY - height / 2), base.maxY - height)
        return FilmCrop(x: left, y: top, width: width, height: height)
    }

    /// A focus inside the picture, or nil for an empty or nonsensical one.
    static func valid(_ focus: FilmCrop) -> FilmCrop? {
        let left = max(0, focus.x)
        let top = max(0, focus.y)
        let right = min(1, focus.maxX)
        let bottom = min(1, focus.maxY)
        guard right > left, bottom > top, left.isFinite, top.isFinite else { return nil }
        return FilmCrop(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// A square window round a face, for the round people pictures.
    public static func square(around focus: FilmCrop, imageAspect: Double) -> FilmCrop {
        let aspect = imageAspect > 0 && imageAspect.isFinite ? imageAspect : 1
        // Square in pixels: the height in picture units is the width times the picture's aspect. The focus already has
        // room around the face; never larger than the biggest square in the picture.
        let largest = min(1, 1 / aspect)
        let width = min(largest, max(focus.width, focus.height / aspect) * 1.1)
        let height = width * aspect
        let left = min(max(0, focus.midX - width / 2), 1 - width)
        let top = min(max(0, focus.midY - height / 2), 1 - height)
        return FilmCrop(x: left, y: top, width: width, height: height)
    }
}
