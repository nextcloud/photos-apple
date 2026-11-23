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

/// "Add photos" to an album and the album's toolbar.
@Suite struct AlbumPickerAndToolbarTests {
    /// The search narrows the grid down; what was picked before must stay picked although the grid no longer shows it.
    @Test func picksSurviveASearchThatHidesThem() {
        var shown: Set<FileID> = [1, 2, 3, 4]
        var picked: Set<FileID> = []
        picked = PhotoPicker.merged(picked: picked, isShown: shown.contains, gridSelection: [1, 2])
        #expect(picked == [1, 2])

        // The search leaves 3 and 4: the grid shows nothing as selected and reports its (empty) selection.
        shown = [3, 4]
        #expect(PhotoPicker.shownSelection(picked: picked, isShown: shown.contains).isEmpty)
        picked = PhotoPicker.merged(picked: picked, isShown: shown.contains, gridSelection: [])
        #expect(picked == [1, 2])
        picked = PhotoPicker.merged(picked: picked, isShown: shown.contains, gridSelection: [4])
        #expect(picked == [1, 2, 4])

        // Search cleared: everything picked is selected in the grid again, and deselecting there takes it out.
        shown = [1, 2, 3, 4]
        #expect(PhotoPicker.shownSelection(picked: picked, isShown: shown.contains) == [1, 2, 4])
        picked = PhotoPicker.merged(picked: picked, isShown: shown.contains, gridSelection: [2, 4])
        #expect(picked == [2, 4])
    }

    /// Two "…" menus side by side were the problem: while selecting only the selection's "More" may be one.
    @Test func theAlbumOptionsMenuMakesWayForTheSelection() {
        // iPhone: one menu for everything, gone while selecting.
        #expect(AlbumToolbar.layout(isCompact: true, isSelecting: false, isMac: false) == .singleMenu)
        #expect(AlbumToolbar.layout(isCompact: true, isSelecting: true, isMac: false) == .hidden)
        // iPad: buttons, the options menu hides while selecting.
        #expect(AlbumToolbar.layout(isCompact: false, isSelecting: false, isMac: false) == .buttons(showsOptions: true))
        #expect(AlbumToolbar.layout(isCompact: false, isSelecting: true, isMac: false) == .buttons(showsOptions: false))
        // Mac: a click selects, the album's actions stay reachable; the menus differ by symbol instead.
        #expect(AlbumToolbar.layout(isCompact: false, isSelecting: true, isMac: true) == .buttons(showsOptions: true))
        #if os(macOS)
            #expect(AlbumToolbar.optionsSymbol != "ellipsis.circle")
        #endif
    }

    @Test func theSelectionCountIsTheSubtitle() {
        #expect(GridSelectionState(isSelecting: true, count: 0).title == "Select items")
        #expect(GridSelectionState(isSelecting: true, count: 3).title == "3 selected")
        // Of several grids below a screen, the one that is selecting counts.
        var value = GridSelectionState.Key.defaultValue
        GridSelectionState.Key.reduce(value: &value) { GridSelectionState(isSelecting: true, count: 2) }
        GridSelectionState.Key.reduce(value: &value) { GridSelectionState() }
        #expect(value == GridSelectionState(isSelecting: true, count: 2))
    }
}
