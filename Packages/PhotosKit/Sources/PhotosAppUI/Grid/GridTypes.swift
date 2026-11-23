// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import PhotosCore
import PhotosDomain
import PhotosMedia
import PhotosModel
import PhotosNetworking
import PhotosStore

#if canImport(UIKit)
    import UIKit
#endif

// The platform-neutral half of the photo grid: zoom steps, header texts and heights, tile badges and labels, preview
// requests. `PhotoGrid+AppKit` and `PhotoGrid+UIKit` only add the collection view around it; the sections model is
// `GridModel` (PhotosStore) and the layout maths `GridGeometry` (PhotosDomain).

/// An action offered in context menus and the selection toolbar.
struct GridMenuAction: Identifiable {
    var id: String
    var title: String
    var systemImage: String
    var isDestructive = false
    /// A separator goes before this action in menus.
    var startsGroup = false
    var handler: @MainActor ([FileID]) -> Void
}

/// Callbacks from the platform grid to SwiftUI.
struct GridCallbacks {
    var open: @MainActor (FileID) -> Void
    var menu: @MainActor ([FileID]) -> [GridMenuAction]
    var selectionChanged: @MainActor (Set<FileID>) -> Void
    /// A new zoom step (pinch, ⌘+/⌘−).
    var columnsChanged: @MainActor (Int) -> Void
    /// Escape: leave the selection mode.
    var cancelSelection: @MainActor () -> Void = {}
}

/// Zoom steps of the grid. A step is named after the number of columns it gives at the platform's reference width
/// (the default window on the Mac, a portrait screen elsewhere); the real column count follows from the width.
enum GridColumns {
    #if os(macOS)
        static let options = [3, 4, 5, 6, 8, 10, 12, 16]
        static let `default` = 8
    #elseif os(visionOS)
        static let options = [3, 4, 5, 6, 8, 10]
        static let `default` = 5
    #else
        static let options = [1, 3, 5, 7, 9, 13]
        static let `default` = 5
    #endif

    /// Content width at which a step shows exactly its number of columns.
    @MainActor static var referenceWidth: Double {
        #if os(macOS)
            1056
        #elseif os(visionOS)
            1000
        #else
            UIDevice.current.userInterfaceIdiom == .pad ? 768 : 390
        #endif
    }

    static func step(_ current: Int, zoomIn: Bool) -> Int {
        GridZoom.step(current, in: options, zoomIn: zoomIn)
    }

    /// Target tile side of a zoom step, in points.
    @MainActor static func targetSide(step: Int) -> Double {
        GridZoom.targetSide(step: step, referenceWidth: referenceWidth, spacing: Double(Design.tileSpacing))
    }

    /// Days at normal zoom, months and years when zoomed out.
    static func granularity(step: Int) -> TimelineGranularity {
        GridZoom.granularity(step: step, in: options)
    }

    @MainActor static func geometry(width: Double, step: Int) -> GridGeometry {
        GridGeometry.fitting(width: width, targetSide: targetSide(step: step), spacing: Double(Design.tileSpacing))
    }
}

/// The two lines of a section header.
struct GridHeaderText: Equatable {
    /// Month or year, large.
    var title: String?
    /// Day, small.
    var subtitle: String?
}

/// Header texts, formatted on demand (only for headers that are shown) and remembered per section.
@MainActor
final class GridHeaderTexts {
    private var cache: [Int: GridHeaderText] = [:]
    private var day = 0

    func text(for section: GridSection, now: Date = Date()) -> GridHeaderText {
        // "Today" and "Yesterday" go stale at midnight.
        let today = Int(now.timeIntervalSinceReferenceDate / 86400)
        if today != day {
            day = today
            cache.removeAll(keepingCapacity: true)
        }
        if let cached = cache[section.id] { return cached }
        let text = Self.format(section, now: now)
        cache[section.id] = text
        return text
    }

    func reset() { cache.removeAll(keepingCapacity: true) }

