// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import PhotosModel

/// The arrangements a collage or card can have (SPEC §15.8.3).
public enum CollageStyle: String, CaseIterable, Sendable, Codable {
    /// Equal cells in rows and columns.
    case grid
    /// Rows of different heights that keep each photo close to its own shape (justified rows).
    case mosaic
    /// Instant-photo prints with white borders, slightly turned, as if laid on a table.
    case polaroid
    /// One large photo and a column or row of small ones, the title over the large one.
    case magazine

    /// How many photos the style can hold.
    public var maxPhotos: Int {
        switch self {
        case .grid, .mosaic: 12
        case .polaroid: 9
        case .magazine: 7
        }
    }
}

/// A photo of a collage: its shape and the part that must stay visible (faces, the salient subject).
public struct CollagePhoto: Sendable, Hashable {
    public var id: FileID
    /// Width / height of the picture.
    public var aspect: Double
    /// The important part, in the picture's unit coordinates (0…1, origin top left). The whole picture when unknown.
    public var focus: CGRect

    public init(id: FileID, aspect: Double, focus: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) {
        self.id = id
        self.aspect = aspect > 0 && aspect.isFinite ? aspect : 1
        self.focus = focus.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1)).ifEmpty(
            CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}

/// Where one photo goes on the canvas.
public struct CollageCell: Sendable, Hashable {
    /// Position of the photo in the list the layout was made for.
    public var index: Int
    /// The cell (for a print: the whole print with its border), in canvas points.
    public var frame: CGRect
    /// Where the picture itself goes, in canvas points (inside `frame`).
    public var photoFrame: CGRect
    /// Rotation around the cell's centre, in degrees.
    public var rotation: Double
    /// The part of the picture shown, in its unit coordinates (origin top left); it has the shape of `photoFrame`.
    public var crop: CGRect
    /// Drawn as a print with a white border and a shadow.
    public var isPrint: Bool
}

/// The arrangement of a whole collage.
public struct CollageLayout: Sendable, Hashable {
    public var canvas: CGSize
    public var cells: [CollageCell]
    /// Where the title goes, nil without a title.
    public var titleFrame: CGRect?
    /// The title lies over a photo (light text on a shade) instead of on the background.
    public var titleOverPhoto: Bool
}

/// Lays out collages: pure geometry, so every style is unit-tested (SPEC §15.8.3).
public enum CollageLayouts {
    /// Makes the layout of `photos` (in this order; for `magazine` the first one is the large one) on a canvas of `canvas`
    /// points. Photos beyond the style's maximum are left out.
    /// - Parameter seed: varies the turn and offset of the prints (`polaroid`); the same seed gives the same layout.
    public static func layout(
        _ style: CollageStyle, photos: [CollagePhoto], canvas: CGSize, hasTitle: Bool, seed: UInt64 = 0
    ) -> CollageLayout {
        let photos = Array(photos.prefix(style.maxPhotos))
        let side = min(canvas.width, canvas.height)
        let margin = (side * 0.04).rounded()
        let gutter = (side * 0.015).rounded()
        var area = CGRect(origin: .zero, size: canvas).insetBy(dx: margin, dy: margin)
        var titleFrame: CGRect?
        if hasTitle && style != .magazine {
            let band = (canvas.height * 0.12).rounded()
            titleFrame = CGRect(x: area.minX, y: area.maxY - band, width: area.width, height: band)
            area.size.height -= band + gutter
        }
        guard !photos.isEmpty, area.width > 0, area.height > 0 else {
            return CollageLayout(canvas: canvas, cells: [], titleFrame: titleFrame, titleOverPhoto: false)
        }
        switch style {
        case .grid:
            return CollageLayout(
                canvas: canvas, cells: grid(photos, in: area, gutter: gutter), titleFrame: titleFrame, titleOverPhoto: false)
        case .mosaic:
            return CollageLayout(
                canvas: canvas, cells: mosaic(photos, in: area, gutter: gutter), titleFrame: titleFrame, titleOverPhoto: false)
        case .polaroid:
            return CollageLayout(
                canvas: canvas, cells: polaroid(photos, in: area, seed: seed), titleFrame: titleFrame,
                titleOverPhoto: false)
        case .magazine:
            let cells = magazine(photos, in: area, gutter: gutter)
            var title: CGRect?
            if hasTitle, let hero = cells.first?.photoFrame {
                let height = min(hero.height * 0.3, canvas.height * 0.16)
                title = CGRect(x: hero.minX, y: hero.maxY - height, width: hero.width, height: height)
            }
            return CollageLayout(canvas: canvas, cells: cells, titleFrame: title, titleOverPhoto: hasTitle)
        }
    }

