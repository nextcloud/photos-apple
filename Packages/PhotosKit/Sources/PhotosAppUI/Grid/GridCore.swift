// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import PhotosCore
import PhotosDomain
import PhotosMedia
import PhotosModel
import PhotosStore

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

// What the AppKit and the UIKit grid do the same way, in one place: which update needs a relayout, the layout of a
// section, the item that keeps its place across a relayout and the offset that puts it back, preview requests, and
// what a tile shows (badges, picture). The two wrappers keep the collection view, its delegates and the drawing.

/// What an update from SwiftUI means for the collection view.
struct GridUpdatePlan: Equatable {
    /// Zoom step or header visibility changed: the layout is invalid.
    var layoutChanged: Bool
    /// The change of the model since the one the grid shows.
    var change: GridModel.Change

    /// The sections are laid out again (and the scroll position restored).
    var relayouts: Bool { layoutChanged || change == .structure }
    /// The data has to be reloaded, not just the layout invalidated.
    var reloads: Bool {
        if case .sections = change { return layoutChanged }
        return change == .structure
    }
    /// The sections to update in place (a batch update of the collection view); `nil` when nothing or everything is.
    var sectionChanges: GridModel.SectionChanges? {
        guard !relayouts, case .sections(let changes) = change else { return nil }
        return changes
    }

    /// - Parameters:
    ///   - revision: revision of the update that came in.
    ///   - shown: revision the grid shows.
    ///   - change: the update's change, which is relative to the revision before it.
    static func plan(revision: Int, shown: Int, change: GridModel.Change, layoutChanged: Bool) -> GridUpdatePlan {
        guard revision != shown else { return GridUpdatePlan(layoutChanged: layoutChanged, change: .none) }
        // After skipped revisions the change says nothing about what the grid shows: everything is reloaded.
        return GridUpdatePlan(layoutChanged: layoutChanged, change: revision == shown + 1 ? change : .structure)
    }
}

/// The selection of a grid as file ids, kept up to date from what the collection view reports as selected and
/// deselected (work in proportion to the change), instead of being rebuilt from every selected index path on each update:
/// with a whole library selected, that rebuild was 150 000 lookups per SwiftUI update.
struct GridSelectionTracker {
    private(set) var ids: Set<FileID> = []

    mutating func insert(_ new: some Sequence<FileID>) { ids.formUnion(new) }
    mutating func remove(_ gone: some Sequence<FileID>) { ids.subtract(gone) }
    mutating func reset(_ ids: Set<FileID>) { self.ids = ids }

    /// Whether the collection view has to be given `selection`. SwiftUI hands back the set the grid reported unless it
    /// changed the selection itself; that comparison is cheap (the same storage). After a model change the selected
    /// items may be at other places (or gone).
    func needsApply(_ selection: Set<FileID>, modelChanged: Bool) -> Bool {
        if modelChanged { return !(selection.isEmpty && ids.isEmpty) }
        return selection != ids
    }
}

/// Sizes of one section of the compositional layout.
struct GridSectionMetrics: Equatable {
    var columns: Int
    /// Side of a tile.
    var side: Double
    var spacing: Double
    /// 0: the section has no header.
    var headerHeight: Double

    /// - Parameter wholePoints: tiles are cut down to whole points (AppKit lays fractional tiles out blurry).
    init(geometry: GridGeometry, headerHeight: Double, wholePoints: Bool) {
        columns = geometry.columns
        side = wholePoints ? geometry.side.rounded(.down) : geometry.side
        spacing = geometry.spacing
        self.headerHeight = headerHeight
    }

    /// Rows of square tiles under a header that stays pinned to the top while its section scrolls.
    @MainActor func layoutSection(headerKind: String) -> NSCollectionLayoutSection {
        let side = CGFloat(side)
        let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .absolute(side), heightDimension: .absolute(side)))
        let rowSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(side))
        #if canImport(UIKit)
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: rowSize, repeatingSubitem: item, count: columns)
        #else
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: rowSize, subitem: item, count: columns)
        #endif
        group.interItemSpacing = .fixed(CGFloat(spacing))
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = CGFloat(spacing)
        if headerHeight > 0 {
            let header = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(CGFloat(headerHeight))),
                elementKind: headerKind, alignment: .top)
            header.pinToVisibleBounds = true
            section.boundarySupplementaryItems = [header]
        }
        return section
    }
}

