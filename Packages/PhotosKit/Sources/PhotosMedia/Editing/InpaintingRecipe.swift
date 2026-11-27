// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation

/// What the Remove tool did to a photo (SPEC §21.5): the areas it filled in, in the order they were removed. Part of the
/// edit recipe (`EditRecipe.retouch`), so a removal is non-destructive like every other edit: the original keeps the
/// object, every rendition fills the areas in again (on the device, from the strokes) and undo is removing a stroke.
///
/// Coordinates are fractions of the original picture as it is shown upright (its EXIF orientation applied) — before the
/// crop, turns, straighten and flip of the recipe — with the origin at the top left. Removal comes before the colour
/// adjustments: changing them later never runs the (slow) fill again, and the fill sees the photo's own pixels.
public struct RetouchSteps: Hashable, Sendable {
    public var strokes: [RetouchStroke]

    public init(strokes: [RetouchStroke] = []) {
        self.strokes = strokes
    }

    public var isIdentity: Bool { strokes.isEmpty }

    /// The same steps with one more stroke.
    public func adding(_ stroke: RetouchStroke) -> RetouchSteps {
        RetouchSteps(strokes: strokes + [stroke])
    }
}

/// A point of a stroke: fractions of the original's width and height from its top left.
public struct RetouchPoint: Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public init(_ point: CGPoint) {
        self.init(x: Double(point.x), y: Double(point.y))
    }

    public var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

/// One area the Remove tool filled in.
public enum RetouchStroke: Hashable, Sendable {
    /// Brushed by hand: a line through `points`, `radius` wide on each side.
    case brush(Brush)
    /// An object picked by tapping it (Vision's mask of it), or a suggestion ("people in the background").
    case area(Area)

    public struct Brush: Hashable, Sendable {
        /// Half the brush's width, as a fraction of the original's shorter side.
        public var radius: Double
        public var points: [RetouchPoint]

        /// Rounded as the recipe stores them, so a stroke read back from the file is the same stroke.
        public init(radius: Double, points: [RetouchPoint]) {
            self.radius = RetouchStroke.rounded(radius)
            self.points = points.map { RetouchPoint(x: RetouchStroke.rounded($0.x), y: RetouchStroke.rounded($0.y)) }
        }
    }

    /// A small bitmap over the whole original: run lengths, row by row from the top left, starting with a run of cells
    /// that are not removed. Rendering scales it up smoothly and grows it by `grow`, so the object's edge and a soft
    /// shadow go with it.
    public struct Area: Hashable, Sendable {
        public var width: Int
        public var height: Int
        public var runs: [Int]
        /// How far the area is grown around the mask, as a fraction of the original's shorter side.
        public var grow: Double

        public init(width: Int, height: Int, runs: [Int], grow: Double = Area.defaultGrow) {
            self.width = width
            self.height = height
            self.runs = runs
            self.grow = RetouchStroke.rounded(grow)
        }

        /// Vision's masks follow the outline tightly. The fill continues what is around the hole, and the object's own
        /// edge pixels around a tight mask come back as a dark ghost of it: grown by 1.5 % of the shorter side, the
        /// object is gone (measured on the test library, SPEC §21.5).
        public static let defaultGrow = 0.015
        /// The long side of the stored bitmap: fine enough for an outline once it is grown, small enough for the recipe.
        public static let maxSide = 192

        /// The cells as bytes (0 or 255), row by row from the top; nil when the runs do not fill the bitmap exactly.
        public var cells: [UInt8]? {
            guard width > 0, height > 0, width * height <= 1_000_000 else { return nil }
            var cells = [UInt8]()
            cells.reserveCapacity(width * height)
            var on = false
            for run in runs {
                guard run >= 0, cells.count + run <= width * height else { return nil }
                cells.append(contentsOf: repeatElement(on ? 255 : 0, count: run))
                on.toggle()
            }
            return cells.count == width * height ? cells : nil
        }

        /// An area from a mask (any size, one byte per pixel, row by row from the top): scaled down to at most
        /// `maxSide`, a cell is removed when any of its pixels is at least half on. Nil for an empty mask.
        public static func from(mask: [UInt8], width: Int, height: Int, grow: Double = defaultGrow) -> Area? {
            guard width > 0, height > 0, mask.count >= width * height else { return nil }
            let scale = min(1, Double(maxSide) / Double(max(width, height)))
            let cellsWide = max(1, Int((Double(width) * scale).rounded()))
            let cellsHigh = max(1, Int((Double(height) * scale).rounded()))
            var cells = [Bool](repeating: false, count: cellsWide * cellsHigh)
            var any = false
            for y in 0..<height {
                let cy = min(cellsHigh - 1, y * cellsHigh / height)
                for x in 0..<width where mask[y * width + x] >= 128 {
                    cells[cy * cellsWide + min(cellsWide - 1, x * cellsWide / width)] = true
                    any = true
                }
            }
            guard any else { return nil }
            var runs = [Int]()
            var current = false
            var length = 0
            for cell in cells {
                if cell == current {
                    length += 1
                } else {
                    runs.append(length)
                    current = cell
                    length = 1
                }
            }
            runs.append(length)
            return Area(width: cellsWide, height: cellsHigh, runs: runs, grow: grow)
        }

