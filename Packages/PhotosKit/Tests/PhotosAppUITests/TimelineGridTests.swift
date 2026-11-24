// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import PhotosMedia
import PhotosModel
import PhotosStore
import Testing

@testable import PhotosAppUI
@testable import PhotosDomain

/// Round 4 of the timeline: actions on stacked tiles, bursts in the timeline, the aspect ratio grid and the first sync's
/// skeleton in the grid feed.
@MainActor
@Suite struct TimelineGridTests {
    let base = Date(timeIntervalSince1970: 1_700_000_000)

    func media(_ id: FileID, _ name: String, at offset: TimeInterval, mime: String = "image/jpeg") -> GridMedia {
        let date = base.addingTimeInterval(-offset)
        return GridMedia(MediaItem(fileId: id, path: "/Photos/\(name)", mimeType: mime, etag: "e\(id)", modifiedAt: date, capturedAt: date))
    }

    // MARK: Actions on stacks

    @Test func anActionOnAStackedTileReachesEverythingBehindIt() {
        let stacks: [FileID: [FileID]] = [4: [4, 2], 7: [7, 8, 9]]
        let stack: (FileID) -> [FileID] = { stacks[$0] ?? [] }
        // Each tile, then what is stacked behind it, in the grid's order.
        #expect(StackedSelection.members(of: [1, 4, 7], stack: stack) == [1, 4, 2, 7, 8, 9])
        // A tile without a stack is just itself; nothing twice (a copy that is also selected some other way).
        #expect(StackedSelection.members(of: [3], stack: stack) == [3])
        #expect(StackedSelection.members(of: [2, 4], stack: stack) == [2, 4])
        #expect(StackedSelection.members(of: [], stack: stack).isEmpty)
        // The confirmation counts what the user cannot see.
        #expect(StackedSelection.hiddenCount([1, 4, 2, 7, 8, 9], tiles: [1, 4, 7]) == 3)
        #expect(StackedSelection.hiddenCount([1, 4], tiles: [1, 4]) == 0)
    }

    @Test func theCollapsedTimelineCarriesTheStacksTheActionsExpand() {
        let items = [
            media(1, "IMG_20171007_141256_BURST002.jpg", at: 0), media(2, "IMG_20171007_141256_BURST001_COVER.jpg", at: 0.2),
            media(3, "IMG_7.HEIC", at: 10, mime: "image/heic"), media(4, "IMG_7.JPG", at: 10), media(5, "C.JPG", at: 100),
        ]
        let collapsed = TimelineStacking.collapse(items)
        // The burst shows its cover, at the place of its newest frame; the HEIC + JPEG pair shows the JPEG.
        #expect(collapsed.map(\.fileId) == [2, 4, 5])
        #expect(collapsed[0].stack == [2, 1])
        #expect(collapsed[1].stack == [4, 3])
        let model = GridModel(items: collapsed, sectioning: .flat)
        let all = StackedSelection.members(of: [2, 4, 5]) { model[$0]?.stack ?? [] }
        #expect(all == [2, 1, 4, 3, 5])
        #expect(StackedSelection.hiddenCount(all, tiles: [2, 4, 5]) == 2)
    }

    @Test func aBurstTileSaysItIsABurst() {
        var item = media(2, "IMG_20171007_141256_BURST001_COVER.jpg", at: 0)
        item.stack = [2, 1, 3]
        #expect(GridTileBadges(item: item).accessibilityLabel.hasSuffix("Burst of 3 photos"))
    }

    // MARK: Aspect ratio grid

    @Test func squareTilesAreFilledAndTheAspectRatioGridFitsThePicture() {
        let tile = CGRect(x: 10, y: 20, width: 100, height: 100)
        #expect(GridTile.pictureFrame(in: tile, aspectRatio: 1.5, square: true) == tile)
        // Landscape 3:2: full width, centred vertically.
        #expect(GridTile.pictureFrame(in: tile, aspectRatio: 1.5, square: false) == CGRect(x: 10, y: 36, width: 100, height: 67))
        // Portrait 3:4: full height, centred horizontally.
        #expect(GridTile.pictureFrame(in: tile, aspectRatio: 0.75, square: false) == CGRect(x: 22, y: 20, width: 75, height: 100))
        // Unknown ratio: the square. A panorama is not drawn as a line.
        #expect(GridTile.pictureFrame(in: tile, aspectRatio: 0, square: false) == tile)
        #expect(GridTile.pictureFrame(in: tile, aspectRatio: .nan, square: false) == tile)
        #expect(GridTile.pictureFrame(in: tile, aspectRatio: 40, square: false).height == 20)
    }

    @Test func theAspectRatioGridAsksForSmallerPreviewsOfWidePhotos() {
        let core = GridCore(headerMetrics: GridHeaderMetrics(titleHeight: 26, subtitleHeight: 16)) { item, side, scale, square in
            let pixels = PreviewSizing.neededPixels(tileSide: side, scale: scale, aspectRatio: square ? item.aspectRatio : 1)
            return ImagePipeline.Request(fileId: item.fileId, etag: item.etag, bucket: 1024, maxPixelSize: Int(pixels))
        }
        var wide = media(1, "wide.jpg", at: 0)
        wide.aspectRatio = 2
        let model = GridModel(items: [wide], sectioning: .flat)
        let update = GridFeed.Update(model: model, revision: 1, change: .structure)
        _ = core.begin(update, zoomStep: GridColumns.default, showsHeaders: true)
        core.show(model, relayout: true)
        let side = core.geometry(width: 1000).side
        // Square: the short edge has to cover the tile.
        #expect(core.previewRequest(for: wide, width: 1000, scale: 2).maxPixelSize == Int(side * 2 * 2))
        // Switching the style reloads every tile (also those prepared off screen); the long edge fits the tile.
        let plan = core.begin(update, zoomStep: GridColumns.default, showsHeaders: true, squareTiles: false)
        #expect(plan == GridUpdatePlan(layoutChanged: true, change: .structure))
        #expect(plan.reloads)
        #expect(!core.squareTiles)
        #expect(core.previewRequest(for: wide, width: 1000, scale: 2).maxPixelSize == Int(side * 2))
        #expect(core.previewRequests(at: [IndexPath(item: 0, section: 0)], width: 1000, scale: 2).map(\.maxPixelSize) == [Int(side * 2)])
    }

    // MARK: Skeleton

    @Test func theFeedShowsTheSkeletonUntilTheFirstSyncIsThrough() {
        let feed = GridFeed()
        let skeleton = TimelineSkeleton(months: [202311: 2, 202001: 5])
        feed.setSkeleton(skeleton)
        // Nothing loaded yet: the grid already has the library's shape.
        feed.apply([], flat: false)
        #expect(feed.items.isEmpty)
        #expect(feed.model.hasTiles)
        #expect(feed.model.sections.map(\.tileCount) == [2, 5])
        let revision = feed.update.revision
        // The first sync is over: only what is loaded.
        feed.setSkeleton(nil)
        #expect(feed.update.revision == revision + 1)
        #expect(!feed.model.hasTiles)
        feed.setSkeleton(nil)
        #expect(feed.update.revision == revision + 1)
        // A flat grid (album) never shows one.
        let album = GridFeed()
        album.setSkeleton(skeleton)
        album.apply([media(1, "a.jpg", at: 0)], flat: true)
        #expect(album.model.sections.map(\.placeholders) == [0])
    }
}