/// Keeping the scroll position across a relayout (zoom, resize, new sections).
enum GridAnchor {
    /// A tile near the top of the visible area, as the layout has it.
    struct Candidate: Equatable {
        var section: Int
        var item: Int
        /// Lower edge in the document.
        var maxY: Double
    }

    /// The first tile (in reading order) that shows below the pinned header of its section.
    /// - Parameter top: document offset of the top of the visible area (below the bars).
    static func first(of candidates: [Candidate], top: Double, headerHeight: (Int) -> Double) -> (section: Int, item: Int)? {
        var best: (section: Int, item: Int)?
        for candidate in candidates where candidate.maxY > top + headerHeight(candidate.section) + 1 {
            if let current = best, (current.section, current.item) <= (candidate.section, candidate.item) { continue }
            best = (candidate.section, candidate.item)
        }
        return best
    }

    /// Content offset that puts the document offset `documentY` at the top of the visible area, within what can be
    /// scrolled. Offsets start at `-topInset` (the content begins under a bar).
    static func offset(
        documentY: Double, topInset: Double, contentHeight: Double, bottomInset: Double = 0, viewportHeight: Double
    ) -> Double {
        let maxY = max(contentHeight + bottomInset - viewportHeight, -topInset)
        return min(max(documentY - topInset, -topInset), maxY)
    }
}

/// The state of a photo grid that does not depend on the platform: the model it shows, zoom and headers, the item
/// that is kept in place, the size it was last laid out for.
@MainActor
final class GridCore {
    /// Preview request for an item shown at a tile side (points) and a screen scale, in square tiles or not.
    typealias RequestBuilder = @MainActor (_ item: GridMedia, _ tileSide: Double, _ scale: Double, _ square: Bool) -> ImagePipeline.Request

    private let makeRequest: RequestBuilder
    private(set) var model = GridModel.empty
    private(set) var zoomStep = GridColumns.default
    private(set) var showsHeaders = true
    /// Square tiles, or the whole picture fitted into each tile (`TileStyle`).
    private(set) var squareTiles = true
    private var revision = -1
    let headerTexts = GridHeaderTexts()
    /// Header heights; they follow the text size where the platform has one.
    var headerMetrics: GridHeaderMetrics
    /// Item to keep in place across a relayout caused by a new width (window resize, rotation, split view).
    var resizeAnchor: FileID?
    /// Item a restore is still under way for.
    private(set) var pendingAnchor: FileID?
    private var laidOutColumns = 0
    private var laidOutSide = 0.0

    init(headerMetrics: GridHeaderMetrics, previewRequest: @escaping RequestBuilder) {
        self.headerMetrics = headerMetrics
        makeRequest = previewRequest
    }

    convenience init(services: AccountServices, headerMetrics: GridHeaderMetrics) {
        self.init(headerMetrics: headerMetrics) { item, tileSide, scale, square in
            services.previewRequest(for: item, tileSide: tileSide, scale: scale, square: square)
        }
    }

    // MARK: Geometry

    /// Columns and tile side for a width at the current zoom.
    func geometry(width: Double) -> GridGeometry {
        GridColumns.geometry(width: width, step: zoomStep)
    }

    var headersShown: Bool { showsHeaders && model.hasHeaders }

    func headerHeight(section: Int) -> Double {
        guard headersShown, let section = model.sections[safe: section] else { return 0 }
        return headerMetrics.height(for: section)
    }

    func sectionMetrics(_ section: Int, width: Double, wholePoints: Bool) -> GridSectionMetrics {
        GridSectionMetrics(geometry: geometry(width: width), headerHeight: headerHeight(section: section), wholePoints: wholePoints)
    }

    // MARK: Updates

