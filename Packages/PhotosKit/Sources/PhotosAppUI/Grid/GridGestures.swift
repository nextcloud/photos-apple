// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import AVFoundation
import CoreGraphics
import Foundation
import OSLog
import PhotosCore
import PhotosDomain
import PhotosMedia
import PhotosModel
import PhotosStore

// The platform-neutral half of two grid gestures (SPEC §16.1): selecting a range of tiles by dragging across them, and
// peeking into a video, a Live Photo or a stack by scrubbing over its tile. `GridGestures+UIKit` and `PhotoGrid+AppKit`
// add the recognisers, the autoscroll and the drawing.

// MARK: - Range selection

/// A drag across the tiles that selects (or deselects) everything between the tile it started on and the tile under the
/// finger, in the grid's order, as in Photos. It deselects when it started on a selected tile. Tiles the range leaves
/// again go back to what they were before the drag.
struct GridRangeSelection: Equatable {
    /// Flat index (`GridModel.items`) of the tile the drag started on.
    let anchor: Int
    /// The drag selects; false: it deselects.
    let selects: Bool
    /// The selection before the drag.
    let base: Set<FileID>
    private(set) var current: Int

    init(anchor: Int, anchorId: FileID, base: Set<FileID>) {
        self.anchor = anchor
        self.base = base
        selects = !base.contains(anchorId)
        current = anchor
    }

    var range: ClosedRange<Int> { min(anchor, current)...max(anchor, current) }

    /// The tiles of the first range (just the anchor) and the state they get.
    func start(id: (Int) -> FileID?) -> [(index: Int, selected: Bool)] {
        guard let anchorId = id(anchor), base.contains(anchorId) != selects else { return [] }
        return [(anchor, selects)]
    }

    /// The finger is over the tile at `index` now: the tiles whose state changes (only those), in no particular order.
    mutating func move(to index: Int, id: (Int) -> FileID?) -> [(index: Int, selected: Bool)] {
        guard index != current else { return [] }
        let old = range
        current = index
        let new = range
        var changes: [(Int, Bool)] = []
        // Left the range: back to what it was.
        for tile in old where !new.contains(tile) {
            guard let fileId = id(tile) else { continue }
            let before = base.contains(fileId)
            if before != selects { changes.append((tile, before)) }
        }
        // Entered the range.
        for tile in new where !old.contains(tile) {
            guard let fileId = id(tile) else { continue }
            if base.contains(fileId) != selects { changes.append((tile, selects)) }
        }
        return changes
    }

    /// The whole selection the drag makes now.
    func selection(id: (Int) -> FileID?) -> Set<FileID> {
        var result = base
        for tile in range {
            guard let fileId = id(tile) else { continue }
            if selects { result.insert(fileId) } else { result.remove(fileId) }
        }
        return result
    }
}

/// Scrolling while a range is dragged to the top or bottom edge of the grid.
enum GridAutoscroll {
    /// Depth of the zone along each edge, in points.
    static let edge: Double = 64
    /// Fastest speed, deep in the zone (points per second).
    static let maximumSpeed: Double = 1600

    /// Points per second to scroll (negative: up) for a finger at `y` in a visible area from `top` to `bottom`. Grows
    /// with the square of the depth, so a finger just inside the zone creeps and one at the edge flies.
    static func speed(y: Double, top: Double, bottom: Double) -> Double {
        guard bottom - top > 2 * edge else { return 0 }
        if y < top + edge {
            let depth = min(1, (top + edge - y) / edge)
            return -maximumSpeed * depth * depth
        }
        if y > bottom - edge {
            let depth = min(1, (y - (bottom - edge)) / edge)
            return maximumSpeed * depth * depth
        }
        return 0
    }
}

// MARK: - Scrub to peek

/// What scrubbing over a tile shows: frames of a video, of the motion of a Live Photo, or the copies of a stack.
enum GridPeekKind: Equatable {
    case video
    case livePhoto
    case stack(count: Int)

    /// Nil for tiles there is nothing to peek into (photos, placeholders, formats the system cannot play).
    init?(_ item: GridMedia) {
        if item.stack.count > 1 {
            self = .stack(count: item.stack.count)
        } else if item.kind == .video, !MimeTypes.unplayableVideos.contains(item.mimeType) {
            self = .video
        } else if item.isLivePhoto {
            self = .livePhoto
        } else {
            return nil
        }
    }

    /// Pictures a peek is made of: a few frames are enough to see what happens, and each costs a decode (of a byte
    /// range of the video, for one that is not on the device).
    var frameCount: Int {
        switch self {
        case .video: 8
        case .livePhoto: 6
        case .stack(let count): min(count, 12)
        }
    }

