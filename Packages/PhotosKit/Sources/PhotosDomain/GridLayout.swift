// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Square-tile grid maths shared by the UIKit and AppKit grids (SPEC §6.4).
///
/// The zoom level sets a *target tile size*; how many columns there are follows from the width, so a wide window
/// shows more photos instead of bigger ones.
public struct GridGeometry: Sendable, Equatable {
    public var columns: Int
    /// Side of a tile in points.
    public var side: Double
    public var spacing: Double

    public init(columns: Int, side: Double, spacing: Double) {
        self.columns = columns
        self.side = side
        self.spacing = spacing
    }

    /// The column count whose tiles come closest to `targetSide` in `width`.
    public static func fitting(width: Double, targetSide: Double, spacing: Double) -> GridGeometry {
        guard width > 0, targetSide > 0 else { return GridGeometry(columns: 1, side: max(width, 1), spacing: spacing) }
        let columns = max(1, Int(((width + spacing) / (targetSide + spacing)).rounded()))
        let side = max(1, (width - Double(columns - 1) * spacing) / Double(columns))
        return GridGeometry(columns: columns, side: side, spacing: spacing)
    }

    public func rows(forItems count: Int) -> Int {
        count <= 0 ? 0 : (count + columns - 1) / columns
    }

    /// Height of the tiles of a section with `count` items (without its header).
    public func height(forItems count: Int) -> Double {
        let rows = rows(forItems: count)
        return rows == 0 ? 0 : Double(rows) * side + Double(rows - 1) * spacing
    }

    /// Top offsets of every section plus the total height as last element (date scrubber).
    public func sectionOffsets(itemCounts: [Int], headerHeights: [Double]) -> [Double] {
        var offsets: [Double] = []
        offsets.reserveCapacity(itemCounts.count + 1)
        var y = 0.0
        for (index, count) in itemCounts.enumerated() {
            offsets.append(y)
            y += (index < headerHeights.count ? headerHeights[index] : 0) + height(forItems: count)
        }
        offsets.append(y)
        return offsets
    }

    /// Index of the section that contains the offset `y` (clamped).
    public static func section(at y: Double, in offsets: [Double]) -> Int? {
        guard offsets.count > 1 else { return nil }
        var low = 0
        var high = offsets.count - 2
        while low < high {
            let mid = (low + high + 1) / 2
            if offsets[mid] <= y { low = mid } else { high = mid - 1 }
        }
        return low
    }
}

/// Zoom steps of the grid. A step is stored as the number of columns it gives at the platform's reference width,
/// which keeps the stored setting (`gridColumns`) and the server's `gridDensity` mapping meaningful.
public enum GridZoom {
    /// Target tile side of a step.
    public static func targetSide(step: Int, referenceWidth: Double, spacing: Double) -> Double {
        let columns = Double(max(step, 1))
        return max(1, (referenceWidth - (columns - 1) * spacing) / columns)
    }

    /// The neighbouring step; `zoomIn` makes tiles larger.
    public static func step(_ current: Int, in options: [Int], zoomIn: Bool) -> Int {
        guard !options.isEmpty else { return current }
        let index = options.firstIndex(of: current) ?? options.firstIndex(where: { $0 >= current }) ?? options.count - 1
        return options[max(0, min(options.count - 1, index + (zoomIn ? -1 : 1)))]
    }

    /// Days at normal zoom, months for the two steps before the smallest, years at the smallest.
    public static func granularity(step: Int, in options: [Int]) -> TimelineGranularity {
        guard options.count >= 4 else { return .day }
        let index = options.firstIndex(of: step) ?? options.firstIndex(where: { $0 >= step }) ?? options.count - 1
        if index >= options.count - 1 { return .year }
        if index >= options.count - 3 { return .month }
        return .day
    }
}

/// Which preview size a square, aspect-filled tile needs (SPEC §5.5.1).
public enum PreviewSizing {
    /// Server previews are aspect-fit: their *long* edge is the requested size. A tile that crops to a square needs
    /// the *short* edge to cover it, so the request grows with the aspect ratio (capped: a panorama should not pull
    /// a 4096 px preview into a thumbnail).
    public static func neededPixels(tileSide: Double, scale: Double, aspectRatio: Double, maxAspectFactor: Double = 2) -> Double {
        let ratio = aspectRatio > 0 && aspectRatio.isFinite ? aspectRatio : 1
        let factor = min(max(ratio, 1 / ratio), maxAspectFactor)
        return tileSide * max(scale, 1) * factor
    }

    /// The smallest bucket that covers `pixels`. `tolerance` 0.9 accepts a bucket up to 10 % too small, which is not
    /// visible, rather than loading sixteen times the pixels for it.
    public static func bucket(forPixels pixels: Double, buckets: [Int] = [64, 256, 1024, 4096], tolerance: Double = 0.9) -> Int {
        buckets.first { Double($0) >= pixels * tolerance } ?? buckets.last ?? 1024
    }

    /// The bucket for a square cover of `side` points (album covers) whose photo's aspect ratio is not known: a 4:3
    /// photo is assumed, so that its short edge still covers the square. A 170 pt cover on a 2× screen needs 1024.
    public static func coverBucket(side: Double, scale: Double, buckets: [Int] = [64, 256, 1024, 4096]) -> Int {
        bucket(forPixels: neededPixels(tileSide: side, scale: scale, aspectRatio: 4.0 / 3.0), buckets: buckets)
    }

    /// The size (long edge) a preview is decoded to for a tile that needs `pixels`: rounded up to a multiple of `step`,
    /// so that resizing a window by a few points does not decode every tile again, and never more than the bucket.
    /// A 400 px tile then holds about 1.6 MB decoded instead of the 3 MB of its 1024 px bucket.
    public static func decodePixels(forPixels pixels: Double, bucket: Int, step: Int = 64) -> Int {
        guard pixels.isFinite, pixels > 0, step > 0 else { return bucket }
        let rounded = (Int(pixels.rounded(.up)) + step - 1) / step * step
        return min(bucket, max(step, rounded))
    }
}

/// What a grid shows when it has no items.
public enum GridEmptyPhase: Sendable, Equatable {
    /// Nothing is known yet: show a skeleton.
    case loading
    /// The source really is empty.
    case empty

    /// - Parameters:
    ///   - feedLoaded: the local query has delivered at least once.
    ///   - waitsForFirstSync: the grid shows the synced library (timeline), so "empty" needs a finished first sync.
    ///   - firstSyncRunning: the initial sync is in progress.
    ///   - hasSyncedBefore: a sync has completed at some point.
    ///   - syncStopped: the sync cannot continue right now (offline, failed, signed out).
    public static func phase(
        feedLoaded: Bool, waitsForFirstSync: Bool, firstSyncRunning: Bool, hasSyncedBefore: Bool, syncStopped: Bool
    ) -> GridEmptyPhase {
        guard feedLoaded else { return .loading }
        guard waitsForFirstSync else { return .empty }
        if firstSyncRunning { return .loading }
        if hasSyncedBefore || syncStopped { return .empty }
        // Never synced and nothing reported yet: the first sync is about to start.
        return .loading
    }
}