    static func format(_ section: GridSection, now: Date) -> GridHeaderText {
        switch section.kind {
        case .flat: GridHeaderText()
        case .day:
            GridHeaderText(
                title: section.startsMonth ? DayLabel.monthLabel(for: section.date, now: now) : nil,
                subtitle: DayLabel.label(for: section.date, now: now))
        case .month: GridHeaderText(title: DayLabel.monthLabel(for: section.date, now: now))
        case .year: GridHeaderText(title: DayLabel.yearLabel(for: section.date))
        }
    }

    /// Month and year of a section, for the date scrubber.
    static func scrubberLabel(_ section: GridSection) -> String {
        switch section.kind {
        case .flat: ""
        case .year: DayLabel.yearLabel(for: section.date)
        case .day, .month: DayLabel.monthYearLabel(for: section.date)
        }
    }
}

/// Fixed header heights. Absolute heights keep the content height exact, so scrubbing does not jump the way it does
/// with self-sizing headers that are measured as they scroll in.
struct GridHeaderMetrics: Equatable, Sendable {
    var titleHeight: Double
    var subtitleHeight: Double
    var top: Double = 10
    var gap: Double = 2
    var bottom: Double = 6

    func height(for section: GridSection) -> Double {
        switch section.kind {
        case .flat: 0
        case .day:
            section.startsMonth ? top + titleHeight + gap + subtitleHeight + bottom : top + subtitleHeight + bottom
        case .month, .year: top + titleHeight + bottom
        }
    }
}

/// What a tile shows besides its picture; the same on every platform.
enum GridTile {
    /// "Photo, 22 November 2026 at 14:03, Favorite".
    static func accessibilityLabel(for item: GridMedia) -> String {
        let kind: String =
            if item.kind == .video {
                String(localized: "Video", bundle: .module)
            } else if item.isLivePhoto {
                String(localized: "Live Photo", bundle: .module)
            } else {
                String(localized: "Photo", bundle: .module)
            }
        var parts: [String] = [kind, item.timestamp.formatted(date: .long, time: .shortened)]
        if item.kind == .video, let duration = item.duration { parts.append(Formatters.duration(duration)) }
        if item.isFavorite { parts.append(String(localized: "Favorite", bundle: .module)) }
        return parts.joined(separator: ", ")
    }

    /// Duration of a video, nil for photos and for videos of unknown length (those only get the video badge).
    static func durationText(for item: GridMedia) -> String? {
        guard item.kind == .video, let duration = item.duration, duration > 0 else { return nil }
        return Formatters.duration(duration)
    }

    static func showsBottomShade(for item: GridMedia) -> Bool {
        item.kind == .video || item.isFavorite
    }

    /// SF Symbol shown in place of a picture that cannot be had (no server preview, undecodable file).
    static func placeholderSymbol(for item: GridMedia) -> String {
        if item.kind == .video { return "video" }
        if item.mimeType.hasPrefix("image/") { return "photo" }
        return "doc"
    }

    /// Whether an image already at hand is good enough for a request, so nothing has to be loaded.
    static func covers(_ image: CGImage, bucket: Int) -> Bool {
        Double(max(image.width, image.height)) >= Double(bucket) * 0.9
    }
}

/// Builds preview requests for grid tiles.
extension AccountServices {
    /// - Parameters:
    ///   - tileSide: side of the tile in points.
    ///   - scale: backing scale of the window or screen the tile is on.
    func previewRequest(for item: GridMedia, tileSide: Double, scale: Double) -> ImagePipeline.Request {
        let pixels = PreviewSizing.neededPixels(tileSide: tileSide, scale: scale, aspectRatio: item.aspectRatio)
        return ImagePipeline.Request(
            fileId: item.fileId, etag: item.etag, bucket: PreviewSizing.bucket(forPixels: pixels, buckets: PhotosAPI.previewBuckets),
            hasPreview: item.hasPreview,
            mimeType: item.mimeType,
            originalURL: connection.filesURL(item.directory == "/" ? "/\(item.name)" : "\(item.directory)/\(item.name)"))
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
