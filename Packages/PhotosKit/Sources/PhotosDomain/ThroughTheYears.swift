// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// "Through the years" (SPEC §16.6): a time-lapse of one named person's face across the years. One photo per month (or
/// season, or year for long spans), the face in it turned so the eyes are level and scaled and moved so the eyes are in
/// the same place and the same distance apart in every frame; the frames dissolve into each other with the date, and the
/// age when the birthday is known, on screen. Pure selection, geometry and wording; the faces are found on the device
/// (`FaceLandmarks` in PhotosMedia).
public enum ThroughTheYears {
    /// A photo of the person, as Recognize found them in it.
    public struct Sample: Hashable, Sendable {
        public var fileId: FileID
        public var date: Date
        /// The person's face in the photo (Recognize's box: 0…1, origin top left), nil when unknown.
        public var face: FilmCrop?
        public var isFavorite: Bool
        /// Width / height of the photo.
        public var aspectRatio: Double

        public init(fileId: FileID, date: Date, face: FilmCrop?, isFavorite: Bool = false, aspectRatio: Double = 4 / 3) {
            self.fileId = fileId
            self.date = date
            self.face = face
            self.isFavorite = isFavorite
            self.aspectRatio = aspectRatio
        }
    }

    /// How finely the years are divided: one photo each.
    public enum Period: String, Hashable, Sendable, Codable {
        case month
        case season
        case year

        public var months: Int {
            switch self {
            case .month: 1
            case .season: 3
            case .year: 12
            }
        }
    }

    /// At most this many frames: a time-lapse of a few minutes at most.
    public static let frameLimit = 120
    /// At least this many periods with a photo, or there is nothing to watch grow.
    public static let minimumFrames = 3
    /// A face smaller than this share of the photo's width makes a blurry frame when enlarged; it is used only when the
    /// period has nothing better.
    public static let smallFace = 0.06

    /// The period that gives a film of a good length: months while the photos span up to four years (at most 48 frames),
    /// then seasons up to twelve years, then years.
    public static func period(spanning samples: [Sample], calendar: Calendar = .current) -> Period {
        guard let first = samples.map(\.date).min(), let last = samples.map(\.date).max() else { return .month }
        let months = (calendar.dateComponents([.month], from: first, to: last).month ?? 0) + 1
        if months <= 48 { return .month }
        if months <= 144 { return .season }
        return .year
    }

    /// The start of the period `date` falls into.
    public static func periodStart(of date: Date, period: Period, calendar: Calendar = .current) -> Date {
        var components = calendar.dateComponents([.year, .month], from: date)
        let month = components.month ?? 1
        components.month = ((month - 1) / period.months) * period.months + 1
        components.day = 1
        return calendar.date(from: components) ?? date
    }

    /// A frame of the film: the photo chosen for a period.
    public struct Pick: Hashable, Sendable {
        public var sample: Sample
        /// The start of the period it stands for.
        public var period: Date
    }

    /// The best photo of each period, oldest first: the larger, more central face, favourites a little ahead. Too many
    /// periods (very long spans) are thinned evenly to `limit`.
    public static func pick(_ samples: [Sample], period: Period? = nil, limit: Int = frameLimit, calendar: Calendar = .current)
        -> [Pick]
    {
        candidates(samples, period: period, limit: limit, calendar: calendar).compactMap(\.first)
    }

    /// Every period's photos, best first (`score`), periods oldest first and thinned evenly to `limit`: when the best
    /// face of a period cannot be lined up (turned away), the next one is tried.
    public static func candidates(
        _ samples: [Sample], period: Period? = nil, limit: Int = frameLimit, perPeriod: Int = 3, calendar: Calendar = .current
    ) -> [[Pick]] {
        let period = period ?? self.period(spanning: samples, calendar: calendar)
        var groups: [Date: [Sample]] = [:]
        for sample in samples {
            groups[periodStart(of: sample.date, period: period, calendar: calendar), default: []].append(sample)
        }
        var result: [[Pick]] = groups.keys.sorted().map { key in
            let ranked = groups[key]!.sorted { score($0) != score($1) ? score($0) > score($1) : $0.date < $1.date }
            return ranked.prefix(perPeriod).map { Pick(sample: $0, period: key) }
        }
        if result.count > limit, limit > 1 {
            // Evenly through the years, keeping the first and the last.
            let count = result.count
            result = (0..<limit).map { result[Int((Double($0) * Double(count - 1) / Double(limit - 1)).rounded())] }
        }
        return result
    }

    /// How well a photo shows the face: its size (up to a portrait's), how central it is, favourites first.
    public static func score(_ sample: Sample) -> Double {
        guard let face = sample.face, face.width > 0, face.height > 0 else { return sample.isFavorite ? 0.05 : 0 }
        // Face width as a share of the photo's shorter side (a portrait counts as much as a close landscape).
        let shorter = min(1, 1 / max(sample.aspectRatio, 0.01))
        let size = min(face.width / max(shorter, 0.01), 0.45)
        let small = face.width < smallFace ? 0.25 : 1
        let offCentre = hypot(face.midX - 0.5, face.midY - 0.45)
        let centred = 1 - min(offCentre, 0.7) * 0.5
        return size * small * centred * (sample.isFavorite ? 1.25 : 1)
    }

