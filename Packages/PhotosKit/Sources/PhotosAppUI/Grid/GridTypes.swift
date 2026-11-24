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
import SwiftUI
import UniformTypeIdentifiers

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
    /// A submenu (Add to Album ▸ …). Menus show these instead of running `handler`; where there are no submenus
    /// (accessibility actions) `handler` offers the same in another way.
    var children: [GridMenuAction] = []
    /// The system's share menu (Mac) or sheet (iPhone, iPad) with these items, instead of `handler`.
    var share: (@MainActor () -> [NSItemProvider])? = nil

    /// The actions without submenus, for accessibility actions: a submenu's entries are actions of their own
    /// ("Add to Album: Holidays"); sharing needs its menu or sheet and is left out.
    static func flattened(_ actions: [GridMenuAction]) -> [GridMenuAction] {
        actions.filter { $0.share == nil }.flatMap { action in
            action.children.isEmpty
                ? [action]
                : action.children.map { child in
                    var entry = child
                    entry.title = "\(action.title): \(child.title)"
                    return entry
                }
        }
    }

    /// The actions split where a group starts (for menus that separate groups by nesting them, as UIKit does).
    static func groups(_ actions: [GridMenuAction]) -> [[GridMenuAction]] {
        var groups: [[GridMenuAction]] = []
        for action in actions {
            if action.startsGroup || groups.isEmpty { groups.append([]) }
            groups[groups.count - 1].append(action)
        }
        return groups
    }
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
    /// The grid went into the selection mode by itself (a two-finger drag over the tiles on iPhone and iPad).
    var beginSelection: @MainActor () -> Void = {}
    /// Pull to refresh on iPhone and iPad; returns when the reload is through. Nil: the grid has no refresh control.
    /// `PhotoGrid` fills it from SwiftUI's `.refreshable` when it is not set.
    var refresh: (@MainActor () async -> Void)?
    /// Says where a tile is, for the zoom transition into the viewer and back (iPhone, iPad). Nil: not needed.
    var tileLocator: GridTileLocator?
    /// Edit ▸ Copy (⌘C) with the selection; nil: the grid does not copy.
    var copy: (@MainActor ([FileID]) -> Void)? = nil
}

/// Where a tile of the grid is on screen; the platform grid fills it in. The zoom transition into the viewer starts from
/// the tile that was tapped and, after paging, goes back to the tile of the photo shown last (iPhone, iPad).
@MainActor
final class GridTileLocator {
    /// The tile's frame in the grid view's own coordinates, nil when the tile is not on screen.
    var frame: (FileID) -> CGRect? = { _ in nil }
    /// Scrolls the grid so the tile is on screen (without animation), so the viewer can zoom back into it.
    var reveal: (FileID) -> Void = { _ in }
}

/// Whether a grid screen is selecting and how many items; screens around `MediaGridScreen` read it as a preference
/// (an album keeps its title and shows the count as subtitle).
struct GridSelectionState: Equatable, Sendable {
    var isSelecting = false
    var count = 0

    /// "Select items" or "3 selected".
    var title: String {
        count == 0 ? String(localized: "Select items", bundle: .module) : String(localized: "\(count) selected", bundle: .module)
    }

    struct Key: PreferenceKey {
        static let defaultValue = GridSelectionState()

        static func reduce(value: inout GridSelectionState, nextValue: () -> GridSelectionState) {
            let next = nextValue()
            if next.isSelecting { value = next }
        }
    }
}

/// Runs one pull-to-refresh at a time and says when it is over (the refresh control spins until then).
@MainActor
final class GridRefreshRunner {
    private(set) var isRunning = false

