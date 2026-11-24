// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel
import PhotosStore
import Testing

@testable import PhotosAppUI
@testable import PhotosDomain

/// Stacks in the timeline, the viewer's video players, people management and the memories strip.
@MainActor
@Suite struct LibraryExtrasTests {
    let base = Date(timeIntervalSince1970: 1_700_000_000)

    func media(_ id: FileID, _ name: String, at offset: TimeInterval, mime: String = "image/jpeg") -> GridMedia {
        let date = base.addingTimeInterval(-offset)
        return GridMedia(MediaItem(fileId: id, path: "/Photos/\(name)", mimeType: mime, etag: "e\(id)", modifiedAt: date, capturedAt: date))
    }

    // MARK: Stacks

    @Test func theTimelineShowsOneTileForTheCopiesOfAShot() {
        let items = [
            media(1, "A.JPG", at: 0), media(2, "IMG_1.HEIC", at: 10, mime: "image/heic"), media(3, "B.JPG", at: 10.5),
            media(4, "IMG_1.JPG", at: 11), media(5, "C.JPG", at: 100),
        ]
        let collapsed = TimelineStacking.collapse(items)
        // The JPEG is the tile, at the place of the newest copy (the HEIC); the HEIC is behind it.
        #expect(collapsed.map(\.fileId) == [1, 4, 3, 5])
        #expect(collapsed[1].stack == [4, 2])
        #expect(collapsed.filter { $0.fileId != 4 }.allSatisfy { $0.stack.isEmpty })
        #expect(TimelineStacking.stacks(in: collapsed) == [4: [4, 2]])
    }

    @Test func aTimelineWithoutCopiesIsLeftAsItIs() {
        let items = (1...5).map { media(FileID($0), "IMG_\($0).JPG", at: Double($0)) }
        #expect(TimelineStacking.collapse(items) == items)
    }

    @Test func aStackedTileSaysHowManyCopiesItHas() {
        var item = media(4, "IMG_1.JPG", at: 0)
        #expect(!GridTileBadges(item: item).showsStack)
        item.stack = [4, 2]
        let badges = GridTileBadges(item: item)
        #expect(badges.showsStack)
        #expect(badges.accessibilityLabel.hasSuffix("2 copies"))
    }

    @Test func aStackedQueryDeliversStackedResults() async throws {
        let items = [media(1, "IMG_1.HEIC", at: 0, mime: "image/heic"), media(2, "IMG_1.JPG", at: 0)]
        let stream = TimelineStacking.stacked {
            GridStream { continuation in
                continuation.yield(items)
                continuation.finish()
            }
        }()
        var results: [[GridMedia]] = []
        for try await value in stream { results.append(value) }
        #expect(results.map { $0.map(\.fileId) } == [[2]])
    }

    // MARK: Video players

    @Test func onlyTheVideoShownKeepsAPlayer() {
        #expect(VideoRetention.action(isCurrent: true, hasPlayer: false) == .load)
        #expect(VideoRetention.action(isCurrent: true, hasPlayer: true) == .keep)
        // Paged away: the player is let go, not just paused.
        #expect(VideoRetention.action(isCurrent: false, hasPlayer: true) == .release)
        #expect(VideoRetention.action(isCurrent: false, hasPlayer: false) == .release)
    }

    @Test func aVideoShownAgainGoesOnWhereItWasLeft() {
        #expect(VideoRetention.resumePosition(current: 12.5, duration: 60) == 12.5)
        #expect(VideoRetention.resumePosition(current: 0.4, duration: 60) == nil)
        #expect(VideoRetention.resumePosition(current: 59.5, duration: 60) == nil)
        #expect(VideoRetention.resumePosition(current: .nan, duration: nil) == nil)
        #expect(VideoRetention.resumePosition(current: 30, duration: .nan) == 30)
    }

    // MARK: People

    @Test func aPersonsNameIsCheckedBeforeItIsSent() {
        let existing = ["Anna", "Ben", "17"]
        #expect(PersonName.problem("  ", existing: existing) == .empty)
        #expect(PersonName.problem("42", existing: existing) == .numeric)
        #expect(PersonName.problem("anna", existing: existing) == .taken)
        #expect(PersonName.problem("Anna", existing: existing, current: "Anna") == nil)
        #expect(PersonName.problem("Clara", existing: existing) == nil)
    }

    @Test func hiddenPeopleStayHiddenWhenRenamedAndAreKeptInTheAccountFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = HiddenPeople.file(in: folder)
        #expect(HiddenPeople.load(from: file) == HiddenPeople())
        HiddenPeople(names: ["17", "Ben"]).renamed("17", to: "Clara").save(to: file)
        #expect(HiddenPeople.load(from: file).names == ["Clara", "Ben"])
        #expect(HiddenPeople(names: ["Ben"]).renamed("Anna", to: "Clara").names == ["Ben"])
    }

    // MARK: Memories strip

    @Test func theStripShowsOnThisDayThenTheRecapThenTrips() {
        func memory(_ id: String) -> Memory {
            Memory(id: id, kind: .trip, title: id, start: base, end: base, cover: 1, items: [1])
        }
        let snapshot = MemoriesSnapshot(
            onThisDay: [memory("1y"), memory("2y")], trips: (1...20).map { memory("trip\($0)") }, recap: memory("recap"))
        let cards = MemoriesStrip.cards(snapshot)
        #expect(cards.count == MemoriesStrip.limit)
        #expect(cards.prefix(4).map(\.id) == ["1y", "2y", "recap", "trip1"])
        #expect(MemoriesStrip.cards(MemoriesSnapshot()).isEmpty)
    }
}
