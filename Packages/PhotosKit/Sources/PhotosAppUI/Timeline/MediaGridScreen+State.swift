// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosStore
import SwiftUI

extension MediaGridScreen {
    /// The hero as the grid hosts it, telling this screen when its title went under the bar.
    var gridHero: GridHero? {
        guard GridHero.isSupported, var hero else { return nil }
        hero.collapsedChanged = { (collapsed: Bool) in heroCollapsed = collapsed }
        return hero
    }

    /// The hero is in view with its title, or about to come with the photos: the bar shows none (while selecting it
    /// shows the count; an empty grid has no hero and the bar keeps its title).
    var heroShowsTitle: Bool {
        gridHero != nil && !heroCollapsed && !isSelecting && (feed.model.hasTiles || !feed.loaded)
    }

    /// A tap on a moment's title in a day header (SPEC §16.1).
    var momentOpener: (@MainActor (String) -> Void)? {
        guard let openMoment else { return nil }
        let opener: @MainActor (String) -> Void = { (id: String) in openMoment(id) }
        return opener
    }

    /// Opens the viewer from a tile, which it zooms out of (iPhone, iPad).
    func openViewer(at id: FileID) {
        zoomTile = id
        zoomFrame = tileLocator.frame(id)
        viewerStart = viewerStart(at: id)
    }

    /// The zoom transition follows the photo the viewer shows: its tile is scrolled on screen, so closing the viewer
    /// zooms back into it.
    var zoomSource: ViewerZoomSource? {
        guard let tile = zoomTile ?? viewerStart?.startId else { return nil }
        return ViewerZoomSource(namespace: zoomNamespace, tile: tile) { id in
            tileLocator.reveal(id)
            zoomTile = id
            zoomFrame = tileLocator.frame(id)
            #if os(macOS)
                // The grid follows the viewer: back in the grid, the photo seen last is selected and culling goes on there.
                selection = [id]
                isSelecting = true
            #endif
        }
    }

    /// The viewer over this grid's photos, at `id`; stacked copies can be opened in it.
    func viewerStart(at id: FileID) -> ViewerStart {
        ViewerStart(ids: feed.model.ids, startId: id, stacks: TimelineStacking.stacks(in: feed.items), fromLibrary: isLibrary)
    }

    struct RevealKey: Equatable {
        var request: UUID?
        var revision: Int
    }

    /// "Show in library": once the grid has its photos, scrolls to the photo (or, when the Library does not show it, to
    /// the photo closest in time) and marks it — selected on the Mac, a short ring elsewhere.
    func carryOutReveal() async {
        guard let center = reveal, let request = center.pending, feed.loaded, !feed.items.isEmpty else { return }
        // The grid lays out the model it was just given first; a newer one starts this again.
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled, center.pending == request,
            let target = TimelineRevealCenter.target(of: request, in: feed.items)
        else { return }
        center.pending = nil
        endSelection()
        tileLocator.reveal(target.id)
        guard case .tile(let id) = target else { return }
        #if os(macOS)
            selection = [id]
            isSelecting = true
        #else
            if let frame = tileLocator.frame(id) { highlight = TileHighlight(frame: frame) }
        #endif
    }

    /// A slideshow of the selected items in the grid's order, or of the whole grid from `start` on.
    func playSlideshow(_ ids: [FileID]) {
        let all: [FileID] = feed.model.ids
        if ids.count > 1 {
            let chosen = Set(ids)
            slideshow = SlideshowRequest(title: title, ids: all.filter { chosen.contains($0) })
        } else if !all.isEmpty {
            slideshow = SlideshowRequest(title: title, ids: all, startId: ids.first)
        }
    }

    /// Favourites or unfavourites; undoable. New favourites get a heart over their tiles.
    func setFavorite(_ items: [MediaItem], _ value: Bool) {
        favoriteToggles += 1
        if value { motion.favorite(items.map(\.fileId)) }
        let undoManager = undoManager
        Task { await session.perform(.favorite(items, value: value), undoManager: undoManager) }
    }

    /// Skeleton or empty state (SPEC §6.3): the timeline is only called empty after a first sync has finished.
    var emptyPhase: GridEmptyPhase {
        var firstSyncRunning = false
        var hasSyncedBefore = false
        var syncStopped = false
        switch session.syncStatus {
        case .initialSync: firstSyncRunning = true
        case .idle(let lastSync): hasSyncedBefore = lastSync != nil
        // Incremental sync and reconciliation only run after the first sync.
        case .syncing, .reconciling: hasSyncedBefore = true
        case .offline, .failed: syncStopped = true
        }
        return GridEmptyPhase.phase(
            feedLoaded: feed.loaded, waitsForFirstSync: waitsForFirstSync, firstSyncRunning: firstSyncRunning,
            hasSyncedBefore: hasSyncedBefore, syncStopped: syncStopped)
    }

    var loadingCaption: String? {
        guard waitsForFirstSync else { return nil }
        if case .initialSync(let count) = session.syncStatus {
            return InitialSyncProgress.text(count: count, total: session.initialSyncTotal)
        }
        return String(localized: "Loading your library…", bundle: .module)
    }

    /// The first sync is running: its total is asked for once ("N of M").
    var isInitialSync: Bool {
        if case .initialSync = session.syncStatus { return true }
        return false
    }

    var selectionTitle: String {
        selection.isEmpty
            ? String(localized: "Select items", bundle: .module)
            : String(localized: "\(selection.count) selected", bundle: .module)
    }

    var deleteTitle: String {
        String(localized: "Delete \(confirmDelete?.items.count ?? 0) items?", bundle: .module)
    }

    /// Where deleted items go, and how many of them are stacked behind the selected tiles (SPEC TL-6).
    var deleteMessage: String {
        let trash: String =
            session.features.has(.trashbin)
            ? String(localized: "The items are moved to the trash bin of your Nextcloud.", bundle: .module)
            : String(localized: "The trash bin is disabled on your server: deleted items cannot be restored.", bundle: .module)
        guard let stacked = confirmDelete?.stacked, stacked > 0 else { return trash }
        let copies: String = String(localized: "This also deletes \(stacked) photos stacked behind the selected ones.", bundle: .module)
        return copies + " " + trash
    }

    /// The items of the tiles `ids` with everything stacked behind them: an action on a stack is an action on all of
    /// it (SPEC TL-6).
    func withStacks(_ ids: [FileID]) -> [FileID] {
        let model = feed.model
        return StackedSelection.members(of: ids) { model[$0]?.stack ?? [] }
    }

    /// Asks before deleting the tiles `ids` and the photos stacked behind them.
    func requestDelete(_ ids: [FileID]) {
        withItems(withStacks(ids)) { items in
            let deletable = items.filter(\.permissions.canDelete)
            guard !deletable.isEmpty else { return }
            confirmDelete = DeleteConfirmation(
                items: deletable, stacked: StackedSelection.hiddenCount(deletable.map(\.fileId), tiles: ids))
        }
    }
}