    // MARK: Styles

    /// Columns and rows for `count` cells about as wide as high in `area` (a shorter last row stretches, so empty places
    /// do not matter). On a tie the wider top row wins: 5 photos are 3 over 2.
    static func gridShape(count: Int, area: CGRect) -> (columns: Int, rows: Int) {
        var best = (columns: 1, rows: count, cost: Double.infinity)
        for columns in 1...max(1, count) {
            let rows = Int((Double(count) / Double(columns)).rounded(.up))
            let cellAspect = Double(area.width / CGFloat(columns)) / Double(area.height / CGFloat(rows))
            let cost = abs(log(cellAspect))
            if cost <= best.cost + 1e-9 { best = (columns, rows, cost) }
        }
        return (best.columns, best.rows)
    }

    static func grid(_ photos: [CollagePhoto], in area: CGRect, gutter: CGFloat) -> [CollageCell] {
        let (columns, rows) = gridShape(count: photos.count, area: area)
        let height = (area.height - gutter * CGFloat(rows - 1)) / CGFloat(rows)
        var cells: [CollageCell] = []
        for row in 0..<rows {
            let first = row * columns
            let inRow = min(columns, photos.count - first)
            // A shorter last row: its cells share the whole width.
            let width = (area.width - gutter * CGFloat(inRow - 1)) / CGFloat(inRow)
            for column in 0..<inRow {
                let frame = CGRect(
                    x: area.minX + CGFloat(column) * (width + gutter), y: area.minY + CGFloat(row) * (height + gutter), width: width,
                    height: height)
                cells.append(cell(first + column, photos[first + column], frame: frame))
            }
        }
        return cells
    }

    /// Justified rows: the number of rows whose natural height is closest to the area's, then stretched to fill it exactly.
    static func mosaic(_ photos: [CollagePhoto], in area: CGRect, gutter: CGFloat) -> [CollageCell] {
        var best: (rows: [[Int]], error: Double)?
        for count in 1...photos.count {
            let rows = partition(photos.map(\.aspect), into: count)
            let height = rows.reduce(0.0) { total, row in
                total + Double(area.width - gutter * CGFloat(row.count - 1)) / row.reduce(0.0) { $0 + photos[$1].aspect }
            }
            let natural = height + Double(gutter) * Double(rows.count - 1)
            let error = abs(log(natural / Double(area.height)))
            if best == nil || error < best!.error { best = (rows, error) }
        }
        let rows = best?.rows ?? [Array(photos.indices)]
        let heights = rows.map { row in
            Double(area.width - gutter * CGFloat(row.count - 1)) / row.reduce(0.0) { $0 + photos[$1].aspect }
        }
        let available = Double(area.height - gutter * CGFloat(rows.count - 1))
        let scale = available / heights.reduce(0, +)
        var cells: [CollageCell] = []
        var y = Double(area.minY)
        for (row, natural) in zip(rows, heights) {
            let height = natural * scale
            var x = Double(area.minX)
            let widthTotal = Double(area.width - gutter * CGFloat(row.count - 1))
            let aspectTotal = row.reduce(0.0) { $0 + photos[$1].aspect }
            for (position, index) in row.enumerated() {
                // The last cell takes what rounding left over, so the row ends exactly at the edge.
                let width =
                    position == row.count - 1 ? Double(area.maxX) - x : widthTotal * photos[index].aspect / aspectTotal
                cells.append(cell(index, photos[index], frame: CGRect(x: x, y: y, width: width, height: height)))
                x += width + Double(gutter)
            }
            y += height + Double(gutter)
        }
        return cells
    }

    /// Splits a sequence of widths into `count` consecutive runs of about equal total (greedy, order kept).
    static func partition(_ widths: [Double], into count: Int) -> [[Int]] {
        let count = max(1, min(count, widths.count))
        let target = widths.reduce(0, +) / Double(count)
        var rows: [[Int]] = [[]]
        var sum = 0.0
        for (index, width) in widths.enumerated() {
            let remainingItems = widths.count - index
            let remainingRows = count - rows.count
            // Start a new row when this one is full enough, or when every remaining row needs one of the remaining items.
            if !rows[rows.count - 1].isEmpty && remainingRows > 0
                && (sum + width / 2 > target || remainingItems <= remainingRows)
            {
                rows.append([])
                sum = 0
            }
            rows[rows.count - 1].append(index)
            sum += width
        }
        return rows
    }

