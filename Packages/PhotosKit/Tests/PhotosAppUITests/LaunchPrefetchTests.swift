// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel
import PhotosStore
import Testing

@testable import PhotosAppUI
@testable import PhotosDomain

/// The Library's first items and memories read while the window builds its first screen (SPEC §20.6,
/// `LibraryLaunchPrefetch`), and how the grid feed takes them (`GridFeed.seed`).
@MainActor
@Suite struct LaunchPrefetchTests {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let key = LibraryLaunchPrefetch.Key(account: "admin@example.com", excludedFolders: ["/Hidden"], stacksCopies: true)

    func media(_ id: FileID, _ name: String, at offset: TimeInterval) -> GridMedia {
        let date = base.addingTimeInterval(-offset)
        return GridMedia(
            MediaItem(fileId: id, path: "/Photos/\(name)", mimeType: "image/jpeg", etag: "e\(id)", modifiedAt: date, capturedAt: date))
    }

    // A long lifetime: the full suite runs in parallel, and the main actor can come back to a test long after the read.

    var items: [GridMedia] { [media(3, "c.jpg", at: 0), media(2, "b.jpg", at: 3600), media(1, "a.jpg", at: 86_400 * 3)] }

    @Test func theLibraryTakesTheReadOnceAndOnlyForItsQuery() async {
        let prefetch = LibraryLaunchPrefetch(lifetime: .seconds(3600))
        let items = items
        prefetch.start(key, items: { items }, memories: { [] })
        // A second start does not read again.
        prefetch.start(
            key,
            items: {
                Issue.record("read twice")
                return []
            })
        var other = key
        other.excludedFolders = []
        // Another query gets nothing, and the first call gives the read up (a fresh instance shows this).
        let probe = LibraryLaunchPrefetch(lifetime: .seconds(3600))
        probe.start(key, items: { items })
        await probe.readsFinished()
        #expect(probe.take(other) == nil)
        #expect(probe.take(key) == nil, "handed out at most once, also after a mismatch")

        await prefetch.readsFinished()
        let model = prefetch.take(key)
        #expect(model?.items.map(\.fileId) == [3, 2, 1])
        #expect(model?.sectioning == GridFeed.librarySectioning)
        #expect(prefetch.take(key) == nil, "handed out once")
    }

    @Test func aResultThatComesAfterTheLibraryAppearedIsNotKept() async {
        let prefetch = LibraryLaunchPrefetch(lifetime: .seconds(3600))
        let gate = AsyncStream<Void>.makeStream()
        let items = items
        prefetch.start(
            key,
            items: {
                for await _ in gate.stream { break }
                return items
            })
        // The Library appears before the read is done: it observes the store itself.
        #expect(prefetch.take(key) == nil)
        gate.continuation.yield()
        await prefetch.readsFinished()
        #expect(prefetch.peekModel() == nil)
    }

    @Test func memoriesAreHandedOutOnceForTheAccount() async {
        let prefetch = LibraryLaunchPrefetch(lifetime: .seconds(3600))
        let memory = Memory(id: "m", kind: .trip, title: "Lisbon", start: base, end: base, cover: 1, items: [1, 2])
        let items = items
        prefetch.start(key, items: { items }, memories: { [memory] })
        await prefetch.readsFinished()
        #expect(prefetch.takeMemories(account: "someone@else") == nil)
        #expect(prefetch.takeMemories(account: key.account) == nil, "handed out at most once")
        let second = LibraryLaunchPrefetch(lifetime: .seconds(3600))
        second.start(key, items: { items }, memories: { [memory] })
        await second.readsFinished()
        #expect(second.takeMemories(account: key.account)?.map(\.id) == ["m"])
    }

    @Test func aStackedLibraryIsCollapsedLikeTheLiveObservation() async {
        let prefetch = LibraryLaunchPrefetch(lifetime: .seconds(3600))
        // A HEIC and a JPEG of one shot: one tile, as `TimelineStacking.stacked` gives the grid.
        let date = base
        let heic = GridMedia(
            MediaItem(fileId: 10, path: "/Photos/IMG_1.HEIC", mimeType: "image/heic", etag: "h", modifiedAt: date, capturedAt: date))
        let jpeg = GridMedia(
            MediaItem(fileId: 11, path: "/Photos/IMG_1.JPG", mimeType: "image/jpeg", etag: "j", modifiedAt: date, capturedAt: date))
        prefetch.start(key, items: { [heic, jpeg] })
        await prefetch.readsFinished()
        let model = prefetch.take(key)
        #expect(model?.items.map(\.fileId) == TimelineStacking.collapse([heic, jpeg]).map(\.fileId))
    }

    @Test func theFeedShowsASeedAndTheSameFirstObservationChangesNothing() {
        let feed = GridFeed()
        feed.seed(GridModel(items: items, sectioning: GridFeed.librarySectioning))
        #expect(feed.loaded)
        #expect(feed.items.map(\.fileId) == [3, 2, 1])
        let revision = feed.update.revision
        feed.apply(items, flat: false)
        #expect(feed.update.revision == revision, "an equal first result is not a new update")
        // New items from the observation replace the seed.
        feed.apply([media(4, "d.jpg", at: -60)] + items, flat: false)
        #expect(feed.items.map(\.fileId) == [4, 3, 2, 1])
        // A feed that has items already ignores a late seed.
        feed.seed(GridModel(items: Array(items.prefix(1)), sectioning: GridFeed.librarySectioning))
        #expect(feed.items.count == 4)
    }

    @Test func aSeedFollowsTheZoomTheGridAlreadyHas() {
        let feed = GridFeed()
        feed.setGranularity(.month)
        feed.seed(GridModel(items: items, sectioning: GridFeed.librarySectioning))
        #expect(feed.model.sectioning == .timeline(.month))
    }
}