    // MARK: Alignment

    /// Where a face's eyes are in its photo (pixels, origin top left).
    public struct Eyes: Hashable, Sendable {
        public var left: Point
        public var right: Point

        public init(left: Point, right: Point) {
            // Left and right as they appear in the photo, whatever the detector calls them.
            if left.x <= right.x {
                self.left = left
                self.right = right
            } else {
                self.left = right
                self.right = left
            }
        }

        public var distance: Double { hypot(right.x - left.x, right.y - left.y) }
        public var middle: Point { Point(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2) }
        /// The tilt of the line through the eyes (radians, positive: the right eye is lower).
        public var angle: Double { atan2(right.y - left.y, right.x - left.x) }

        /// Where the eyes about are in a face box (pixels, origin top left), when no landmarks were found.
        public static func estimated(in box: FilmCrop, imageWidth: Double, imageHeight: Double) -> Eyes {
            let y = (box.y + box.height * 0.4) * imageHeight
            return Eyes(
                left: Point(x: (box.x + box.width * 0.31) * imageWidth, y: y),
                right: Point(x: (box.x + box.width * 0.69) * imageWidth, y: y))
        }
    }

    public struct Point: Hashable, Sendable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    /// Where the eyes go in every frame: their middle at this share of the frame's width and height…
    public static let eyeLine = Point(x: 0.5, y: 0.42)
    /// …and this far apart, as a share of the frame's shorter side.
    public static let eyeDistance = 0.17

    /// A similarity transform (rotation, uniform scale, translation) from photo pixels to frame pixels, both with the
    /// origin top left: x' = a·x − b·y + tx, y' = b·x + a·y + ty.
    public struct Transform: Hashable, Sendable {
        public var a: Double
        public var b: Double
        public var tx: Double
        public var ty: Double

        public func apply(_ point: Point) -> Point {
            Point(x: a * point.x - b * point.y + tx, y: b * point.x + a * point.y + ty)
        }

        public var scale: Double { hypot(a, b) }
        public var rotation: Double { atan2(b, a) }
    }

    /// Turns, scales and moves a photo so its eyes are level, `eyeDistance` apart and centred on `eyeLine` in a frame of
    /// `width` × `height` pixels.
    public static func alignment(_ eyes: Eyes, width: Double, height: Double) -> Transform {
        let target = eyeDistance * min(width, height)
        let scale = target / max(eyes.distance, 0.0001)
        // Rotate by −angle: the eyes become level.
        let a = scale * cos(-eyes.angle)
        let b = scale * sin(-eyes.angle)
        let middle = eyes.middle
        let destination = Point(x: eyeLine.x * width, y: eyeLine.y * height)
        return Transform(
            a: a, b: b, tx: destination.x - (a * middle.x - b * middle.y), ty: destination.y - (b * middle.x + a * middle.y))
    }

    /// How much of the frame the photo covers once aligned (0…1), sampled on a grid: frames whose face was close to an edge
    /// show more of the blurred fill.
    public static func coverage(_ transform: Transform, imageWidth: Double, imageHeight: Double, width: Double, height: Double)
        -> Double
    {
        // The inverse transform maps frame pixels back into the photo.
        let scale2 = transform.a * transform.a + transform.b * transform.b
        guard scale2 > 0 else { return 0 }
        var inside = 0
        let steps = 12
        for row in 0..<steps {
            for column in 0..<steps {
                let x = (Double(column) + 0.5) / Double(steps) * width - transform.tx
                let y = (Double(row) + 0.5) / Double(steps) * height - transform.ty
                let px = (transform.a * x + transform.b * y) / scale2
                let py = (-transform.b * x + transform.a * y) / scale2
                if px >= 0, py >= 0, px <= imageWidth, py <= imageHeight { inside += 1 }
            }
        }
        return Double(inside) / Double(steps * steps)
    }

    // MARK: Timing

    /// How fast the faces change.
    public enum Speed: String, CaseIterable, Hashable, Sendable, Codable {
        case slow
        case normal
        case fast

        /// Seconds per face.
        public var hold: Double {
            switch self {
            case .slow: 1.6
            case .normal: 1.0
            case .fast: 0.55
            }
        }

        /// The dissolve into the next face: most of the time on screen, so the face seems to grow up.
        public var crossfade: Double { hold * 0.6 }
    }

    /// The film of `frames` faces with a title first (card 0): the title stays 3 s, the last face 2.5 s.
    public static func plan(frames: Int, speed: Speed) -> FilmPlan {
        FilmPlan(timeLapse: frames + 1, hold: speed.hold, crossfade: speed.crossfade, firstHold: 3.2, lastHold: 2.6)
    }

    // MARK: Age

    /// The age on `date` of someone born on `birthday`: whole years from 2 on, months below that; nil before birth.
    public static func age(on date: Date, birthday: Date, calendar: Calendar = .current) -> DateComponents? {
        guard date >= calendar.startOfDay(for: birthday) else { return nil }
        let parts = calendar.dateComponents([.year, .month], from: birthday, to: date)
        let years = parts.year ?? 0
        if years >= 2 { return DateComponents(year: years) }
        return DateComponents(month: years * 12 + (parts.month ?? 0))
    }
}