    static func polaroid(_ photos: [CollagePhoto], in area: CGRect, seed: UInt64) -> [CollageCell] {
        let (columns, rows) = gridShape(count: photos.count, area: area)
        let slotWidth = area.width / CGFloat(columns)
        let slotHeight = area.height / CGFloat(rows)
        // A print is a square photo with a narrow border and a wide one at the bottom.
        let printWidth = min(slotWidth * 0.94, slotHeight * 0.94 / 1.16)
        let printHeight = printWidth * 1.16
        let border = printWidth * 0.06
        var generator = SeededGenerator(seed: seed)
        var cells: [CollageCell] = []
        for (index, photo) in photos.enumerated() {
            let row = index / columns
            let column = index % columns
            let inRow = min(columns, photos.count - row * columns)
            // A shorter last row is centred.
            let rowOffset = CGFloat(columns - inRow) * slotWidth / 2
            let centre = CGPoint(
                x: area.minX + rowOffset + (CGFloat(column) + 0.5) * slotWidth + CGFloat(generator.unit() - 0.5) * slotWidth * 0.06,
                y: area.minY + (CGFloat(row) + 0.5) * slotHeight + CGFloat(generator.unit() - 0.5) * slotHeight * 0.06)
            let frame = CGRect(x: centre.x - printWidth / 2, y: centre.y - printHeight / 2, width: printWidth, height: printHeight)
            let photoFrame = CGRect(
                x: frame.minX + border, y: frame.minY + border, width: printWidth - 2 * border, height: printWidth - 2 * border)
            let rotation = (generator.unit() - 0.5) * 12
            cells.append(
                CollageCell(
                    index: index, frame: frame, photoFrame: photoFrame, rotation: rotation,
                    crop: crop(imageAspect: photo.aspect, cellAspect: 1, focus: photo.focus), isPrint: true))
        }
        return cells
    }

    /// The first photo large (left on a wide canvas, on top on a tall one), the others in a column or row beside it.
    static func magazine(_ photos: [CollagePhoto], in area: CGRect, gutter: CGFloat) -> [CollageCell] {
        guard photos.count > 1 else { return [cell(0, photos[0], frame: area)] }
        let others = Array(photos.indices.dropFirst())
        let wide = area.width >= area.height
        var cells: [CollageCell] = []
        let hero: CGRect
        let rest: CGRect
        if wide {
            let width = (area.width - gutter) * 0.64
            hero = CGRect(x: area.minX, y: area.minY, width: width, height: area.height)
            rest = CGRect(x: hero.maxX + gutter, y: area.minY, width: area.maxX - hero.maxX - gutter, height: area.height)
        } else {
            let height = (area.height - gutter) * 0.62
            hero = CGRect(x: area.minX, y: area.minY, width: area.width, height: height)
            rest = CGRect(x: area.minX, y: hero.maxY + gutter, width: area.width, height: area.maxY - hero.maxY - gutter)
        }
        cells.append(cell(0, photos[0], frame: hero))
        // Up to three in one line beside the large photo; more in two lines.
        let lines = others.count > 3 ? 2 : 1
        let perLine = Int((Double(others.count) / Double(lines)).rounded(.up))
        for line in 0..<lines {
            let members = Array(others.dropFirst(line * perLine).prefix(perLine))
            guard !members.isEmpty else { continue }
            for (position, index) in members.enumerated() {
                let frame: CGRect
                if wide {
                    let lineWidth = (rest.width - gutter * CGFloat(lines - 1)) / CGFloat(lines)
                    let height = (rest.height - gutter * CGFloat(members.count - 1)) / CGFloat(members.count)
                    frame = CGRect(
                        x: rest.minX + CGFloat(line) * (lineWidth + gutter), y: rest.minY + CGFloat(position) * (height + gutter),
                        width: lineWidth, height: height)
                } else {
                    let lineHeight = (rest.height - gutter * CGFloat(lines - 1)) / CGFloat(lines)
                    let width = (rest.width - gutter * CGFloat(members.count - 1)) / CGFloat(members.count)
                    frame = CGRect(
                        x: rest.minX + CGFloat(position) * (width + gutter), y: rest.minY + CGFloat(line) * (lineHeight + gutter),
                        width: width, height: lineHeight)
                }
                cells.append(cell(index, photos[index], frame: frame))
            }
        }
        return cells
    }

