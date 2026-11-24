// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The zoom levels of the Library (SPEC §15.5): years, months and days as cards with a key photo, and all photos as the
/// grid with its own column steps. A pinch moves along one ladder from the years to the largest grid tiles.
public enum LibraryZoomLevel: String, CaseIterable, Sendable, Codable, Hashable {
    case years, months, days, all

    /// `UserDefaults` key of the level the Library shows.
    public static let storageKey = "libraryZoomLevel"
}

/// A place on the zoom ladder: one of the summary levels, or the grid at a zoom step (`GridColumns.options`).
public enum LibraryZoomStop: Hashable, Sendable {
    case years, months, days
    case grid(step: Int)

    public var level: LibraryZoomLevel {
        switch self {
        case .years: .years
        case .months: .months
        case .days: .days
        case .grid: .all
        }
    }
}

/// The ladder a pinch moves along, most zoomed out first: years, months, days, then the grid from its densest step to its
/// largest tiles. "Days" sits before the densest grid: it shows a few photos of every day, the grid all of them.
public struct LibraryZoomLadder: Sendable, Equatable {
    public let stops: [LibraryZoomStop]

    /// - Parameter gridSteps: the grid's zoom steps as `GridColumns.options` lists them (fewest columns first).
    public init(gridSteps: [Int]) {
        stops = [.years, .months, .days] + gridSteps.sorted(by: >).map { .grid(step: $0) }
    }

    /// Where `stop` is; a grid step that is not on the ladder counts as the closest one.
    public func index(of stop: LibraryZoomStop) -> Int {
        if let index = stops.firstIndex(of: stop) { return index }
        guard case .grid(let step) = stop else { return 0 }
        let grid = stops.enumerated().compactMap { index, stop -> (Int, Int)? in
            if case .grid(let candidate) = stop { return (index, candidate) }
            return nil
        }
        return grid.min { abs($0.1 - step) < abs($1.1 - step) }?.0 ?? stops.count - 1
    }

    /// The stop `steps` rungs further in (positive: larger photos) or out, within the ladder.
    public func moved(_ stop: LibraryZoomStop, by steps: Int) -> LibraryZoomStop {
        let target = min(max(index(of: stop) + steps, 0), stops.count - 1)
        return stops[target]
    }

    public func canZoomIn(from stop: LibraryZoomStop) -> Bool { index(of: stop) < stops.count - 1 }
    public func canZoomOut(from stop: LibraryZoomStop) -> Bool { index(of: stop) > 0 }

    /// The first grid stop (the densest grid); a pinch out of it goes to the days.
    public var densestGrid: LibraryZoomStop? {
        stops.first { if case .grid = $0 { true } else { false } }
    }
}

/// How a pinch turns into zoom steps: the content follows the fingers while they move, and on release it settles on the
/// stop the pinch was heading for, taking its speed into account (a quick pinch goes further, as a fling does).
public enum LibraryZoomGesture {
    /// Scale factor of a pinch that commits one step; less springs back.
    public static let commitScale = 1.22
    /// Each further factor of this moves one more step (a long or fast pinch).
    public static let stepScale = 2.6
    /// Seconds of the pinch's speed that are carried on after the release.
    public static let momentum = 0.12
    /// No pinch moves more than this many steps.
    public static let maximumSteps = 3

    /// The scale the pinch would end at if its speed carried on for `momentum` seconds.
    /// - Parameters:
    ///   - scale: the pinch's scale now (1: as it began).
    ///   - velocity: change of the scale per second (UIKit's `UIPinchGestureRecognizer.velocity`).
    public static func projectedScale(scale: Double, velocity: Double) -> Double {
        guard scale.isFinite, scale > 0 else { return 1 }
        let speed = velocity.isFinite ? velocity : 0
        // In log space, so that pinching in and out are symmetric.
        let logScale = log(scale) + (speed / scale) * momentum
        return exp(min(max(logScale, -4), 4))
    }

    /// Steps a pinch that ends at `projectedScale` moves: positive zooms in (larger photos), negative out, 0 springs back.
    public static func steps(projectedScale: Double) -> Int {
        guard projectedScale.isFinite, projectedScale > 0 else { return 0 }
        let amount = abs(log(projectedScale))
        guard amount >= log(commitScale) else { return 0 }
        let steps = 1 + Int((amount - log(commitScale)) / log(stepScale))
        return (projectedScale > 1 ? 1 : -1) * min(steps, maximumSteps)
    }

    /// The scale shown while the fingers move. Where the ladder ends, the content resists (a rubber band) instead of
    /// following.
    public static func displayScale(_ scale: Double, canZoomIn: Bool, canZoomOut: Bool) -> Double {
        guard scale.isFinite, scale > 0 else { return 1 }
        let logScale = log(scale)
        let resisted = (logScale > 0 && !canZoomIn) || (logScale < 0 && !canZoomOut)
        // Up to a factor of 2.5 either way; beyond the end only a fifth of the movement, at most 8 %.
        let shown = resisted ? max(min(logScale * 0.2, log(1.08)), -log(1.08)) : max(min(logScale, log(2.5)), -log(2.5))
        return exp(shown)
    }

    /// How far the pinch is towards the next stop (0…1), for cross-fading to it while the fingers move.
    public static func progress(scale: Double) -> Double {
        guard scale.isFinite, scale > 0 else { return 0 }
        return min(abs(log(scale)) / log(commitScale * 1.3), 1)
    }
}

/// The year of the timeline at the top of the screen, and when crossing into another one deserves a haptic tick
/// (SPEC §15.5): while scrolling fast or scrubbing the year index, not while reading slowly through the photos.
public struct YearBoundaryTicker: Sendable {
    /// Points per second above which scrolling counts as fast.
    public var minimumSpeed: Double
    /// Ticks closer together than this (seconds) are left out: a fling through ten years is not a buzz.
    public var minimumInterval: TimeInterval

    private var year: Int?
    private var lastTick = -Double.infinity
    private var lastOffset: Double?
    private var lastTime: TimeInterval?
    /// Smoothed speed in points per second.
    private(set) var speed = 0.0

    public init(minimumSpeed: Double = 2200, minimumInterval: TimeInterval = 0.07) {
        self.minimumSpeed = minimumSpeed
        self.minimumInterval = minimumInterval
    }

    /// The grid scrolled.
    /// - Parameters:
    ///   - year: year of the section at the top; nil where there is none (no headers, empty grid).
    ///   - offset: vertical content offset in points.
    ///   - time: now, in seconds (any monotonic clock).
    ///   - isUserScrolling: the finger is on the grid or it decelerates after a fling (not a programmatic jump such as a
    ///     relayout after zooming).
    ///   - isScrubbing: the year index or the scrubber is being dragged.
    /// - Returns: whether to play a tick now.
    public mutating func update(year: Int?, offset: Double, time: TimeInterval, isUserScrolling: Bool, isScrubbing: Bool) -> Bool {
        if let lastOffset, let lastTime, time > lastTime {
            let instant = abs(offset - lastOffset) / (time - lastTime)
            speed = speed * 0.5 + instant * 0.5
        }
        lastOffset = offset
        lastTime = time
        guard let year else { return false }
        let previous = self.year
        self.year = year
        guard let previous, previous != year else { return false }
        guard isScrubbing || (isUserScrolling && speed >= minimumSpeed) else { return false }
        guard time - lastTick >= minimumInterval else { return false }
        lastTick = time
        return true
    }

    /// The grid shows something else (a new model, another zoom): the next year seen is not a crossing.
    public mutating func reset() {
        year = nil
        lastOffset = nil
        lastTime = nil
        speed = 0
    }
}