    /// Segments of the peek's bar: one per copy of a stack; none (a continuous bar) for a video.
    var segments: Int {
        if case .stack = self { return frameCount }
        return 0
    }
}

enum GridPeek {
    static let logger = Logger(subsystem: "com.nextcloud.photos", category: "peek")

    /// The pointer must rest on a tile this long before anything is loaded: passing over tiles costs nothing.
    static let hoverDelay: Duration = .milliseconds(250)
    /// A finger must be held this long before a slide scrubs (a quicker move scrolls).
    static let holdDuration: TimeInterval = 0.2
    /// A held finger that has not slid by then is not scrubbing: the context menu may come.
    static let slideWindow: TimeInterval = 0.6

    /// Frame (or copy) for a position across the tile, 0 at the leading edge.
    static func index(fraction: Double, count: Int) -> Int {
        guard count > 0, fraction.isFinite else { return 0 }
        return min(count - 1, max(0, Int(fraction * Double(count))))
    }

    /// Times of the frames: the middle of each of `count` equal parts of the video, so the first is not the black frame
    /// a video often starts with and the last is not past the end.
    static func frameTimes(duration: Double, count: Int) -> [Double] {
        guard duration.isFinite, duration > 0, count > 0 else { return [] }
        return (0..<count).map { (Double($0) + 0.5) * duration / Double(count) }
    }

    /// The order frames are loaded in: the one under the finger first, then outwards.
    static func loadOrder(count: Int, from start: Int) -> [Int] {
        guard count > 0 else { return [] }
        let start = min(max(start, 0), count - 1)
        var order = [start]
        var step = 1
        while order.count < count {
            if start + step < count { order.append(start + step) }
            if start - step >= 0 { order.append(start - step) }
            step += 1
        }
        return order
    }

    /// The frame to show for `wanted`: itself when loaded, else the nearest loaded one (nil before any is there).
    static func nearestLoaded(_ wanted: Int, loaded: [Bool]) -> Int? {
        guard !loaded.isEmpty else { return nil }
        for distance in 0..<loaded.count {
            if wanted - distance >= 0, wanted - distance < loaded.count, loaded[wanted - distance] { return wanted - distance }
            if wanted + distance < loaded.count, distance > 0, loaded[wanted + distance] { return wanted + distance }
        }
        return nil
    }

    /// Position across a tile, 0…1, mirrored for right-to-left layouts.
    static func fraction(x: Double, in tile: CGRect, rightToLeft: Bool = false) -> Double {
        guard tile.width > 0 else { return 0 }
        let value = min(max((x - Double(tile.minX)) / Double(tile.width), 0), 1)
        return rightToLeft ? 1 - value : value
    }
}

/// Loads the pictures of one peek, the one under the finger first, and keeps them while the peek lasts. Cancelled when
/// the finger or pointer leaves the tile: nothing more is loaded or decoded then.
@MainActor
final class GridPeekLoader {
    let item: GridMedia
    let kind: GridPeekKind
    private(set) var frames: [CGImage?]
    /// A frame arrived.
    var changed: () -> Void = {}
    private var task: Task<Void, Never>?
    /// Keeps the stream of a video that is not on the device going while its frames are made (the asset's resource
    /// loader only holds it weakly).
    private var stream: StreamingAssetLoader?

    init(item: GridMedia, kind: GridPeekKind, cached: [CGImage?]? = nil) {
        self.item = item
        self.kind = kind
        frames = cached ?? Array(repeating: nil, count: kind.frameCount)
    }

    var isComplete: Bool { !frames.contains { $0 == nil } }

    /// The picture for a position across the tile and the index of the part it stands for.
    func picture(at fraction: Double) -> (image: CGImage?, index: Int) {
        let wanted = GridPeek.index(fraction: fraction, count: frames.count)
        let shown = GridPeek.nearestLoaded(wanted, loaded: frames.map { $0 != nil })
        return (shown.flatMap { frames[$0] }, wanted)
    }

