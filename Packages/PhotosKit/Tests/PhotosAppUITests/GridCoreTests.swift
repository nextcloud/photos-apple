// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import PhotosDomain
import PhotosMedia
import PhotosModel
import PhotosStore
import Testing

@testable import PhotosAppUI

/// The platform-neutral half of the photo grid that the AppKit and the UIKit wrapper share.
@MainActor
@Suite struct GridCoreTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()

    func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    func media(_ id: FileID, _ date: Date, favorite: Bool = false, video: Bool = false, etag: String? = nil) -> GridMedia {
        GridMedia(
            MediaItem(
                fileId: id, path: "/Photos/\(id).\(video ? "mov" : "jpg")", mimeType: video ? "video/quicktime" : "image/jpeg",
                etag: etag ?? "e\(id)", modifiedAt: date, capturedAt: date, isFavorite: favorite))
    }

    /// Three days: 5 + 2 + 1 items.
    var model: GridModel {
        let items =
            (1...5).map { media($0, date(2026, 11, 22)) } + (6...7).map { media($0, date(2026, 11, 3)) } + [media(8, date(2026, 10, 31))]
        return GridModel(items: items, sectioning: .timeline(.day), calendar: calendar)
    }

    func core() -> GridCore {
        GridCore(headerMetrics: GridHeaderMetrics(titleHeight: 26, subtitleHeight: 16)) { item, side, scale in
            ImagePipeline.Request(fileId: item.fileId, etag: item.etag, bucket: 256, maxPixelSize: Int(side * scale))
        }
    }

    func update(_ model: GridModel, revision: Int, change: GridModel.Change) -> GridFeed.Update {
        GridFeed.Update(model: model, revision: revision, change: change)
    }

    // MARK: Update plan

    @Test func aChangeOnlyCountsForTheRevisionRightBeforeIt() {
        let favourite = GridModel.Change.content([3])
        #expect(GridUpdatePlan.plan(revision: 5, shown: 4, change: favourite, layoutChanged: false).change == favourite)
        // Skipped revisions: what changed in between is unknown, so everything is reloaded.
        #expect(GridUpdatePlan.plan(revision: 6, shown: 4, change: favourite, layoutChanged: false).change == .structure)
        // The same revision again (SwiftUI updates the view for other reasons): nothing to do.
        let same = GridUpdatePlan.plan(revision: 4, shown: 4, change: .structure, layoutChanged: false)
        #expect(same.change == .none)
        #expect(!same.relayouts)
        // A zoom step relays out without reloading.
        let zoom = GridUpdatePlan.plan(revision: 4, shown: 4, change: .none, layoutChanged: true)
        #expect(zoom.relayouts)
        #expect(!zoom.reloads)
        #expect(GridUpdatePlan.plan(revision: 5, shown: 4, change: .structure, layoutChanged: false).reloads)

        // An upload: the sections are updated in place, nothing is reloaded or laid out from scratch.
        let upload = GridModel.Change.sections(.init(inserted: [0], reloaded: [0]))
        let batch = GridUpdatePlan.plan(revision: 5, shown: 4, change: upload, layoutChanged: false)
        #expect(!batch.relayouts && !batch.reloads)
        #expect(batch.sectionChanges == .init(inserted: [0], reloaded: [0]))
        // With a zoom step at the same time the counts change under a new layout: reload.
        let zoomed = GridUpdatePlan.plan(revision: 5, shown: 4, change: upload, layoutChanged: true)
        #expect(zoomed.relayouts && zoomed.reloads && zoomed.sectionChanges == nil)
        // After skipped revisions it is a reload too.
        #expect(GridUpdatePlan.plan(revision: 6, shown: 4, change: upload, layoutChanged: false).reloads)
    }

    /// The selection is kept from the grid's own changes; handing the same set back costs no work, and only a real change
    /// (or a new model, where the selected items may have moved) is applied to the collection view.
    @Test func selectionTrackerAppliesOnlyRealChanges() {
        var tracker = GridSelectionTracker()
        #expect(!tracker.needsApply([], modelChanged: false))
        #expect(!tracker.needsApply([], modelChanged: true))
        let all = Set((1...150_000).map { FileID($0) })
        tracker.insert(all)
        let reported = tracker.ids
        #expect(!tracker.needsApply(reported, modelChanged: false))
        #expect(tracker.needsApply(reported, modelChanged: true))
        tracker.remove([7])
        #expect(tracker.ids.count == 149_999)
        #expect(tracker.needsApply(reported, modelChanged: false))
        tracker.reset([])
        #expect(tracker.needsApply(reported, modelChanged: false))
    }

    @Test func anUpdateIsTakenOverInTwoHalves() {
        let core = core()
        let first = core.begin(update(model, revision: 1, change: .structure), zoomStep: GridColumns.default, showsHeaders: true)
        // The first update skips revision 0: reload. The old (empty) model is still there for the anchor.
        #expect(first.reloads)
        #expect(core.model.isEmpty)
        core.show(model, relayout: true)
        #expect(core.model.count == 8)
        #expect(core.headersShown)

        let zoomed = core.begin(update(model, revision: 1, change: .structure), zoomStep: GridColumns.options[0], showsHeaders: true)
        #expect(zoomed == GridUpdatePlan(layoutChanged: true, change: .none))
        #expect(core.zoomStep == GridColumns.options[0])

        let hidden = core.begin(update(model, revision: 2, change: .content([2])), zoomStep: GridColumns.options[0], showsHeaders: false)
        #expect(hidden == GridUpdatePlan(layoutChanged: true, change: .content([2])))
        #expect(!core.headersShown)
        #expect(core.headerHeight(section: 0) == 0)
    }

    // MARK: Layout

    @Test func sectionMetricsFollowWidthZoomAndHeaders() {
        let core = core()
        _ = core.begin(update(model, revision: 1, change: .structure), zoomStep: GridColumns.default, showsHeaders: true)
        core.show(model, relayout: true)
        let width = 1001.0
        let geometry = core.geometry(width: width)
        let exact = core.sectionMetrics(0, width: width, wholePoints: false)
        #expect(exact.columns == geometry.columns)
        #expect(exact.side == geometry.side)
        #expect(exact.spacing == geometry.spacing)
        // 22 November starts a month: title and day. 3 November does not: only the day.
        #expect(exact.headerHeight == 10 + 26 + 2 + 16 + 6)
        #expect(core.sectionMetrics(1, width: width, wholePoints: false).headerHeight == 10 + 16 + 6)
        // AppKit gets whole points.
        let whole = core.sectionMetrics(0, width: width, wholePoints: true)
        #expect(whole.side == geometry.side.rounded(.down))
        #expect(whole.side != geometry.side)
        // A section that does not exist has no header.
        #expect(core.sectionMetrics(9, width: width, wholePoints: true).headerHeight == 0)
    }

    @Test func layoutBookkeepingSeesNewColumnsAndTileSizes() {
        let core = core()
        // Nothing laid out yet: a first layout is not a change of columns, but the tiles need their previews.
        #expect(!core.columnsChanged(width: 1000))
        #expect(core.sideChanged(width: 1000))
        core.noteLayout(width: 1000)
        #expect(!core.columnsChanged(width: 1000))
        #expect(!core.sideChanged(width: 1000))
        // A few points wider: same columns, larger tiles.
        #expect(!core.columnsChanged(width: 1010))
        #expect(core.sideChanged(width: 1010))
        #expect(core.columnsChanged(width: 500))
    }

    // MARK: Anchor

    @Test func theAnchorIsTheFirstTileBelowThePinnedHeader() {
        let header: (Int) -> Double = { $0 == 0 ? 60 : 32 }
        let candidates = [
            // Row hidden under the pinned header of section 0 (ends at 150, header reaches to 100 + 60).
            GridAnchor.Candidate(section: 0, item: 0, maxY: 150),
            GridAnchor.Candidate(section: 0, item: 1, maxY: 150),
            // Next row shows; the layout does not hand the tiles over in order.
            GridAnchor.Candidate(section: 0, item: 5, maxY: 290),
            GridAnchor.Candidate(section: 0, item: 4, maxY: 290),
            GridAnchor.Candidate(section: 1, item: 0, maxY: 460),
        ]
        let first = GridAnchor.first(of: candidates, top: 100, headerHeight: header)
        #expect(first?.section == 0)
        #expect(first?.item == 4)
        #expect(GridAnchor.first(of: [], top: 100, headerHeight: header) == nil)
        // Exactly at the header's edge is still hidden.
        #expect(GridAnchor.first(of: [GridAnchor.Candidate(section: 0, item: 0, maxY: 161)], top: 100, headerHeight: header) == nil)
    }

    @Test func theGridStaysAtTheTopAndKeepsAnAnchorWhileItIsRestored() async {
        let core = core()
        _ = core.begin(update(model, revision: 1, change: .structure), zoomStep: GridColumns.default, showsHeaders: true)
        core.show(model, relayout: true)
        let candidates = [GridAnchor.Candidate(section: 1, item: 1, maxY: 900)]
        // At the top there is nothing to keep: new photos may push the old ones down.
        #expect(core.anchorItem(isAtTop: true, top: 0) { candidates } == nil)
        #expect(core.anchorItem(isAtTop: false, top: 500) { candidates } == 7)

        var scrolls: [FileID] = []
        core.restore(7) { scrolls.append($0) }
        #expect(scrolls == [7])
        // A second relayout before the first restore is through keeps the same item, whatever is on screen now.
        #expect(core.anchorItem(isAtTop: false, top: 0) { [GridAnchor.Candidate(section: 0, item: 0, maxY: 500)] } == 7)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        // Restored once more after the layout pass, then the anchor is free again.
        #expect(scrolls == [7, 7])
        #expect(core.pendingAnchor == nil)
        core.restore(nil) { scrolls.append($0) }
        #expect(scrolls == [7, 7])
    }

    @Test func theRestoredOffsetStaysWithinWhatCanBeScrolled() {
        // Mac: the document starts under a 52 pt toolbar.
        #expect(GridAnchor.offset(documentY: 1000, topInset: 52, contentHeight: 5000, viewportHeight: 800) == 948)
        #expect(GridAnchor.offset(documentY: -30, topInset: 52, contentHeight: 5000, viewportHeight: 800) == -52)
        #expect(GridAnchor.offset(documentY: 4900, topInset: 52, contentHeight: 5000, viewportHeight: 800) == 4200)
        // Content shorter than the view: it stays at the top.
        #expect(GridAnchor.offset(documentY: 200, topInset: 52, contentHeight: 300, viewportHeight: 800) == -52)
        // iOS: the bottom inset (tab bar, home indicator) can be scrolled into.
        #expect(GridAnchor.offset(documentY: 4900, topInset: 100, contentHeight: 5000, bottomInset: 34, viewportHeight: 800) == 4234)
    }

    // MARK: Previews

    @Test func prefetchRequestsAreBuiltForTheTilesSizeOnScreen() {
        let core = core()
        _ = core.begin(update(model, revision: 1, change: .structure), zoomStep: GridColumns.default, showsHeaders: true)
        core.show(model, relayout: true)
        let paths = [IndexPath(item: 4, section: 0), IndexPath(item: 1, section: 1), IndexPath(item: 7, section: 2)]
        let requests = core.previewRequests(at: paths, width: 1000, scale: 2)
        // The path outside the model is skipped.
        #expect(requests.map(\.fileId) == [5, 7])
        #expect(requests.allSatisfy { $0.maxPixelSize == Int(core.geometry(width: 1000).side * 2) })
        #expect(core.fileId(at: paths[1]) == 7)
        #expect(core.indexPath(for: 8) == IndexPath(item: 0, section: 2))
        #expect(core.indexPath(for: 99) == nil)
    }

    // MARK: Tiles

    @Test func badgesSayWhatATileIs() {
        let photo = GridTileBadges(item: media(1, date(2026, 11, 22)))
        #expect(photo.duration == nil)
        #expect(!photo.showsVideo && !photo.showsFavorite && !photo.showsLivePhoto && !photo.showsShade)
        #expect(!photo.accessibilityLabel.isEmpty)

        let favourite = GridTileBadges(item: media(2, date(2026, 11, 22), favorite: true))
        #expect(favourite.showsFavorite && favourite.showsShade)

        var clip = media(3, date(2026, 11, 22), video: true)
        clip.duration = 65
        let video = GridTileBadges(item: clip)
        #expect(video.showsVideo && video.showsShade)
        #expect(video.duration == Formatters.duration(65))
        // A video of unknown length only has the video badge.
        clip.duration = nil
        #expect(GridTileBadges(item: clip).duration == nil)
    }

    func image(_ side: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    /// What a tile was told to show, as text.
    @MainActor final class Recorder {
        var shown: [String] = []
        var loads = 0
        var cached: CGImage?
        var blur: CGImage?
        var result: CGImage?
        var gate: AsyncStream<Void>.Continuation?

        func attach(to picture: GridTilePicture) {
            picture.show = { [unowned self] display in
                switch display {
                case .clear: shown.append("clear")
                case .blur: shown.append("blur")
                case .picture(let image): shown.append("picture \(image.width)")
                case .placeholder(let symbol): shown.append("placeholder \(symbol)")
                }
            }
        }

        var source: GridTilePicture.Source {
            GridTilePicture.Source(
                cached: { [unowned self] _ in cached }, blur: { [unowned self] _ in blur },
                load: { [unowned self] _ in
                    loads += 1
                    let (stream, continuation) = AsyncStream<Void>.makeStream()
                    gate = continuation
                    for await _ in stream { break }
                    return result
                })
        }

        /// Lets the running load return and waits until the tile has handled it.
        func finishLoad() async {
            for _ in 0..<50 where gate == nil { await Task.yield() }
            gate?.yield()
            gate = nil
            for _ in 0..<50 { await Task.yield() }
        }
    }

    func request(_ item: GridMedia, pixels: Int) -> ImagePipeline.Request {
        ImagePipeline.Request(fileId: item.fileId, etag: item.etag, bucket: 1024, maxPixelSize: pixels)
    }

    @Test func aTileShowsTheBlurThenThePreviewAndKeepsItWhileASharperOneLoads() async {
        let picture = GridTilePicture()
        let recorder = Recorder()
        recorder.attach(to: picture)
        recorder.blur = image(8)
        recorder.result = image(256)
        let item = media(1, date(2026, 11, 22))

        picture.configure(item: item, request: request(item, pixels: 256), source: recorder.source)
        #expect(recorder.shown == ["clear", "blur"])
        #expect(picture.isLoading && !picture.hasPicture)
        // The same request again (badges changed): the running load is enough.
        picture.configure(item: item, request: request(item, pixels: 256), source: recorder.source)
        await recorder.finishLoad()
        #expect(recorder.loads == 1)
        #expect(recorder.shown == ["clear", "blur", "picture 256"])
        #expect(picture.hasPicture && !picture.isLoading)

        // Zoomed in: the picture stays (no "clear", no blur) until the sharper one is there.
        recorder.result = image(512)
        picture.configure(item: item, request: request(item, pixels: 512), source: recorder.source)
        #expect(recorder.shown == ["clear", "blur", "picture 256"])
        await recorder.finishLoad()
        #expect(recorder.shown.last == "picture 512")
        #expect(recorder.loads == 2)
    }

    @Test func aPictureInMemoryThatIsLargeEnoughIsNotLoadedAgain() async {
        let picture = GridTilePicture()
        let recorder = Recorder()
        recorder.attach(to: picture)
        recorder.cached = image(512)
        let item = media(1, date(2026, 11, 22))
        // Zoomed out: the 512 px picture covers a 256 px tile.
        picture.configure(item: item, request: request(item, pixels: 256), source: recorder.source)
        for _ in 0..<20 { await Task.yield() }
        #expect(recorder.shown == ["clear", "picture 512"])
        #expect(recorder.loads == 0)
        #expect(!picture.isLoading)

        // Too small for a 1024 px tile: shown at once, the sharp one is loaded.
        let other = media(2, date(2026, 11, 22))
        recorder.result = image(1024)
        picture.configure(item: other, request: request(other, pixels: 1024), source: recorder.source)
        #expect(recorder.shown == ["clear", "picture 512", "clear", "picture 512"])
        await recorder.finishLoad()
        #expect(recorder.shown.last == "picture 1024")
    }

    @Test func aFileWithoutPreviewGetsAGlyphAndAReusedTileForgetsItsLoad() async {
        let picture = GridTilePicture()
        let recorder = Recorder()
        recorder.attach(to: picture)
        let clip = media(3, date(2026, 11, 22), video: true)
        picture.configure(item: clip, request: request(clip, pixels: 256), source: recorder.source)
        await recorder.finishLoad()
        #expect(recorder.shown == ["clear", "placeholder video"])

        // Reused while a load runs: the late result of the old item must not be shown.
        let photo = media(4, date(2026, 11, 22))
        recorder.result = image(256)
        picture.configure(item: photo, request: request(photo, pixels: 256), source: recorder.source)
        for _ in 0..<50 where recorder.gate == nil { await Task.yield() }
        picture.reset()
        #expect(picture.fileId == nil)
        await recorder.finishLoad()
        #expect(recorder.shown == ["clear", "placeholder video", "clear", "clear"])
    }
}
