// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// One point of a tone curve: input and output level, both 0 … 1 in the sRGB (gamma-encoded) values a user sees.
public struct CurvePoint: Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A tone curve (SPEC §21.6.1): control points joined by a monotone cubic spline (Fritsch–Carlson), so the curve never
/// overshoots between two points — no banding or colour flips where a Catmull-Rom curve would swing past 0 or 1. The
/// same interpolation is described in docs/EDIT-FORMAT.md so other apps render the same picture.
public struct ToneCurve: Hashable, Sendable {
    /// Sorted by `x`, at least two points; the first and last are the curve's ends (they need not be at 0 and 1: moving
    /// them sets the black and white points).
    public private(set) var points: [CurvePoint]

    /// The straight line: nothing changes.
    public static let identity = ToneCurve(points: [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)])
    /// Most points a curve keeps (more are not useful by hand, and bound what a file can make the renderer do).
    public static let maximumPoints = 16
    /// Two points closer than this in `x` are one point.
    static let minimumGap = 0.01

    /// A curve through `points`: sorted, clamped to 0 … 1, points closer than `minimumGap` merged, at most
    /// `maximumPoints`; fewer than two points give the straight line.
    public init(points: [CurvePoint]) {
        let clean = points.filter { $0.x.isFinite && $0.y.isFinite }
            .map { CurvePoint(x: min(1, max(0, $0.x)), y: min(1, max(0, $0.y))) }
            .sorted { $0.x < $1.x }
        var merged: [CurvePoint] = []
        for point in clean {
            if let last = merged.last, point.x - last.x < Self.minimumGap {
                merged[merged.count - 1] = point
            } else {
                merged.append(point)
            }
        }
        if merged.count > Self.maximumPoints { merged = Array(merged.prefix(Self.maximumPoints - 1)) + [merged[merged.count - 1]] }
        self.points = merged.count >= 2 ? merged : [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]
    }

    /// Every point lies on the diagonal from (0, 0) to (1, 1): the curve changes nothing.
    public var isIdentity: Bool {
        guard let first = points.first, let last = points.last, first.x == 0, last.x == 1 else { return false }
        return points.allSatisfy { abs($0.x - $0.y) < 0.0005 }
    }

    /// The curve with a point added (or the point at that place moved).
    public func adding(_ point: CurvePoint) -> ToneCurve {
        ToneCurve(points: points + [point])
    }

    /// The curve without the point at `index`; the two ends stay.
    public func removing(at index: Int) -> ToneCurve {
        guard points.indices.contains(index), index != 0, index != points.count - 1 else { return self }
        var next = points
        next.remove(at: index)
        return ToneCurve(points: next)
    }

    /// The point at `index` moved to `point`, kept between its neighbours.
    public func moving(at index: Int, to point: CurvePoint) -> ToneCurve {
        guard points.indices.contains(index) else { return self }
        var next = points
        let lower = index > 0 ? points[index - 1].x + Self.minimumGap : 0
        let upper = index < points.count - 1 ? points[index + 1].x - Self.minimumGap : 1
        let x = index == 0 && points.count > 1 ? min(point.x, upper) : min(upper, max(lower, point.x))
        next[index] = CurvePoint(x: min(1, max(0, x)), y: min(1, max(0, point.y)))
        return ToneCurve(points: next)
    }

    // MARK: Evaluation

    /// Tangents of the monotone cubic Hermite spline at each point (Fritsch–Carlson).
    var tangents: [Double] {
        let count = points.count
        guard count >= 2 else { return [] }
        var slopes = [Double](repeating: 0, count: count - 1)
        for index in 0..<(count - 1) {
            let dx = points[index + 1].x - points[index].x
            slopes[index] = dx > 0 ? (points[index + 1].y - points[index].y) / dx : 0
        }
        var tangents = [Double](repeating: 0, count: count)
        tangents[0] = slopes[0]
        tangents[count - 1] = slopes[count - 2]
        if count > 2 {
            for index in 1..<(count - 1) {
                // A peak or a valley (slopes of different sign) is flat; otherwise the average of the two slopes.
                tangents[index] = slopes[index - 1] * slopes[index] <= 0 ? 0 : (slopes[index - 1] + slopes[index]) / 2
            }
        }
        for index in 0..<(count - 1) {
            if slopes[index] == 0 {
                tangents[index] = 0
                tangents[index + 1] = 0
                continue
            }
            let alpha = tangents[index] / slopes[index]
            let beta = tangents[index + 1] / slopes[index]
            let length = alpha * alpha + beta * beta
            if length > 9 {
                let tau = 3 / length.squareRoot()
                tangents[index] = tau * alpha * slopes[index]
                tangents[index + 1] = tau * beta * slopes[index]
            }
        }
        return tangents
    }

    /// The output level for input `x` (0 … 1). Left of the first point and right of the last the curve is flat.
    public func value(at x: Double) -> Double {
        table(size: 2, sampling: [x])[0]
    }

    /// The curve sampled at `count` evenly spaced inputs from 0 to 1.
    public func table(count: Int) -> [Double] {
        let samples = (0..<count).map { count > 1 ? Double($0) / Double(count - 1) : 0 }
        return table(size: count, sampling: samples)
    }

    private func table(size: Int, sampling: [Double]) -> [Double] {
        let tangents = tangents
        guard let first = points.first, let last = points.last else { return sampling }
        var segment = 0
        let ordered = sampling.enumerated().sorted { $0.element < $1.element }
        var result = [Double](repeating: 0, count: sampling.count)
        for (position, x) in ordered {
            let value: Double
            if x <= first.x {
                value = first.y
            } else if x >= last.x {
                value = last.y
            } else {
                while segment < points.count - 2 && x > points[segment + 1].x { segment += 1 }
                let p0 = points[segment]
                let p1 = points[segment + 1]
                let h = p1.x - p0.x
                let t = h > 0 ? (x - p0.x) / h : 0
                let t2 = t * t
                let t3 = t2 * t
                value =
                    (2 * t3 - 3 * t2 + 1) * p0.y + (t3 - 2 * t2 + t) * h * tangents[segment] + (-2 * t3 + 3 * t2) * p1.y
                    + (t3 - t2) * h * tangents[segment + 1]
            }
            result[position] = min(1, max(0, value))
        }
        return result
    }
}

