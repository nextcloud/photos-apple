// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

#if os(macOS)
    import AppKit
    import PhotosCore
    import PhotosDomain
    import UniformTypeIdentifiers
    import PhotosMedia
    import PhotosModel
    import PhotosStore
    import SwiftUI

    extension PhotoGridScrollView {
        // MARK: Updates

        func update(_ update: GridFeed.Update, zoomStep: Int, selection: Set<FileID>, showsHeaders: Bool, squareTiles: Bool) {
            let plan = core.begin(update, zoomStep: zoomStep, showsHeaders: showsHeaders, squareTiles: squareTiles)
            if plan.relayouts {
                let pinched = plan.layoutChanged ? pinchAnchor : nil
                let anchor = pinched?.id ?? anchorItem()
                // The tile a peek is over may be somewhere else now.
                peek?.end()
                hoverLift?.drop(animated: false)
                if pinchStepPending, plan.layoutChanged {
                    pinchStepPending = false
                    pinchScaler.crossfadeIntoNewLayout()
                }
                core.show(update.model, relayout: true)
                if plan.reloads {
                    collectionView.reloadData()
                } else {
                    collectionView.collectionViewLayout?.invalidateLayout()
                }
                if let pinched {
                    place(pinched.id, offset: pinched.offset)
                } else {
                    restore(anchor)
                }
                core.noteLayout(width: gridWidth)
                refreshVisibleTiles()
                reloadScrubber()
            } else if let changes = plan.sectionChanges {
                apply(changes, model: update.model)
            } else if case .content(let ids) = plan.change {
                core.show(update.model, relayout: false)
                refreshVisibleTiles(only: ids)
            }
            apply(selection: selection, modelChanged: plan.relayouts || plan.sectionChanges != nil)
            #if DEBUG
                if !model.isEmpty {
                    GridDebugKeys.runOnce(in: collectionView)
                    GridDebugPinch.runOnce(in: self)
                    GridDebugScroll.runOnce(in: self)
                }
            #endif
        }

        /// Some sections came, went or changed (an upload, a sync page): only those are updated, in one batch, instead
        /// of reloading and laying out every section of the library.
        private func apply(_ changes: GridModel.SectionChanges, model: GridModel) {
            guard window != nil else {
                // Not on screen: nothing to animate or keep in place.
                core.show(model, relayout: true)
                collectionView.reloadData()
                reloadScrubber()
                return
            }
            // Tiles the user just deleted or archived fade out while their neighbours move into the gap (and come back
            // the same way on Undo), SPEC §17.2.
            if let motion = callbacks?.motion, motion.hasExpectations,
                let items = GridItemChanges.make(old: core.model, new: model, changes: changes),
                motion.style(gone: items.gone, back: items.back) != nil
            {
                _ = collectionView.numberOfSections
                peek?.end()
                core.show(model, relayout: true)
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.15 : 0.3
                    context.allowsImplicitAnimation = true
                    collectionView.animator().performBatchUpdates {
                        collectionView.deleteSections(items.deletedSections)
                        collectionView.insertSections(items.insertedSections)
                        collectionView.deleteItems(at: Set(items.deletedItems))
                        collectionView.insertItems(at: Set(items.insertedItems))
                    }
                }
                if !items.headerChanges.isEmpty { reconfigureVisibleHeaders() }
                if !changes.content.isEmpty { refreshVisibleTiles(only: changes.content) }
                reloadScrubber()
                return
            }
            let anchor = anchorItem()
            // The collection view must know the old sections before the batch (it may not have asked yet).
            _ = collectionView.numberOfSections
            core.show(model, relayout: true)
            collectionView.performBatchUpdates {
                collectionView.deleteSections(changes.deleted)
                collectionView.insertSections(changes.inserted)
                collectionView.reloadSections(changes.reloaded)
            }
            restore(anchor)
            if !changes.content.isEmpty { refreshVisibleTiles(only: changes.content) }
            reloadScrubber()
        }

        /// A heart over the tiles on screen that were just made favourites (SPEC §17.2).
        func playHeartBursts(_ ids: [FileID]) {
            guard window != nil else { return }
            let wanted = Set(ids)
            for case let tile as PhotoItem in collectionView.visibleItems() {
                guard let id = tile.fileId, wanted.contains(id) else { continue }
                tile.playHeartBurst()
            }
        }

        /// Reconfigures the tiles on screen: badges, and a preview that fits the current tile size. A tile keeps the
        /// picture it shows until the better one is there.
        func refreshVisibleTiles(only ids: Set<FileID>? = nil) {
            let side = geometry.side
            let scale = backingScale
            for case let tile as PhotoItem in collectionView.visibleItems() {
                guard let id = tile.fileId, ids?.contains(id) ?? true, let item = model[id] else { continue }
                tile.configure(item: item, owner: self, tileSide: side, scale: scale)
            }
        }

        private func apply(selection: Set<FileID>, modelChanged: Bool) {
            guard selected.needsApply(selection, modelChanged: modelChanged) else { return }
            var paths: Set<IndexPath> = []
            paths.reserveCapacity(selection.count)
            var found: Set<FileID> = []
            for id in selection {
                guard let position = model.position(of: id) else { continue }
                paths.insert(IndexPath(item: position.item, section: position.section))
                found.insert(id)
            }
            if collectionView.selectionIndexPaths != paths { collectionView.selectionIndexPaths = paths }
            if found.count != selection.count {
                selected.reset(found)
                // Selected items that are gone (deleted, filtered out): tell SwiftUI, outside of its view update.
                DispatchQueue.main.async { [weak self] in self?.callbacks?.selectionChanged(found) }
            } else {
                selected.reset(selection)
            }
        }

        /// The selected items (as last reported to SwiftUI).
        func currentSelection() -> Set<FileID> { selected.ids }

        func fileId(at indexPath: IndexPath) -> FileID? { core.fileId(at: indexPath) }

        // MARK: Moments (SPEC §16.1)

        /// New moment titles: the headers on screen show them at once; their heights stay (one line either way).
        func setMoments(_ moments: MomentHeaders) {
            guard core.headerTexts.setMoments(moments) else { return }
            reconfigureVisibleHeaders()
        }

        private func reconfigureVisibleHeaders() {
            let kind = NSCollectionView.elementKindSectionHeader
            for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: kind) {
                guard let header = collectionView.supplementaryView(forElementKind: kind, at: indexPath) as? SectionHeaderView else {
                    continue
                }
                configure(header, section: indexPath.section)
            }
        }

        func configure(_ header: SectionHeaderView, section index: Int) {
            guard let section = model.sections[safe: index] else { return }
            header.configure(core.headerTexts.text(for: section), metrics: headerMetrics)
            header.openMoment = { [weak self] id in self?.callbacks?.openMoment?(id) }
        }
    }
#endif