        /// The removed cells' bounds as fractions of the picture (top left origin), not grown; nil when empty.
        public var bounds: CGRect? {
            guard let cells else { return nil }
            var minX = width
            var minY = height
            var maxX = -1
            var maxY = -1
            for y in 0..<height {
                for x in 0..<width where cells[y * width + x] != 0 {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
            guard maxX >= 0 else { return nil }
            return CGRect(
                x: Double(minX) / Double(width), y: Double(minY) / Double(height), width: Double(maxX - minX + 1) / Double(width),
                height: Double(maxY - minY + 1) / Double(height))
        }
    }

    /// The area the stroke covers, grown as it is filled in, in fractions of a picture of `size` (top left origin).
    public func bounds(in size: CGSize) -> CGRect? {
        let short = Double(min(size.width, size.height))
        guard size.width > 0, size.height > 0 else { return nil }
        switch self {
        case .brush(let brush):
            guard let first = brush.points.first else { return nil }
            var rect = CGRect(origin: first.cgPoint, size: .zero)
            for point in brush.points.dropFirst() { rect = rect.union(CGRect(origin: point.cgPoint, size: .zero)) }
            let dx = brush.radius * short / Double(size.width)
            let dy = brush.radius * short / Double(size.height)
            return rect.insetBy(dx: -dx, dy: -dy)
        case .area(let area):
            guard let bounds = area.bounds else { return nil }
            // Grown, and by one cell more for the smooth scaling of the bitmap.
            let dx = area.grow * short / Double(size.width) + 1 / Double(area.width)
            let dy = area.grow * short / Double(size.height) + 1 / Double(area.height)
            return bounds.insetBy(dx: -dx, dy: -dy)
        }
    }
}

// MARK: - JSON

/// ```json
/// "retouch": { "strokes": [
///   { "brush": { "radius": 0.02, "points": [[0.412, 0.533], [0.418, 0.54]] } },
///   { "area": { "width": 192, "height": 128, "runs": [9310, 4, 186, 7], "grow": 0.006 } } ] }
/// ```
/// A stroke of a kind this version does not know is skipped (the rest is still removed); a broken one too.
extension RetouchSteps: Codable {
    private enum Keys: String, CodingKey { case strokes }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let decoded = (try? container.decodeIfPresent([Lenient].self, forKey: .strokes)) ?? []
        strokes = decoded.compactMap(\.stroke)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(strokes, forKey: .strokes)
    }

    /// One element of `strokes` that never fails to decode.
    private struct Lenient: Decodable {
        var stroke: RetouchStroke?
        init(from decoder: any Decoder) throws {
            stroke = try? RetouchStroke(from: decoder)
        }
    }
}

extension RetouchStroke: Codable {
    private enum Keys: String, CodingKey { case brush, area }
    private enum BrushKeys: String, CodingKey { case radius, points }
    private enum AreaKeys: String, CodingKey { case width, height, runs, grow }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        if let brush = try? container.nestedContainer(keyedBy: BrushKeys.self, forKey: .brush) {
            let radius = try brush.decode(Double.self, forKey: .radius)
            let pairs = try brush.decode([[Double]].self, forKey: .points)
            let points = pairs.compactMap { pair -> RetouchPoint? in
                guard pair.count == 2, pair.allSatisfy(\.isFinite) else { return nil }
                return RetouchPoint(x: min(1, max(0, pair[0])), y: min(1, max(0, pair[1])))
            }
            guard radius.isFinite, radius > 0, !points.isEmpty else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "brush"))
            }
            self = .brush(Brush(radius: min(0.5, radius), points: points))
        } else if let area = try? container.nestedContainer(keyedBy: AreaKeys.self, forKey: .area) {
            let grow = (try? area.decodeIfPresent(Double.self, forKey: .grow)) ?? Area.defaultGrow
            let value = Area(
                width: try area.decode(Int.self, forKey: .width), height: try area.decode(Int.self, forKey: .height),
                runs: try area.decode([Int].self, forKey: .runs), grow: grow.isFinite ? min(0.1, max(0, grow)) : Area.defaultGrow)
            guard value.cells != nil else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "area")) }
            self = .area(value)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unknown stroke"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .brush(let brush):
            var nested = container.nestedContainer(keyedBy: BrushKeys.self, forKey: .brush)
            try nested.encode(Self.rounded(brush.radius), forKey: .radius)
            try nested.encode(brush.points.map { [Self.rounded($0.x), Self.rounded($0.y)] }, forKey: .points)
        case .area(let area):
            var nested = container.nestedContainer(keyedBy: AreaKeys.self, forKey: .area)
            try nested.encode(area.width, forKey: .width)
            try nested.encode(area.height, forKey: .height)
            try nested.encode(area.runs, forKey: .runs)
            if area.grow != Area.defaultGrow { try nested.encode(Self.rounded(area.grow), forKey: .grow) }
        }
    }

    /// Five decimals: a tenth of a pixel of a 100-megapixel photo, and a short file.
    static func rounded(_ value: Double) -> Double {
        (value * 100_000).rounded() / 100_000
    }
}