    /// - Parameters:
    ///   - pixels: long edge of the frames (the tile's size on screen).
    ///   - fraction: where the finger or pointer is; that frame is loaded first.
    func start(services: AccountServices, pixels: Int, fraction: Double) {
        guard task == nil, !isComplete else { return }
        let first = GridPeek.index(fraction: fraction, count: frames.count)
        task = Task { [weak self] in
            guard let self else { return }
            switch self.kind {
            case .stack: await self.loadCopies(services: services, pixels: pixels, first: first)
            case .video: await self.loadFrames(of: self.item.fileId, services: services, pixels: pixels, first: first)
            case .livePhoto:
                guard let peer = try? await services.library.fetchItems([self.item.fileId])[self.item.fileId]?.livePhotoPeer else {
                    return
                }
                await self.loadFrames(of: peer, services: services, pixels: pixels, first: first)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        stream = nil
    }

    private func set(_ image: CGImage, at index: Int) {
        guard frames.indices.contains(index) else { return }
        frames[index] = image
        changed()
    }

    /// The copies of a stack: their previews at the tile's size, from the cache when they are there.
    private func loadCopies(services: AccountServices, pixels: Int, first: Int) async {
        let ids = Array(item.stack.prefix(frames.count))
        guard let rows = try? await services.library.gridMedia(ids) else { return }
        let side = Double(pixels) / 2
        for index in GridPeek.loadOrder(count: ids.count, from: first) where frames[index] == nil {
            guard !Task.isCancelled else { return }
            guard let member = rows[ids[index]] else { continue }
            if let image = await services.images.preview(services.previewRequest(for: member, tileSide: side, scale: 2)) {
                guard !Task.isCancelled else { return }
                set(image, at: index)
            }
        }
    }

    /// Frames of a video (or of a Live Photo's motion): from the local copy when there is one, else streamed through
    /// the app's HTTP client; only the byte ranges of these frames are read.
    private func loadFrames(of fileId: FileID, services: AccountServices, pixels: Int, first: Int) async {
        let row = try? await services.library.fetchItems([fileId])[fileId]
        GridPeek.logger.debug("peek \(fileId): loading frames")
        guard !Task.isCancelled, let asset = await asset(of: fileId, row: row, services: services), !Task.isCancelled else {
            GridPeek.logger.debug("peek \(fileId): no video (cancelled: \(Task.isCancelled))")
            return
        }
        var duration = item.kind == .video ? (item.duration ?? 0) : 0
        if duration <= 0, let loadedDuration = try? await asset.load(.duration), loadedDuration.isNumeric {
            duration = loadedDuration.seconds
        }
        guard !Task.isCancelled else { return }
        let times = GridPeek.frameTimes(duration: duration, count: frames.count)
        guard !times.isEmpty else {
            GridPeek.logger.debug("peek \(fileId): no duration")
            return
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: pixels, height: pixels)
        // Any frame near the time will do: the nearest key frame is decoded fastest.
        let tolerance = CMTime(seconds: duration / Double(times.count) / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let order = GridPeek.loadOrder(count: times.count, from: first).filter { frames[$0] == nil }
        let requested = order.map { CMTime(seconds: times[$0], preferredTimescale: 600) }
        GridPeek.logger.debug("peek \(fileId): \(requested.count) frames of \(duration) s")
        for await result in generator.images(for: requested) {
            guard !Task.isCancelled else {
                generator.cancelAllCGImageGeneration()
                return
            }
            do {
                let image = try result.image
                // The generator may hand the time back in another timescale: the nearest frame time is the one.
                let time = result.requestedTime.seconds
                guard let index = order.min(by: { abs(times[$0] - time) < abs(times[$1] - time) }) else { continue }
                set(image, at: index)
            } catch {
                GridPeek.logger.debug("peek \(fileId): frame failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        stream = nil
    }

    /// The video as an asset: the original when it is on the device, else a stream through the app's HTTP client (the
    /// trust and client certificate of the account apply). No player: nothing is buffered beyond the frames asked for.
    private func asset(of fileId: FileID, row: MediaItem?, services: AccountServices) async -> AVURLAsset? {
        if let row {
            let originalURL = services.originalURL(for: row)
            if let cached = services.images.originals.cached(fileId: fileId, etag: row.etag, url: originalURL) {
                return AVURLAsset(url: cached)
            }
        }
        guard let url = try? await services.api.directDownloadURL(fileId: fileId), !Task.isCancelled else { return nil }
        let source = MediaByteSource(url: url, headers: ["User-Agent": services.connection.userAgent], http: services.http)
        let loader = StreamingAssetLoader(
            source: source, mimeType: row?.mimeType ?? (item.kind == .video ? item.mimeType : "video/quicktime"))
        stream = loader
        return loader.makeAsset(fileName: row?.name ?? item.name)
    }
}

/// The pictures of the last few peeks, so scrubbing a tile again shows them at once.
@MainActor
final class GridPeekCache {
    private var entries: [(key: String, frames: [CGImage?])] = []
    static let capacity = 8

    static func key(_ item: GridMedia) -> String { "\(item.fileId)-\(item.etag)-\(item.stack.count)" }

    func frames(for item: GridMedia) -> [CGImage?]? {
        entries.first { $0.key == Self.key(item) }?.frames
    }

    func store(_ loader: GridPeekLoader) {
        let key = Self.key(loader.item)
        guard loader.frames.contains(where: { $0 != nil }) else { return }
        entries.removeAll { $0.key == key }
        entries.insert((key, loader.frames), at: 0)
        if entries.count > Self.capacity { entries.removeLast(entries.count - Self.capacity) }
    }
}