    /// Starts `action` unless one is running. `finished` is called on the main actor once `action` has returned.
    /// - Returns: false when a refresh was already under way (nothing was started, `finished` is not called).
    @discardableResult
    func run(_ action: @escaping @MainActor () async -> Void, finished: @escaping @MainActor () -> Void) -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        Task { @MainActor [weak self] in
            await action()
            self?.isRunning = false
            finished()
        }
        return true
    }
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
    /// "Video, 22 November 2026 at 14:03, 1 minute, 5 seconds, Favorite". Selection is a trait of the tile, not text.
    static func accessibilityLabel(for item: GridMedia) -> String {
        AccessibilityText.media(
            isVideo: item.kind == .video, isLivePhoto: item.isLivePhoto, date: item.timestamp, duration: item.duration,
            isFavorite: item.isFavorite)
    }

    /// Opacity of the shade under the badges: stronger with Increase Contrast or Reduce Transparency.
    static func shadeOpacity(increased: Bool) -> Double {
        OverlayLegibility.scrimOpacity(base: 0.5, increased: increased)
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

    /// Whether an image already at hand is good enough for a request decoded to `pixels`, so nothing has to be loaded.
    static func covers(_ image: CGImage, pixels: Int) -> Bool {
        Double(max(image.width, image.height)) >= Double(pixels) * 0.9
    }

    /// Side of the selection mark in the bottom trailing corner (iPhone, iPad, Vision Pro): 22 pt, smaller on tiny tiles.
    static func checkmarkSide(tileSide: Double) -> Double {
        min(22, max(12, (tileSide * 0.45).rounded()))
    }

    /// Whether video badge and duration still fit beside the selection mark. They move left of it; on tiles too small
    /// for both, the mark wins while selecting.
    static func showsTrailingBadges(tileSide: Double, checkmarkShown: Bool) -> Bool {
        !checkmarkShown || tileSide >= 88
    }

    /// Where the picture sits in its tile. Square tiles are filled (the picture is cropped to the square). In the
    /// aspect ratio grid (`TileStyle`) the whole picture is fitted into the square, centred, as in Apple Photos' "Aspect
    /// Ratio Grid"; unknown or absurd ratios fall back to the square.
    static func pictureFrame(in tile: CGRect, aspectRatio: Double, square: Bool) -> CGRect {
        guard !square, aspectRatio.isFinite, aspectRatio > 0, tile.width > 0, tile.height > 0 else { return tile }
        let ratio = min(max(aspectRatio, 0.2), 5)
        let tileRatio = Double(tile.width / tile.height)
        var size = tile.size
        if ratio > tileRatio {
            size.height = (tile.width / CGFloat(ratio)).rounded()
        } else {
            size.width = (tile.height * CGFloat(ratio)).rounded()
        }
        return CGRect(
            x: tile.minX + ((tile.width - size.width) / 2).rounded(.down), y: tile.minY + ((tile.height - size.height) / 2).rounded(.down),
            width: size.width, height: size.height)
    }

    /// Size of the context menu's preview: the photo's shape, `longEdge` points on its long edge (UIKit scales it down
    /// to what fits on screen and keeps the shape).
    static func previewSize(aspectRatio: Double, longEdge: Double = 1200) -> CGSize {
        let ratio = aspectRatio.isFinite && aspectRatio > 0 ? min(max(aspectRatio, 0.2), 5) : 1
        return ratio >= 1 ? CGSize(width: longEdge, height: longEdge / ratio) : CGSize(width: longEdge * ratio, height: longEdge)
    }
}

/// Square tiles or the aspect ratio grid (SPEC §6.4). A setting of this device (Settings › On this device, View ›
/// Square Tiles), on by default: the web's `croppedLayout` is not followed, see SPEC §6.4.
enum TileStyle {
    static let squareTilesKey = "squareTiles"
}

/// Dragging photos out of the grid (iPad: into other apps; the Mac grid uses file promises for the same originals).
enum GridDrag {
    /// What a drag that starts on `dragged` carries: the whole selection when the tile is part of it, in the order of
    /// the grid; else just that tile.
    static func ids(dragged: FileID, selection: Set<FileID>, isSelecting: Bool, position: (FileID) -> Int?) -> [FileID] {
        guard isSelecting, selection.contains(dragged), selection.count > 1 else { return [dragged] }
        return selection.sorted { (position($0) ?? .max, $0) < (position($1) ?? .max, $1) }
    }

    /// `@unchecked Sendable`: the completion handler of `NSItemProvider.registerFileRepresentation` is not annotated,
    /// but it is made to be called from wherever the file was produced (here: the download task).
    private struct Completion: @unchecked Sendable {
        let call: (URL?, Bool, (any Error)?) -> Void
    }

    /// The original of `item` as a file that is only downloaded when it is dropped somewhere; inside the app also the
    /// photo itself (`LibraryItemReference`), so an album window adds it instead of uploading a copy.
    static func itemProvider(for item: GridMedia, services: AccountServices) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = item.name
        if let reference = try? LibraryItemReference(account: services.account.id.rawValue, fileId: item.fileId).encoded() {
            provider.registerDataRepresentation(forTypeIdentifier: LibraryItemReference.contentType.identifier, visibility: .ownProcess) {
                completion in
                completion(reference, nil)
                return nil
            }
        }
        let type = UTType(mimeType: item.mimeType) ?? .data
        let fileId = item.fileId
        let name = item.name
        provider.registerFileRepresentation(for: type, visibility: .all, openInPlace: false) { handler in
            let completion = Completion(call: handler)
            let progress = Progress(totalUnitCount: 1)
            let task = Task.detached {
                do {
                    guard let media = try services.library.item(fileId) else { throw CocoaError(.fileNoSuchFile) }
                    let original = try await services.images.originals.original(
                        fileId: media.fileId, etag: media.etag, url: services.originalURL(for: media))
                    // Under its real name for the receiving app; the system copies the file before the handler returns.
                    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: folder) }
                    let named = folder.appending(path: name)
                    try FileManager.default.copyItem(at: original, to: named)
                    progress.completedUnitCount = 1
                    completion.call(named, false, nil)
                } catch {
                    completion.call(nil, false, error)
                }
            }
            progress.cancellationHandler = { task.cancel() }
            return progress
        }
        return provider
    }
}

