// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import PhotosDomain
import PhotosModel
import PhotosStore
import Testing

@testable import PhotosAppUI

/// Range selection, scrub to peek, story cards and moment headers (SPEC §16.1).
@MainActor
@Suite struct LibraryDelightTests {
    func media(_ id: FileID, video: Bool = false) -> GridMedia {
        let date = Date(timeIntervalSince1970: 1_790_000_000 - Double(id) * 60)
        return GridMedia(
            MediaItem(
                fileId: id, path: "/Photos/\(id).\(video ? "mov" : "jpg")", mimeType: video ? "video/quicktime" : "image/jpeg",
                etag: "e\(id)", modifiedAt: date, capturedAt: date))
    }

    // MARK: Range selection

    /// Tiles 0…9 with ids 100…109.
    func id(_ index: Int) -> FileID? { (0..<10).contains(index) ? FileID(100 + index) : nil }

    func apply(_ changes: [(index: Int, selected: Bool)], to selection: inout Set<FileID>) {
        for change in changes {
            if change.selected { selection.insert(id(change.index)!) } else { selection.remove(id(change.index)!) }
        }
    }

    @Test func aDragSelectsTheRangeFromItsStartToTheFinger() {
        var selection: Set<FileID> = [108]
        var range = GridRangeSelection(anchor: 2, anchorId: 102, base: selection)
        #expect(range.selects)
        apply(range.start(id: id), to: &selection)
        #expect(selection == [102, 108])
        apply(range.move(to: 5, id: id), to: &selection)
        #expect(selection == [102, 103, 104, 105, 108])
        #expect(selection == range.selection(id: id))
        // Back towards the start: the tiles it left are as they were before the drag.
        apply(range.move(to: 3, id: id), to: &selection)
        #expect(selection == [102, 103, 108])
        // Past the start, the other way: the range turns round.
        apply(range.move(to: 0, id: id), to: &selection)
        #expect(selection == [100, 101, 102, 108])
        #expect(selection == range.selection(id: id))
    }

    @Test func aDragFromASelectedTileDeselects() {
        var selection: Set<FileID> = [101, 102, 103, 104, 107]
        var range = GridRangeSelection(anchor: 2, anchorId: 102, base: selection)
        #expect(!range.selects)
        apply(range.start(id: id), to: &selection)
        apply(range.move(to: 8, id: id), to: &selection)
        #expect(selection == [101])
        apply(range.move(to: 3, id: id), to: &selection)
        // 107 comes back: it was selected before the drag.
        #expect(selection == [101, 104, 107])
        // Only what changes is reported.
        #expect(range.move(to: 3, id: id).isEmpty)
    }

    @Test func autoscrollGrowsTowardsTheEdges() {
        #expect(GridAutoscroll.speed(y: 300, top: 0, bottom: 800) == 0)
        let slow = GridAutoscroll.speed(y: 800 - 60, top: 0, bottom: 800)
        let fast = GridAutoscroll.speed(y: 800 - 5, top: 0, bottom: 800)
        #expect(slow > 0 && fast > slow)
        #expect(GridAutoscroll.speed(y: 900, top: 0, bottom: 800) == GridAutoscroll.maximumSpeed)
        #expect(GridAutoscroll.speed(y: 100 + 10, top: 100, bottom: 800) < 0)
        // A grid too short for two zones does not scroll.
        #expect(GridAutoscroll.speed(y: 5, top: 0, bottom: 100) == 0)
    }

    // MARK: Scrub to peek

    @Test func peeksAreForVideosLivePhotosAndStacks() {
        #expect(GridPeekKind(media(1)) == nil)
        #expect(GridPeekKind(media(1, video: true)) == .video)
        var live = media(2)
        live.isLivePhoto = true
        #expect(GridPeekKind(live) == .livePhoto)
        var stack = media(3)
        stack.stack = [3, 4, 5]
        #expect(GridPeekKind(stack) == .stack(count: 3))
        #expect(GridPeekKind.stack(count: 3).segments == 3)
        #expect(GridPeekKind.video.segments == 0)
        // A format the system cannot play (the server converts it for the viewer) has nothing to peek into.
        var avi = media(6, video: true)
        avi.mimeType = MimeTypes.unplayableVideos.first ?? "video/x-msvideo"
        #expect(GridPeekKind(avi) == nil)
    }