/// The curves of a photo: one for all three channels (applied first) and one per channel (SPEC §21.6.1).
public struct ToneCurves: Hashable, Sendable {
    public var rgb = ToneCurve.identity
    public var red = ToneCurve.identity
    public var green = ToneCurve.identity
    public var blue = ToneCurve.identity

    public init(rgb: ToneCurve = .identity, red: ToneCurve = .identity, green: ToneCurve = .identity, blue: ToneCurve = .identity) {
        self.rgb = rgb
        self.red = red
        self.green = green
        self.blue = blue
    }

    public enum Channel: String, CaseIterable, Sendable {
        case rgb, red, green, blue
    }

    public subscript(channel: Channel) -> ToneCurve {
        get {
            switch channel {
            case .rgb: rgb
            case .red: red
            case .green: green
            case .blue: blue
            }
        }
        set {
            switch channel {
            case .rgb: rgb = newValue
            case .red: red = newValue
            case .green: green = newValue
            case .blue: blue = newValue
            }
        }
    }

    public var isIdentity: Bool { Channel.allCases.allSatisfy { self[$0].isIdentity } }

    /// Entries of the lookup table the renderer uses: enough that neighbouring entries never differ by a visible step.
    static let tableSize = 1024

    /// The table Core Image applies: for each input level the red, green and blue output, the channel's curve applied
    /// after the RGB curve (`out = red(rgb(in))`).
    func table() -> [Float] {
        let size = Self.tableSize
        let master = rgb.table(count: size)
        let channels: [[Double]?] = [red, green, blue].map { curve in curve.isIdentity ? nil : curve.table(count: size) }
        var data = [Float](repeating: 0, count: size * 3)
        for index in 0..<size {
            let level = master[index]
            for (channel, table) in channels.enumerated() {
                guard let table else {
                    data[index * 3 + channel] = Float(level)
                    continue
                }
                // The channel's curve at `level`, between its two nearest entries.
                let position = level * Double(size - 1)
                let lower = min(size - 1, max(0, Int(position.rounded(.down))))
                let upper = min(size - 1, lower + 1)
                let fraction = position - Double(lower)
                data[index * 3 + channel] = Float(table[lower] + (table[upper] - table[lower]) * fraction)
            }
        }
        return data
    }

    /// The curves on `image`, in sRGB (gamma-encoded) values as every editor shows them.
    public func apply(to image: CIImage) -> CIImage {
        guard !isIdentity else { return image }
        let values = table()
        let filter = CIFilter.colorCurves()
        filter.inputImage = image
        filter.curvesData = values.withUnsafeBufferPointer { Data(buffer: $0) }
        filter.curvesDomain = CIVector(x: 0, y: 1)
        filter.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        return filter.outputImage ?? image
    }
}
