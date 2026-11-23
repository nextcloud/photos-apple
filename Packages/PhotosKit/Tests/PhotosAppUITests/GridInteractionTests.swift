// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import PhotosModel
import Testing

@testable import PhotosAppUI

/// Pull to refresh, drag and the selection mark of the grid: the parts that do not need a collection view.
@MainActor
@Suite struct GridInteractionTests {
    /// The refresh control must spin until the screen's refresh (a sync) has returned, not just until it was started.
    @Test func aRefreshEndsWhenItsActionHasReturned() async {
        let runner = GridRefreshRunner()
        let (gate, open) = AsyncStream<Void>.makeStream()
        var finished = false
        let (done, signalDone) = AsyncStream<Void>.makeStream()
        let started = runner.run {
            for await _ in gate { break }
        } finished: {
            finished = true
            signalDone.yield()
        }
        #expect(started)
        await Task.yield()
        #expect(runner.isRunning)
        #expect(!finished)

        open.yield()
        for await _ in done { break }
        #expect(finished)
        #expect(!runner.isRunning)
    }

    @Test func aSecondPullWhileRefreshingStartsNothing() async {
        let runner = GridRefreshRunner()
        let (gate, open) = AsyncStream<Void>.makeStream()
        let (done, signalDone) = AsyncStream<Void>.makeStream()
        var runs = 0
        var endings = 0
        let action: @MainActor () async -> Void = {
            runs += 1
            for await _ in gate { break }
        }
        #expect(runner.run(action) { endings += 1; signalDone.yield() })
        #expect(!runner.run(action) { endings += 1 })
        open.yield()
        for await _ in done { break }
        #expect(runs == 1)
        #expect(endings == 1)
        // The next pull works again.
        #expect(runner.run({}) {})
    }

    @Test func aDragCarriesTheTileOrTheSelectionItBelongsTo() {
        let order: [FileID] = [30, 10, 20, 40]
        let position: (FileID) -> Int? = { order.firstIndex(of: $0) }
        // Not selecting: only the dragged tile, whatever is selected.
        #expect(GridDrag.ids(dragged: 10, selection: [10, 20], isSelecting: false, position: position) == [10])
        // Dragging a tile outside the selection leaves the selection alone.
        #expect(GridDrag.ids(dragged: 40, selection: [10, 20], isSelecting: true, position: position) == [40])
        // A selected tile takes the selection along, in the order of the grid.
        #expect(GridDrag.ids(dragged: 20, selection: [20, 30, 10], isSelecting: true, position: position) == [30, 10, 20])
        // Items the grid no longer has go last instead of getting lost.
        #expect(GridDrag.ids(dragged: 20, selection: [20, 99], isSelecting: true, position: position) == [20, 99])
    }

    @Test func theSelectionMarkShrinksOnSmallTilesAndBadgesMakeRoom() {
        #expect(GridTile.checkmarkSide(tileSide: 120) == 22)
        #expect(GridTile.checkmarkSide(tileSide: 28) == 13)
        #expect(GridTile.checkmarkSide(tileSide: 10) == 12)
        // Without the mark the badges are always there; beside it only when the tile is wide enough for both.
        #expect(GridTile.showsTrailingBadges(tileSide: 28, checkmarkShown: false))
        #expect(!GridTile.showsTrailingBadges(tileSide: 76, checkmarkShown: true))
        #expect(GridTile.showsTrailingBadges(tileSide: 120, checkmarkShown: true))
    }

    @Test func theMenuPreviewHasTheShapeOfThePhoto() {
        #expect(GridTile.previewSize(aspectRatio: 1.5, longEdge: 1200) == CGSize(width: 1200, height: 800))
        #expect(GridTile.previewSize(aspectRatio: 0.75, longEdge: 1200) == CGSize(width: 900, height: 1200))
        // Unknown or absurd sizes do not give a sliver.
        #expect(GridTile.previewSize(aspectRatio: 0, longEdge: 1200) == CGSize(width: 1200, height: 1200))
        #expect(GridTile.previewSize(aspectRatio: .nan, longEdge: 1200) == CGSize(width: 1200, height: 1200))
        #expect(GridTile.previewSize(aspectRatio: 40, longEdge: 1000) == CGSize(width: 1000, height: 200))
    }
}