    @Test func framesAreSpreadOverTheVideoAndLoadedFromTheFinger() {
        #expect(GridPeek.frameTimes(duration: 8, count: 4) == [1, 3, 5, 7])
        #expect(GridPeek.frameTimes(duration: 0, count: 4).isEmpty)
        #expect(GridPeek.index(fraction: 0, count: 8) == 0)
        #expect(GridPeek.index(fraction: 0.5, count: 8) == 4)
        #expect(GridPeek.index(fraction: 1, count: 8) == 7)
        #expect(GridPeek.loadOrder(count: 5, from: 2) == [2, 3, 1, 4, 0])
        #expect(GridPeek.loadOrder(count: 4, from: 9) == [3, 2, 1, 0])
        #expect(GridPeek.nearestLoaded(3, loaded: [true, false, false, false, false, true]) == 5)
        #expect(GridPeek.nearestLoaded(2, loaded: [true, false, false, false, false, false]) == 0)
        #expect(GridPeek.nearestLoaded(2, loaded: [false, false]) == nil)
        let tile = CGRect(x: 100, y: 0, width: 200, height: 200)
        #expect(GridPeek.fraction(x: 150, in: tile) == 0.25)
        #expect(GridPeek.fraction(x: 150, in: tile, rightToLeft: true) == 0.75)
        #expect(GridPeek.fraction(x: 50, in: tile) == 0)
    }

    @Test func aPeekShowsTheNearestFrameThatIsThere() {
        let loader = GridPeekLoader(item: media(1, video: true), kind: .video)
        #expect(loader.frames.count == 8)
        #expect(loader.picture(at: 0.5).image == nil)
        let image = CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        let cached = GridPeekLoader(item: media(1, video: true), kind: .video, cached: [image, nil, nil, nil, nil, nil, nil, nil])
        #expect(cached.picture(at: 0.9).image === image)
        #expect(cached.picture(at: 0.9).index == 7)
        let cache = GridPeekCache()
        cache.store(cached)
        #expect(cache.frames(for: media(1, video: true))?.first ?? nil === image)
        // Nothing loaded: nothing kept.
        cache.store(GridPeekLoader(item: media(2, video: true), kind: .video))
        #expect(cache.frames(for: media(2, video: true)) == nil)
    }

    // MARK: Story cards

    func memory(count: Int) -> Memory {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(year: 2025, month: 11, day: 25, hour: 9))!
        let items = (0..<count).map { MomentItem(fileId: FileID($0 + 1), timestamp: start.addingTimeInterval(Double($0) * 600)) }
        let moment = LibraryMoments.build(items, calendar: calendar)[0]
        return moment.memory(title: "1 year ago")
    }

    @Test func aStoryShowsTheCoverAndPhotosSpreadOverTheMemory() {
        let large = memory(count: 40)
        let photos = MemoryStory.photos(of: large)
        #expect(photos.count == MemoryStory.maximumPhotos)
        #expect(photos.first == large.cover)
        #expect(Set(photos).count == photos.count)
        // In time order after the cover.
        #expect(Array(photos.dropFirst()) == photos.dropFirst().sorted())
        let small = memory(count: 3)
        #expect(MemoryStory.photos(of: small).count == 3)
        #expect(MemoryStory.photos(of: memory(count: 1)).count == 1)
    }

    @Test func tapsStepThroughThePhotosAndOnToTheNextCard() {
        #expect(MemoryStory.step(from: 0, count: 3, forward: true) == .photo(1))
        #expect(MemoryStory.step(from: 2, count: 3, forward: true) == .nextCard)
        #expect(MemoryStory.step(from: 0, count: 3, forward: false) == .previousCard)
        #expect(MemoryStory.isForward(x: 300, width: 400))
        #expect(!MemoryStory.isForward(x: 100, width: 400))
        #expect(MemoryStory.isForward(x: 100, width: 400, rightToLeft: true))
    }

    // MARK: Moment headers

    @Test func dayHeadersCarryTheirMomentTitle() {
        let texts = GridHeaderTexts()
        let day = GridSection(
            id: 20_261_122, kind: .day, date: Date(timeIntervalSince1970: 1_795_000_000), startsMonth: false, year: 2026, range: 0..<3)
        #expect(texts.text(for: day).moment == nil)
        let moments = MomentHeaders(entries: [20_261_122: .init(momentId: "moment-20261122-20261122", title: "Sunday in Lisbon")])
        #expect(texts.setMoments(moments))
        #expect(!texts.setMoments(moments))
        let text = texts.text(for: day)
        #expect(text.moment?.title == "Sunday in Lisbon")
        #expect(text.momentAccessibilityLabel?.hasPrefix("Sunday in Lisbon, ") == true)
        // Months and years never show moments.
        let month = GridSection(
            id: 202_611, kind: .month, date: Date(timeIntervalSince1970: 1_795_000_000), startsMonth: true, year: 2026, range: 0..<3)
        #expect(texts.text(for: month).moment == nil)
    }
}
