// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics

/// The geometry of zooming a photo in the viewer (SPEC VW-1), shared by the UIKit and AppKit zoom views.
///
/// Scale 1 is the photo fitted into the page; the photo is never smaller than that.
enum ViewerZoom {
    static let minimumScale: CGFloat = 1
    static let maximumScale: CGFloat = 8
    /// What a double tap or double click zooms to.
    static let doubleTapScale: CGFloat = 2.5
    /// One step of Zoom In / Zoom Out (⌘+ / ⌘−).
    static let stepFactor: CGFloat = 1.5
    /// From here on the 4096 px preview is loaded instead of the 1024 px one (SPEC §5.5.2).
    static let highResolutionScale: CGFloat = 1.5
    /// Tolerance when comparing scales: a pinch seldom ends at exactly 1.
    static let epsilon: CGFloat = 0.01

    static func clamped(_ scale: CGFloat) -> CGFloat {
        guard scale.isFinite else { return minimumScale }
        return min(maximumScale, max(minimumScale, scale))
    }

    static func isZoomed(_ scale: CGFloat) -> Bool {
        scale > minimumScale + epsilon
    }

    /// The scale after one Zoom In or Zoom Out step. Stepping out lands exactly on the fitted size.
    static func stepped(_ scale: CGFloat, zoomIn: Bool) -> CGFloat {
        let next: CGFloat = clamped(zoomIn ? scale * stepFactor : scale / stepFactor)
        return isZoomed(next) ? next : minimumScale
    }

    /// A double tap zooms in on a fitted photo and back out of a zoomed one.
    static func doubleTapTarget(from scale: CGFloat) -> CGFloat {
        isZoomed(scale) ? minimumScale : doubleTapScale
    }

    /// `content` (a photo's pixel size, or just its aspect ratio) fitted into `bounds`, keeping the aspect ratio.
    static func fittedSize(content: CGSize, in bounds: CGSize) -> CGSize {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        guard content.width > 0, content.height > 0, content.width.isFinite, content.height.isFinite else { return bounds }
        let factor: CGFloat = min(bounds.width / content.width, bounds.height / content.height)
        return CGSize(width: content.width * factor, height: content.height * factor)
    }

    /// The part of the fitted photo (in its own, unscaled coordinates) that fills `bounds` at `scale` with `point`
    /// in the middle — moved back inside the photo where it would show what is beside it.
    static func zoomRect(scale: CGFloat, around point: CGPoint, content: CGSize, bounds: CGSize) -> CGRect {
        let scale: CGFloat = clamped(scale)
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        let wanted = CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
        let origin: CGPoint = clampedOffset(wanted, content: content, bounds: size)
        return CGRect(origin: origin, size: size)
    }

    /// The scroll offset closest to `offset` that keeps a photo of size `content` on screen: no further than its
    /// edges where it is larger than `bounds`, centred (a negative offset) where it is smaller.
    static func clampedOffset(_ offset: CGPoint, content: CGSize, bounds: CGSize) -> CGPoint {
        CGPoint(
            x: clampedOffset(offset.x, content: content.width, bounds: bounds.width),
            y: clampedOffset(offset.y, content: content.height, bounds: bounds.height))
    }

    static func clampedOffset(_ offset: CGFloat, content: CGFloat, bounds: CGFloat) -> CGFloat {
        guard content > bounds else { return (content - bounds) / 2 }
        return min(content - bounds, max(0, offset))
    }

    /// Where a photo of size `content` (already scaled) is placed in `bounds`: centred along an axis on which it is smaller.
    static func centeredOrigin(content: CGSize, bounds: CGSize) -> CGPoint {
        CGPoint(x: max(0, (bounds.width - content.width) / 2), y: max(0, (bounds.height - content.height) / 2))
    }
}

/// A zoom request from the menu bar or the keyboard for the page that is shown.
struct ViewerZoomCommand: Equatable {
    enum Kind: Equatable {
        case zoomIn, zoomOut, fit
    }

    /// Counts up, so the same request can be made twice in a row.
    var id: Int
    var kind: Kind

    func target(from scale: CGFloat) -> CGFloat {
        switch kind {
        case .zoomIn: ViewerZoom.stepped(scale, zoomIn: true)
        case .zoomOut: ViewerZoom.stepped(scale, zoomIn: false)
        case .fit: ViewerZoom.minimumScale
        }
    }
}

/// Vertical swipes on a page that is not zoomed (iPhone, iPad): down closes the viewer, up shows the info panel.
enum ViewerSwipe {
    /// The finger's travel and speed in window coordinates: the photo follows it both ways while it is dragged down.
    enum Phase: Equatable {
        case changed(translation: CGSize)
        case ended(translation: CGSize, velocity: CGVector)
        case cancelled
    }

    enum Outcome: Equatable {
        case dismiss, showInfo, none
    }

    /// Distance and speed (points, points per second) from which a swipe counts.
    static let distance: CGFloat = 120
    static let speed: CGFloat = 800

    /// A drag is a vertical swipe when it moves more up or down than sideways; the others belong to the pager.
    static func isVertical(velocity: CGPoint) -> Bool {
        abs(velocity.y) > abs(velocity.x)
    }

    /// What the swipe does when the finger is lifted. A fast flick counts even when it was short, but only in the
    /// direction the finger travelled.
    static func outcome(translation: CGFloat, velocity: CGFloat) -> Outcome {
        if translation > 0, translation > distance || velocity > speed { return .dismiss }
        if translation < 0, translation < -distance || velocity < -speed { return .showInfo }
        return .none
    }

    /// 0…1: how far the page has been dragged towards closing, for the fading backdrop and the shrinking page.
    static func dismissProgress(translation: CGFloat, height: CGFloat) -> CGFloat {
        guard height > 0, translation > 0 else { return 0 }
        return min(1, translation / (height * 0.6))
    }

    /// Scale of the page while it is dragged down.
    static func pageScale(progress: CGFloat) -> CGFloat {
        1 - 0.3 * min(1, max(0, progress))
    }
}