    /// First half of an update: takes zoom, header visibility and tile style over and says what has to happen. The
    /// model is still the old one, so that the anchor can be taken from what is on screen; `show(_:)` is the second half.
    /// Another tile style keeps the cells (they stay squares) but every tile is configured again, also the ones the
    /// collection view has prepared off screen: a reload.
    func begin(_ update: GridFeed.Update, zoomStep: Int, showsHeaders: Bool, squareTiles: Bool = true) -> GridUpdatePlan {
        let styleChanged = squareTiles != self.squareTiles
        let layoutChanged = zoomStep != self.zoomStep || showsHeaders != self.showsHeaders || styleChanged
        var plan = GridUpdatePlan.plan(revision: update.revision, shown: revision, change: update.change, layoutChanged: layoutChanged)
        if styleChanged { plan.change = .structure }
        revision = update.revision
        self.zoomStep = zoomStep
        self.showsHeaders = showsHeaders
        self.squareTiles = squareTiles
        return plan
    }

    /// Second half of an update: the model the grid shows from now on.
    /// - Parameter relayout: the sections changed (or how they are laid out): header texts are formatted anew.
    func show(_ model: GridModel, relayout: Bool) {
        self.model = model
        if relayout { headerTexts.reset() }
    }

    func fileId(at indexPath: IndexPath) -> FileID? {
        model.item(section: indexPath.section, item: indexPath.item)?.fileId
    }

    func indexPath(for id: FileID) -> IndexPath? {
        model.position(of: id).map { IndexPath(item: $0.item, section: $0.section) }
    }

    // MARK: Scroll position

    /// The first item below the pinned header, unless the grid is scrolled to the top (then it stays there).
    /// - Parameters:
    ///   - top: document offset of the top of the visible area.
    ///   - candidates: the tiles in a strip below `top`, from the layout (not from the views on screen, which lag
    ///     behind right after a relayout).
    func anchorItem(isAtTop: Bool, top: Double, candidates: () -> [GridAnchor.Candidate]) -> FileID? {
        if let pendingAnchor { return pendingAnchor }
        guard !isAtTop, !model.isEmpty else { return nil }
        let first = GridAnchor.first(of: candidates(), top: top) { headerHeight(section: $0) }
        return first.flatMap { model.item(section: $0.section, item: $0.item)?.fileId }
    }

    /// Scrolls `anchor` back to the top with `scroll`, now and once more when the layout pass is through (the
    /// collection view may only take its new height then). Until then the anchor stays the same, whatever else is
    /// relaid out in between.
    func restore(_ anchor: FileID?, scroll: @escaping @MainActor (FileID) -> Void) {
        guard let anchor else { return }
        pendingAnchor = anchor
        scroll(anchor)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingAnchor == anchor else { return }
            scroll(anchor)
            self.pendingAnchor = nil
        }
    }

    // MARK: Layout bookkeeping

    /// The column count differs from the one the grid was last laid out with (not on the first layout).
    func columnsChanged(width: Double) -> Bool {
        laidOutColumns != 0 && geometry(width: width).columns != laidOutColumns
    }

    /// The tiles have another size than the previews on screen were requested for.
    func sideChanged(width: Double) -> Bool {
        geometry(width: width).side != laidOutSide
    }

    func noteLayout(width: Double) {
        let geometry = geometry(width: width)
        laidOutColumns = geometry.columns
        laidOutSide = geometry.side
    }

    // MARK: Previews

    /// Requests for the tiles at `indexPaths` (prefetching).
    func previewRequests(at indexPaths: [IndexPath], width: Double, scale: Double) -> [ImagePipeline.Request] {
        let side = geometry(width: width).side
        let square = squareTiles
        return indexPaths.compactMap { model.item(section: $0.section, item: $0.item) }
            .map { makeRequest($0, side, scale, square) }
    }

    /// The request a tile of the grid makes for `item`.
    func previewRequest(for item: GridMedia, width: Double, scale: Double) -> ImagePipeline.Request {
        makeRequest(item, geometry(width: width).side, scale, squareTiles)
    }
}

/// The badges of a tile and its description.
struct GridTileBadges: Equatable {
    /// Duration of a video; nil for photos and videos of unknown length.
    var duration: String?
    var showsVideo: Bool
    var showsFavorite: Bool
    var showsLivePhoto: Bool
    /// From a partner's shared folder (partner sharing, SPEC SH-8).
    var showsPartner: Bool
    /// The lower edge is darkened so the white badges stay readable.
    var showsShade: Bool
    /// The tile stands for several copies of one shot (`TimelineStacking`): a stack badge in the top trailing corner.
    var showsStack = false
    var accessibilityLabel: String