    static func cell(_ index: Int, _ photo: CollagePhoto, frame: CGRect) -> CollageCell {
        let aspect = frame.height > 0 ? Double(frame.width / frame.height) : 1
        return CollageCell(
            index: index, frame: frame, photoFrame: frame, rotation: 0,
            crop: crop(imageAspect: photo.aspect, cellAspect: aspect, focus: photo.focus), isPrint: false)
    }

    // MARK: Cropping

    /// The part of a picture shown in a cell of another shape: as large as possible, centred on the focus and inside the
    /// picture. When the focus does not fit, its top (where faces are) is kept. Unit coordinates, origin top left.
    public static func crop(imageAspect: Double, cellAspect: Double, focus: CGRect) -> CGRect {
        guard imageAspect > 0, cellAspect > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        if cellAspect > imageAspect {
            // The cell is wider: full width, part of the height.
            let height = imageAspect / cellAspect
            let y = focus.height <= height ? focus.midY - height / 2 : focus.minY
            return CGRect(x: 0, y: clamp(y, 0, 1 - height), width: 1, height: height)
        } else {
            let width = cellAspect / imageAspect
            let x = focus.midX - width / 2
            return CGRect(x: clamp(x, 0, 1 - width), y: 0, width: width, height: 1)
        }
    }

    static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double { min(max(value, lower), upper) }
}

/// Chooses the photos of a collage from a memory or an album, and keeps the user's order (SPEC §15.8.3).
public enum CollagePicker {
    /// How many photos a collage from a memory or album starts with.
    public static let defaultCount = 6

    /// Up to `count` photos (no videos, no screenshots): favourites first (at most half), then photos spread evenly over the
    /// time the set covers. The best one comes first (it is the large one of a magazine layout), the others by time.
    public static func pick(_ items: [MediaItem], count: Int = defaultCount, hasPeople: Set<FileID> = []) -> [MediaItem] {
        let photos = items.filter { item in
            item.kind == .image && !item.isLivePhotoVideo && PhotoOfTheDay.quality(DailyPhotoCandidate(item)) >= 0
        }
        .sorted { $0.timestamp < $1.timestamp }
        guard count > 0, !photos.isEmpty else { return [] }
        var chosen: [MediaItem] = []
        if photos.count <= count {
            chosen = photos
        } else {
            let favorites = photos.filter(\.isFavorite)
            chosen = spread(favorites, count: min(favorites.count, count / 2))
            let taken = Set(chosen.map(\.fileId))
            chosen += spread(photos.filter { !taken.contains($0.fileId) }, count: count - chosen.count)
        }
        let scored = chosen.map { ($0, PhotoOfTheDay.quality(DailyPhotoCandidate($0, hasPeople: hasPeople.contains($0.fileId)))) }
        guard let hero = scored.max(by: { a, b in a.1 != b.1 ? a.1 < b.1 : a.0.timestamp > b.0.timestamp })?.0 else { return [] }
        return [hero] + chosen.filter { $0.fileId != hero.fileId }.sorted { $0.timestamp < $1.timestamp }
    }

    /// `count` items evenly spaced through `items` (which are in time order).
    static func spread(_ items: [MediaItem], count: Int) -> [MediaItem] {
        guard count > 0, !items.isEmpty else { return [] }
        guard items.count > count else { return items }
        let step = Double(items.count) / Double(count)
        return (0..<count).map { items[Int(Double($0) * step + step / 2)] }
    }

    /// The order after the user swapped two photos.
    public static func swapped(_ order: [FileID], _ first: FileID, _ second: FileID) -> [FileID] {
        guard let a = order.firstIndex(of: first), let b = order.firstIndex(of: second) else { return order }
        var result = order
        result.swapAt(a, b)
        return result
    }
}

/// A small deterministic random generator (SplitMix64) for layouts that must look the same every time.
struct SeededGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A number in 0..<1.
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

extension CGRect {
    fileprivate func ifEmpty(_ other: CGRect) -> CGRect { isEmpty || isNull ? other : self }
}
