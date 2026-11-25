// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation

/// How the Library's zoom levels morph into each other (SPEC §17.5): the photos seen on both levels travel and scale from
/// where they were to where they are on the new level, instead of the levels only cross-fading.
///
/// A year's key photo is also the key photo of the month (and the day) it was taken in (`KeyPhoto` picks the first best
/// photo of a range), and a day's highlights are tiles of the grid, so the same photo is found on both sides by its id.
public enum LibraryZoomMorph {
    /// One photo moving from its place on the old level to its place on the new one.
    public struct Flight<ID: Hashable & Sendable>: Hashable, Sendable {
        /// The photo shown at the start (on the old level).
        public var source: ID
        /// The photo shown at the end; another one only for the hero (the card under the fingers, whose own photo is not
        /// on the new level): the picture cross-fades while it moves.
        public var destination: ID
        public var from: CGRect
        public var to: CGRect

        public init(source: ID, destination: ID, from: CGRect, to: CGRect) {
            self.source = source
            self.destination = destination
            self.from = from
            self.to = to
        }

        public var crossFades: Bool { source != destination }
    }

    /// What a level change looks like.
    public enum Style: Equatable, Sendable {
        /// The shared photos travel; the rest cross-fades with a slight scale.
        case flights
        /// A plain cross-fade (Reduce Motion: no movement, no zoom).
        case crossFade
    }

    public static func style(reduceMotion: Bool) -> Style { reduceMotion ? .crossFade : .flights }

    /// No more photos than this travel at once: the rest cross-fade with their level (a dense grid can share dozens of
    /// photos with the days; beyond a screenful the eye does not follow them, and each one is a view while it flies).
    public static let maximumFlights = 24

    /// The flights of a level change.
    /// - Parameters:
    ///   - source: frames of the photos on screen on the old level (as the user sees them: a pinch's scale included).
    ///   - destination: frames of the photos on screen on the new level.
    ///   - hero: the photo of the card the zoom started from, and the photo of the card it arrives at; it travels even when
    ///     the two differ (a month whose key photo is not the year's).
    ///   - viewport: the visible area; photos outside it on either side do not travel.
    ///   - anchor: where the zoom started (the fingers); the photos closest to it are kept when there are too many.
    ///   - limit: the most photos that travel.
    public static func flights<ID: Hashable & Sendable>(
        from source: [ID: CGRect], to destination: [ID: CGRect], hero: (source: ID, destination: ID)? = nil, viewport: CGRect,
        anchor: CGPoint, limit: Int = maximumFlights
    ) -> [Flight<ID>] {
        guard limit > 0 else { return [] }
        func visible(_ rect: CGRect) -> Bool {
            rect.width > 0.5 && rect.height > 0.5 && rect.isFinite && rect.intersects(viewport)
        }
        var flights: [Flight<ID>] = []
        for (id, from) in source where visible(from) {
            guard let to = destination[id], visible(to) else { continue }
            flights.append(Flight(source: id, destination: id, from: from, to: to))
        }
        flights.sort { distance($0.from, anchor) < distance($1.from, anchor) }
        if flights.count > limit { flights.removeLast(flights.count - limit) }
        // The hero travels even when its own photo is not on the new level, unless its photo or its target travel already.
        if let hero, hero.source != hero.destination, let from = source[hero.source], let to = destination[hero.destination],
            visible(from), visible(to),
            !flights.contains(where: { $0.source == hero.source || $0.destination == hero.destination })
        {
            if flights.count == limit { flights.removeLast() }
            flights.insert(Flight(source: hero.source, destination: hero.destination, from: from, to: to), at: 0)
        }
        return flights
    }

    /// Where a frame is shown while a pinch scales its level by `scale` around `anchor` (`scaleEffect`): the flights of a
    /// pinch start where the fingers left the photos.
    public static func scaled(_ rect: CGRect, by scale: Double, around anchor: CGPoint) -> CGRect {
        guard scale.isFinite, scale > 0, scale != 1 else { return rect }
        let factor = CGFloat(scale)
        return CGRect(
            x: anchor.x + (rect.minX - anchor.x) * factor, y: anchor.y + (rect.minY - anchor.y) * factor, width: rect.width * factor,
            height: rect.height * factor)
    }

    /// The corner radius a photo has on each level: cards are rounded, grid tiles are square.
    public static func cornerRadius(on level: LibraryZoomLevel) -> CGFloat {
        switch level {
        case .years: 14
        case .months: 10
        case .days: 0
        case .all: 0
        }
    }

    private static func distance(_ rect: CGRect, _ point: CGPoint) -> CGFloat {
        hypot(rect.midX - point.x, rect.midY - point.y)
    }
}

extension CGRect {
    fileprivate var isFinite: Bool {
        origin.x.isFinite && origin.y.isFinite && size.width.isFinite && size.height.isFinite
    }
}