    init(item: GridMedia, isPartner: Bool = false) {
        duration = GridTile.durationText(for: item)
        showsVideo = item.kind == .video
        showsFavorite = item.isFavorite
        showsLivePhoto = item.isLivePhoto
        showsPartner = isPartner
        showsShade = GridTile.showsBottomShade(for: item)
        showsStack = item.stack.count > 1
        accessibilityLabel = GridTile.accessibilityLabel(for: item)
        if showsStack {
            let members: String =
                TimelineStacks.isBurst(leaderName: item.name)
                ? String(localized: "Burst of \(item.stack.count) photos", bundle: .module)
                : String(localized: "\(item.stack.count) copies", bundle: .module)
            accessibilityLabel += ", " + members
        }
        if isPartner { accessibilityLabel += ", " + String(localized: "Partner photo", bundle: .module) }
    }

    /// SF Symbol of the partner badge.
    static let partnerSymbol = "person.2.fill"
}

/// Loads the picture of one tile and says what the tile should show.
///
/// A tile is configured again for the same item when its badges, the zoom or the screen scale change: the picture it
/// shows then stays until a sharper one has loaded (no flash).
@MainActor
final class GridTilePicture {
    enum Display {
        /// Another item: nothing of the old one stays.
        case clear
        /// The BlurHash, until the preview is there.
        case blur(CGImage)
        case picture(CGImage)
        /// No preview to be had (no server preview, broken or unsupported file): an SF Symbol says what the file is.
        case placeholder(symbol: String)
    }

    /// Where pictures come from; the grid uses the account's image pipeline, tests their own.
    struct Source {
        /// The best picture already in memory.
        var cached: @MainActor (GridMedia) -> CGImage?
        var blur: @MainActor (GridMedia) -> CGImage?
        var load: @MainActor (ImagePipeline.Request) async -> CGImage?

        init(
            cached: @escaping @MainActor (GridMedia) -> CGImage?, blur: @escaping @MainActor (GridMedia) -> CGImage?,
            load: @escaping @MainActor (ImagePipeline.Request) async -> CGImage?
        ) {
            self.cached = cached
            self.blur = blur
            self.load = load
        }

        init(services: AccountServices) {
            let images = services.images
            self.init(
                cached: {
                    images.cache.bestMemoryImage(
                        fileId: $0.fileId, etag: images.displayedEtag(fileId: $0.fileId, etag: $0.etag), upTo: 4096)
                },
                blur: { BlurHashCache.image($0.blurhash) },
                load: { await images.preview($0) })
        }
    }

    private(set) var fileId: FileID?
    private(set) var request: ImagePipeline.Request?
    /// A real picture (not just the BlurHash) is shown.
    private(set) var hasPicture = false
    private(set) var isLoading = false
    private var task: Task<Void, Never>?
    /// The tile's drawing.
    var show: (Display) -> Void = { _ in }

    func configure(item: GridMedia, request: ImagePipeline.Request, source: Source) {
        let sameItem = fileId == item.fileId && self.request?.etag == item.etag
        fileId = item.fileId
        if sameItem, request == self.request, hasPicture || isLoading { return }
        task?.cancel()
        self.request = request
        if !sameItem {
            hasPicture = false
            show(.clear)
        }
        if let best = source.cached(item) {
            hasPicture = true
            show(.picture(best))
            // Large enough (for instance after zooming out): nothing to load.
            if GridTile.covers(best, pixels: request.decodeSize) {
                isLoading = false
                return
            }
        } else if !hasPicture, let blur = source.blur(item) {
            show(.blur(blur))
        }
        isLoading = true
        task = Task { [weak self] in
            let image = await source.load(request)
            guard !Task.isCancelled, let self, self.request == request else { return }
            self.isLoading = false
            if let image {
                self.hasPicture = true
                self.show(.picture(image))
            } else if !self.hasPicture {
                self.show(.placeholder(symbol: GridTile.placeholderSymbol(for: item)))
            }
        }
    }

    /// The tile is reused for something else.
    func reset() {
        task?.cancel()
        task = nil
        fileId = nil
        request = nil
        hasPicture = false
        isLoading = false
        show(.clear)
    }
}
