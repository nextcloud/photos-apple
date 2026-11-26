// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

#if canImport(UIKit)
    import PhotosCore
    import PhotosDomain
    import PhotosMedia
    import PhotosModel
    import PhotosStore
    import SwiftUI
    import UIKit

    extension PhotoGridController {
        // MARK: Moments (SPEC §16.1)

        /// New moment titles: the headers on screen show them at once; their heights stay (one line either way).
        func setMoments(_ moments: MomentHeaders) {
            guard core.headerTexts.setMoments(moments), isViewLoaded else { return }
            pillSection = nil
            updateDatePill(animated: false)
            let kind = UICollectionView.elementKindSectionHeader
            for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: kind) {
                guard let header = collectionView.supplementaryView(forElementKind: kind, at: indexPath) as? SectionHeader else { continue }
                configure(header, section: indexPath.section)
            }
        }

        func configure(_ header: SectionHeader, section index: Int) {
            guard let section = model.sections[safe: index] else { return }
            header.configure(core.headerTexts.text(for: section), metrics: headerMetrics)
            header.openMoment = { [weak self] id in self?.callbacks?.openMoment?(id) }
        }

        // MARK: Updates

        func update(
            _ update: GridFeed.Update, zoomStep: Int, selection: Set<FileID>, isSelecting: Bool, showsHeaders: Bool, squareTiles: Bool
        ) {
            loadViewIfNeeded()
            let plan = core.begin(update, zoomStep: zoomStep, showsHeaders: showsHeaders, squareTiles: squareTiles)
            if plan.relayouts {
                let pinched = plan.layoutChanged ? pinchAnchor : nil
                pinchAnchor = nil
                let anchor = pinched?.id ?? anchorItem()
                // The tile a peek is over may be somewhere else now.
                peek?.end()
                core.show(update.model, relayout: true)
                yearTicker.reset()
                let relayout: () -> Void = { [self] in
                    if plan.reloads {
                        collectionView.reloadData()
                    } else {
                        collectionView.collectionViewLayout.invalidateLayout()
                    }
                    // A pinch scaled the tiles while the fingers moved: the new layout takes over at full size.
                    collectionView.transform = .identity
                    if let pinched {
                        place(pinched.id, viewY: pinched.y)
                    } else {
                        restore(anchor)
                    }
                }
                if plan.layoutChanged, view.window != nil, !UIAccessibility.isReduceMotionEnabled {
                    // Zoom: a short cross-fade between the two layouts.
                    UIView.transition(with: collectionView, duration: 0.2, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                        relayout()
                    }
                } else {
                    relayout()
                }
                core.noteLayout(width: gridWidth)
                refreshVisibleTiles()
            } else if let changes = plan.sectionChanges {
                apply(changes, model: update.model)
            } else if case .content(let ids) = plan.change {
                core.show(update.model, relayout: false)
                refreshVisibleTiles(only: ids)
            }
            // While a two-finger drag selects, SwiftUI may not have heard of the selection mode yet: it stays on.
            if isSelecting != self.isSelecting, isSelecting || !multiSelectInteraction {
                setSelecting(isSelecting)
            }
            syncSelection(selection, modelChanged: plan.relayouts || plan.sectionChanges != nil)
            if plan.relayouts || plan.sectionChanges != nil { reloadScrubber() }
        }

        /// Some sections came, went or changed (an upload, a sync page): only those are updated, in one batch, instead
        /// of reloading and laying out every section of the library.
        private func apply(_ changes: GridModel.SectionChanges, model: GridModel) {
            guard view.window != nil else {
                // Not on screen: nothing to keep in place.
                core.show(model, relayout: true)
                collectionView.reloadData()
                return
            }
            // Tiles the user just deleted or archived leave in an animated batch, and come back the same way on Undo.
            if let motion = callbacks?.motion, motion.hasExpectations,
                let items = GridItemChanges.make(old: core.model, new: model, changes: changes),
                let style = motion.style(gone: items.gone, back: items.back)
            {
                applyAnimated(items, style: style, content: changes.content, model: model)
                return
            }
            let anchor = anchorItem()
            // The collection view must know the old sections before the batch (after a reload it may not have asked yet).
            _ = collectionView.numberOfSections
            core.show(model, relayout: true)
            UIView.performWithoutAnimation {
                collectionView.performBatchUpdates {
                    collectionView.deleteSections(changes.deleted)
                    collectionView.insertSections(changes.inserted)
                    collectionView.reloadSections(changes.reloaded)
                }
            }
            restore(anchor)
            if !changes.content.isEmpty { refreshVisibleTiles(only: changes.content) }
        }

        /// Single tiles leave (and come) with their style while their neighbours flow into the gap, in one spring.
        private func applyAnimated(_ items: GridItemChanges, style: GridLeaveStyle, content: Set<FileID>, model: GridModel) {
            _ = collectionView.numberOfSections
            peek?.end()
            core.show(model, relayout: true)
            let layout = collectionView.collectionViewLayout as? GridCollectionLayout
            layout?.leaveStyle = style
            UIView.animate(springDuration: 0.45, bounce: 0, options: [.allowUserInteraction]) {
                self.collectionView.performBatchUpdates {
                    self.collectionView.deleteSections(items.deletedSections)
                    self.collectionView.insertSections(items.insertedSections)
                    self.collectionView.deleteItems(at: items.deletedItems)
                    self.collectionView.insertItems(at: items.insertedItems)
                } completion: { _ in
                    layout?.leaveStyle = nil
                }
            }
            // A day that now starts its month says so.
            if !items.headerChanges.isEmpty { reconfigureVisibleHeaders() }
            if !content.isEmpty { refreshVisibleTiles(only: content) }
            pillSection = nil
        }

        private func reconfigureVisibleHeaders() {
            let kind = UICollectionView.elementKindSectionHeader
            for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: kind) {
                guard let header = collectionView.supplementaryView(forElementKind: kind, at: indexPath) as? SectionHeader else { continue }
                configure(header, section: indexPath.section)
            }
        }

        /// A heart springs up over the tiles on screen that were just made favourites.
        func playHeartBursts(_ ids: [FileID]) {
            guard isViewLoaded, view.window != nil else { return }
            if menuShowing {
                pendingBursts += ids
                return
            }
            let wanted = Set(ids)
            for case let cell as PhotoCell in collectionView.visibleCells {
                guard let id = cell.fileId, wanted.contains(id) else { continue }
                cell.playHeartBurst()
            }
        }

        func setSelecting(_ selecting: Bool) {
            isSelecting = selecting
            collectionView.isEditing = selecting
            collectionView.allowsMultipleSelection = selecting
            if selecting { peek?.end() }
        }

        /// Reconfigures the cells on screen: badges, and a preview that fits the current tile size. A cell keeps the
        /// picture it shows until the better one is there.
        func refreshVisibleTiles(only ids: Set<FileID>? = nil) {
            guard isViewLoaded else { return }
            let side = geometry.side
            let scale = previewScale
            for case let cell as PhotoCell in collectionView.visibleCells {
                guard let id = cell.fileId, ids?.contains(id) ?? true, let item = model[id] else { continue }
                cell.configure(item: item, owner: self, tileSide: side, scale: scale)
            }
        }

        func syncSelection(_ selection: Set<FileID>, modelChanged: Bool = false) {
            guard self.selected.needsApply(selection, modelChanged: modelChanged) else { return }
            let selected = currentSelection()
            defer { self.selected.reset(currentSelection()) }
            guard selected != selection else { return }
            for id in selected.subtracting(selection) {
                if let indexPath = indexPath(for: id) { collectionView.deselectItem(at: indexPath, animated: false) }
            }
            var missing = false
            for id in selection.subtracting(selected) {
                if let indexPath = indexPath(for: id) {
                    collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
                } else {
                    missing = true
                }
            }
            if missing {
                // Selected items that are gone (deleted, filtered out): tell SwiftUI, outside of its view update.
                let remaining = currentSelection()
                DispatchQueue.main.async { [weak self] in self?.callbacks?.selectionChanged(remaining) }
            }
        }

        func currentSelection() -> Set<FileID> {
            Set((collectionView.indexPathsForSelectedItems ?? []).compactMap { fileId(at: $0) })
        }

        func fileId(at indexPath: IndexPath) -> FileID? { core.fileId(at: indexPath) }

        func indexPath(for id: FileID) -> IndexPath? { core.indexPath(for: id) }

        /// The Library's years, months or days cover the grid (SPEC §17.5): its tiles, headers and scrubber are out of
        /// VoiceOver's reach meanwhile.
        func setCovered(_ covered: Bool) {
            view.accessibilityElementsHidden = covered
            collectionView?.accessibilityElementsHidden = covered
            // A leaf element has no children for any accessibility client: the SwiftUI host lists the grid's cells
            // even when it is hidden.
            collectionView?.isAccessibilityElement = covered
        }

        /// The tile's frame in this controller's view, when it is on screen (the zoom transition of the viewer).
        func tileFrame(_ id: FileID) -> CGRect? {
            guard isViewLoaded, let indexPath = indexPath(for: id),
                let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame
            else { return nil }
            let visible = collectionView.bounds.inset(by: collectionView.adjustedContentInset)
            guard visible.intersects(frame) else { return nil }
            return view.convert(frame, from: collectionView)
        }

        /// Scrolls the tile on screen if it is not (the viewer was paged far from where it was opened).
        func reveal(_ id: FileID) {
            guard isViewLoaded, let indexPath = indexPath(for: id), let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame
            else { return }
            let visible = collectionView.bounds.inset(by: collectionView.adjustedContentInset)
            guard !visible.contains(frame) else { return }
            collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
        }
    }
#endif
