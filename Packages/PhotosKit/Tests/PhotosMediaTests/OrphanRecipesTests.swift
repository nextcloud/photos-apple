// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel
import PhotosNetworking
import PhotosStore
import Synchronization
import Testing

@testable import PhotosMedia

/// What the server says about the photos of recipes, set by each test.
final class FakeOrphanProbe: OrphanRecipeProbe {
    struct State {
        var existing: Set<FileID> = []
        var trashed: Set<FileID> = []
        var fails = false
        var asked: [[FileID]] = []
        var trashLooks = 0
    }

    let state = Mutex(State())

    func existing(_ fileIds: [FileID]) async throws -> Set<FileID> {
        try state.withLock { state in
            if state.fails { throw NetworkError.offline }
            state.asked.append(fileIds)
            return state.existing.intersection(fileIds)
        }
    }

    func trashed() async throws -> Set<FileID> {
        try state.withLock { state in
            if state.fails { throw NetworkError.offline }
            state.trashLooks += 1
            return state.trashed
        }
    }
}

/// Recipes of photos deleted for good are removed after a full reconcile (SPEC §22.5.3); recipes of photos in the trash
/// bin, moved elsewhere, changed meanwhile or not sent yet never are.
@Suite(.timeLimit(.minutes(1))) struct OrphanRecipesTests {
    let server = EditDAVServer()
    let probe = FakeOrphanProbe()
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let day: TimeInterval = 86_400

    /// A library with recipes for these photos, all on the server.
    func library(_ fileIds: [FileID]) async -> EditLibrary {
        let library = server.library()
        for fileId in fileIds { await library.save(EditLibraryTests.recipe(exposure: 0.5, at: 1000 + Double(fileId)), for: fileId) }
        await library.waitUntilIdle()
        return library
    }

    @Test func onlyThePhotoGoneEverywhereLosesItsRecipeAfterTheGracePeriod() async throws {
        // 1 in the index, 2 moved out of the timeline folders, 3 in the trash bin, 4 deleted for good.
        let library = await library([1, 2, 3, 4])
        probe.state.withLock {
            $0.existing = [1, 2]
            $0.trashed = [3]
        }
        let indexed: @Sendable (Set<FileID>) -> Set<FileID> = { $0.intersection([1]) }
        var report = await library.removeOrphans(probe: probe, indexed: indexed, now: t0)
        #expect(report.candidates == 3)
        #expect(report.waiting == 1)
        #expect(report.removed.isEmpty)
        #expect(server.file(4) != nil)
        // The index's photos are not asked about.
        #expect(probe.state.withLock { $0.asked } == [[2, 3, 4]])
        // Within a day: not looked at again.
        report = await library.removeOrphans(probe: probe, indexed: indexed, now: t0.addingTimeInterval(3600))
        #expect(report.skipped)
        report = await library.removeOrphans(probe: probe, indexed: indexed, now: t0.addingTimeInterval(29 * day))
        #expect(report.removed.isEmpty)
        report = await library.removeOrphans(probe: probe, indexed: indexed, now: t0.addingTimeInterval(31 * day))
        #expect(report.removed == [4])
        #expect(server.file(4) == nil)
        #expect(library.recipe(for: 4) == nil)
        for kept: FileID in [1, 2, 3] {
            #expect(server.file(kept) != nil)
            #expect(library.recipe(for: kept) != nil)
        }
        #expect(server.log.contains { $0.hasPrefix("DELETE /.nextcloud-photos/edits/4.json match:") })
    }

    @Test func aPhotoRestoredFromTheTrashInBetweenStartsOver() async throws {
        let library = await library([5])
        let indexed: @Sendable (Set<FileID>) -> Set<FileID> = { _ in [] }
        await library.removeOrphans(probe: probe, indexed: indexed, now: t0)
        // Restored and deleted again: the mark is gone, the grace period starts again.
        probe.state.withLock { $0.existing = [5] }
        await library.removeOrphans(probe: probe, indexed: indexed, now: t0.addingTimeInterval(2 * day))
        probe.state.withLock { $0.existing = [] }
        await library.removeOrphans(probe: probe, indexed: indexed, now: t0.addingTimeInterval(4 * day))
        let report = await library.removeOrphans(probe: probe, indexed: indexed, now: t0.addingTimeInterval(31 * day))
        #expect(report.removed.isEmpty)
        #expect(report.waiting == 1)
        #expect(server.file(5) != nil)
    }

    @Test func anUnansweredLookRemovesNothingAndKeepsTheMarks() async throws {
        let library = await library([6])
        let indexed: @Sendable (Set<FileID>) -> Set<FileID> = { _ in [] }
        await library.removeOrphans(probe: probe, indexed: indexed, now: t0)
        probe.state.withLock { $0.fails = true }
        let failed = await library.removeOrphans(probe: probe, indexed: indexed, now: t0.addingTimeInterval(31 * day))
        #expect(failed.removed.isEmpty)
        #expect(server.file(6) != nil)
        // The next day the server answers: the mark from the first look still counts.
        probe.state.withLock { $0.fails = false }
        let answered = await library.removeOrphans(probe: probe, indexed: indexed, now: t0.addingTimeInterval(32 * day))
        #expect(answered.removed == [6])
    }

    @Test func aRecipeChangedOrNotYetSentIsKept() async throws {
        let library = await library([7])
        let indexed: @Sendable (Set<FileID>) -> Set<FileID> = { _ in [] }
        await library.removeOrphans(probe: probe, indexed: indexed, now: t0)
        // Another device changed the recipe on the server since this one read it: the DELETE's If-Match fails.
        server.state.withLock { state in
            state.counter += 1
            state.files["/.nextcloud-photos/edits/7.json"]?.etag = "other\(state.counter)"
        }
        var report = await library.removeOrphans(probe: probe, indexed: indexed, now: t0.addingTimeInterval(31 * day))
        #expect(report.removed.isEmpty)
        #expect(server.file(7) != nil)
        // A recipe saved here while offline is not looked at.
        server.setOffline(true)
        await library.save(EditLibraryTests.recipe(exposure: 0.2, at: 9000), for: 8)
        server.setOffline(false)
        report = await library.removeOrphans(probe: probe, indexed: indexed, now: t0.addingTimeInterval(60 * day))
        #expect(!report.removed.contains(8))
        #expect(library.recipe(for: 8) != nil)
    }

    @Test func noCandidatesNoQuestions() async throws {
        let library = await library([9])
        let report = await library.removeOrphans(probe: probe, indexed: { $0 }, now: t0)
        #expect(report == EditLibrary.OrphanReport())
        #expect(probe.state.withLock { $0.asked.isEmpty && $0.trashLooks == 0 })
    }
}
