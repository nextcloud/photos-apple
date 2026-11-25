// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// A trackpad pinch on the Mac grid as a continuous zoom (SPEC §17.7): between two zoom steps the grid is scaled with the
/// fingers, so the tiles grow or shrink smoothly towards the size of the next step; when the pinch has gone far enough the
/// layout switches to that step, at the size the scaled tiles already have. Only the scale is computed here; the grid
/// applies it as a transform (on the GPU, no layout per frame).
struct GridPinchZoom: Equatable {
    /// Magnification that takes the grid from one step to the next (as the earlier stepping pinch did).
    static let stepDistance = 0.22
    /// How far a pinch past the largest or smallest step stretches the grid before it stops (rubber band).
    static let rubberBand = 0.05
    /// A released pinch that went at least this far towards the next step switches to it; less springs back.
    static let commitFraction = 0.5

    /// The gesture's magnification where the current step began.
    private(set) var origin = 0.0

    /// What a new magnification of the gesture means for the grid.
    enum Outcome: Equatable {
        /// Scale the grid by this factor (1: as laid out).
        case scale(Double)
        /// Switch to the next larger (`zoomIn`) or smaller step; the new step starts at scale 1.
        case step(zoomIn: Bool)
    }

    /// The step's tile side, and the next step's in either direction (nil at the end of the steps).
    struct Sides: Equatable {
        var current: Double
        var larger: Double?
        var smaller: Double?

        func next(zoomIn: Bool) -> Double? { zoomIn ? larger : smaller }
    }

    /// The pinch started: the current step begins at this magnification.
    mutating func begin(at magnification: Double = 0) {
        origin = magnification
    }

    /// The fingers moved to `magnification`.
    ///
    /// Within a step the scale goes geometrically from 1 to the ratio of the next step's tile side to the current one, so
    /// the motion feels even in both directions. Past the last step in a direction the grid only stretches a little
    /// (`rubberBand`), unless `pastEnd` says something takes over there (the Library's days when zooming out), which is
    /// then reported as a step.
    mutating func update(magnification: Double, sides: Sides, pastEnd: Bool = false) -> Outcome {
        let delta = magnification - origin
        let zoomIn = delta > 0
        let progress = min(abs(delta) / Self.stepDistance, 1)
        guard let next = sides.next(zoomIn: zoomIn), sides.current > 0, next > 0 else {
            if pastEnd, !zoomIn, progress >= 1 {
                origin = magnification
                return .step(zoomIn: false)
            }
            return .scale(Self.stretch(progress: progress, zoomIn: zoomIn))
        }
        if progress >= 1 {
            origin = magnification
            return .step(zoomIn: zoomIn)
        }
        return .scale(pow(next / sides.current, progress))
    }

    /// The fingers were lifted at `magnification`: whether the pinch switches to the next step (it went at least half
    /// way there) or springs back to the step it is on.
    func end(magnification: Double, sides: Sides) -> Bool? {
        let delta = magnification - origin
        guard abs(delta) / Self.stepDistance >= Self.commitFraction, sides.next(zoomIn: delta > 0) != nil else { return nil }
        return delta > 0
    }

    /// A slight, ever slower stretch beyond the last step.
    static func stretch(progress: Double, zoomIn: Bool) -> Double {
        let amount = rubberBand * (1 - pow(1 - min(max(progress, 0), 1), 2))
        return zoomIn ? 1 + amount : 1 - amount
    }
}

/// How far a tile under the pointer lifts on the Mac (SPEC §17.7): a few points bigger whatever its size, so small tiles
/// do not jump and large ones still show it, with a soft shadow below.
enum GridLiftMetrics {
    /// Points the picture grows by along each axis.
    static let growth = 8.0
    static let shadowRadius = 10.0
    static let shadowOpacity = 0.35
    static let shadowDrop = 4.0
    /// Seconds: quick to rise, a little slower to settle back.
    static let liftDuration = 0.16
    static let dropDuration = 0.24

    /// The scale of a lifted picture with this side; none with Reduce Motion (the shadow alone shows it then).
    static func scale(side: Double, reduceMotion: Bool) -> Double {
        guard !reduceMotion, side.isFinite, side > 0 else { return 1 }
        return 1 + min(max(growth / side, 0.02), 0.05)
    }
}