/// A photo of the library dragged inside the app (iPad: from a grid into an album window): its account and file id. Only
/// this process sees it (`NSItemProvider` visibility `.ownProcess`); other apps get the original file.
struct LibraryItemReference: Codable, Hashable, Sendable {
    var account: String
    var fileId: FileID

    /// Declared in the app's Info.plist (`UTExportedTypeDeclarations`).
    static let contentType = UTType(exportedAs: "com.nextcloud.photos.library-item", conformingTo: .data)

    func encoded() throws -> Data { try JSONEncoder().encode(self) }

    static func decoded(_ data: Data) throws -> LibraryItemReference { try JSONDecoder().decode(LibraryItemReference.self, from: data) }
}

/// What can be dropped on an album: photos of the library dragged from a grid of this app, which are added to the album
/// (the same file, not a copy), or files from other apps and the Finder, which are uploaded into it.
enum AlbumDrop: Transferable {
    case library(LibraryItemReference)
    case file(URL)

    static var transferRepresentation: some TransferRepresentation {
        // First: a drag from the app's own grid also carries the original file, which must not be uploaded again.
        DataRepresentation(importedContentType: LibraryItemReference.contentType) { (data: Data) in
            AlbumDrop.library(try LibraryItemReference.decoded(data))
        }
        ProxyRepresentation(importing: { (url: URL) in AlbumDrop.file(url) })
    }

    /// The file ids of `drops` that belong to `account` (a photo of another account cannot be put in this one's albums)
    /// and the dropped files, in the order they came.
    static func split(_ drops: [AlbumDrop], account: String) -> (fileIds: [FileID], files: [URL]) {
        var fileIds: [FileID] = []
        var files: [URL] = []
        for drop in drops {
            switch drop {
            case .library(let reference):
                if reference.account == account, !fileIds.contains(reference.fileId) { fileIds.append(reference.fileId) }
            case .file(let url): files.append(url)
            }
        }
        return (fileIds, files)
    }
}

/// Builds preview requests for grid tiles.
extension AccountServices {
    /// - Parameters:
    ///   - tileSide: side of the tile in points.
    ///   - scale: backing scale of the window or screen the tile is on.
    ///   - square: the tile crops the picture to a square (its short edge has to cover the tile); in the aspect ratio
    ///     grid the long edge fits the tile.
    func previewRequest(for item: GridMedia, tileSide: Double, scale: Double, square: Bool = true) -> ImagePipeline.Request {
        let pixels = PreviewSizing.neededPixels(tileSide: tileSide, scale: scale, aspectRatio: square ? item.aspectRatio : 1)
        let bucket = PreviewSizing.bucket(forPixels: pixels, buckets: PhotosAPI.previewBuckets)
        return ImagePipeline.Request(
            fileId: item.fileId, etag: item.etag, bucket: bucket,
            hasPreview: item.hasPreview,
            mimeType: item.mimeType,
            originalURL: originalURL(of: item),
            // Decoded at the size the tile shows, not at the size of the bucket (memory stays bounded at any zoom).
            maxPixelSize: PreviewSizing.decodePixels(forPixels: pixels, bucket: bucket))
    }

    /// The preview a context menu shows above its actions: the 1024 px bucket, whatever the tile size.
    func menuPreviewRequest(for item: GridMedia) -> ImagePipeline.Request {
        ImagePipeline.Request(
            fileId: item.fileId, etag: item.etag, bucket: 1024, hasPreview: item.hasPreview, mimeType: item.mimeType,
            originalURL: originalURL(of: item))
    }

    /// The original of a grid item, for a file without a server preview. A file of someone else's shared album has no path
    /// in the user's files (`MediaItem.collectionChildMountType`) and the grid row lacks its child name: no original then.
    func originalURL(of item: GridMedia) -> URL? {
        guard item.directory.hasPrefix("/") else { return nil }
        return connection.filesURL(item.directory == "/" ? "/\(item.name)" : "\(item.directory)/\(item.name)")
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
