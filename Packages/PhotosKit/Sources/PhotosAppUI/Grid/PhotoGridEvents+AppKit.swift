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
        // MARK: Events

        @objc func handleDoubleClick(_ gesture: NSClickGestureRecognizer) {
            let point = gesture.location(in: collectionView)
            guard let indexPath = collectionView.indexPathForItem(at: point), let id = fileId(at: indexPath) else { return }
            callbacks?.open(id)
        }

        /// A trackpad pinch zooms with the fingers (SPEC §15.5, §17.7): between two zoom steps the grid scales smoothly
        /// about the pointer towards the next step's tile size, and switches to that step (cross-fading into its layout)
        /// once the fingers have gone far enough — one step per 0.22 of magnification, so a long pinch goes through
        /// several. The photo under the pointer stays where it is; out of the densest step the Library's days take over.
        /// Each step is a "level change" on a trackpad with haptics. With Reduce Motion the grid does not scale; the steps
        /// cross-fade.
        @objc func handleMagnify(_ gesture: NSMagnificationGestureRecognizer) {
            pinch(gesture.state, magnification: Double(gesture.magnification), location: gesture.location(in: contentView)) {
                gesture.state = .ended
            }
        }

        /// One event of a pinch; `location` is in the clip view, `finish` ends the gesture early.
        func pinch(
            _ state: NSGestureRecognizer.State, magnification: Double, location: NSPoint, finish: @escaping () -> Void
        ) {
            switch state {
            case .began:
                pinchZoom.begin(at: magnification)
                pinchStepPending = false
                let id = collectionView.indexPathForItem(at: collectionView.convert(location, from: contentView)).flatMap { fileId(at: $0) }
                pinchAnchor = (id ?? anchorItem()).map { ($0, location.y - contentView.bounds.minY) }
                pinchScaler.begin(at: location)
                hoverLift?.isSuspended = true
            case .changed:
                let outcome = pinchZoom.update(magnification: magnification, sides: pinchSides(), pastEnd: callbacks?.zoomPastEnd != nil)
                switch outcome {
                case .scale(let scale):
                    // Until the new step is laid out, the grid stays at the size it reached.
                    if !pinchStepPending, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { pinchScaler.show(scale: scale) }
                case .step(let zoomIn):
                    pinchStep(zoomIn: zoomIn, finish: finish)
                }
            case .ended:
                if let zoomIn = pinchZoom.end(magnification: magnification, sides: pinchSides()) {
                    pinchStep(zoomIn: zoomIn, finish: finish)
                } else {
                    pinchScaler.settle()
                }
                pinchEnded()
            case .cancelled, .failed:
                pinchScaler.settle()
                pinchEnded()
            default: break
            }
        }

        #if DEBUG
            func debugHover(at point: NSPoint) { hoverLift?.debugPointer(at: point) }
        #endif

        private func pinchEnded() {
            hoverLift?.isSuspended = false
            // The relayout of the last step still uses the anchor; it is dropped after that.
            DispatchQueue.main.async { [weak self] in self?.pinchAnchor = nil }
        }

        /// Tile sides of the current step and the steps either side of it, for the pinch's scale.
        private func pinchSides() -> GridPinchZoom.Sides {
            let width = gridWidth
            func side(_ step: Int) -> Double? {
                step == zoomStep ? nil : GridColumns.geometry(width: width, step: step).side
            }
            return GridPinchZoom.Sides(
                current: geometry.side, larger: side(GridColumns.step(zoomStep, zoomIn: true)),
                smaller: side(GridColumns.step(zoomStep, zoomIn: false)))
        }

        private func pinchStep(zoomIn: Bool, finish: () -> Void) {
            let next = GridColumns.step(zoomStep, zoomIn: zoomIn)
            if next != zoomStep {
                LibraryZoomHaptics.trackpadLevelChange()
                pinchStepPending = true
                callbacks?.columnsChanged(next)
            } else if !zoomIn, let zoomPastEnd = callbacks?.zoomPastEnd {
                LibraryZoomHaptics.trackpadLevelChange()
                pinchScaler.reset()
                let height = max(contentView.bounds.height, 1)
                let point = UnitPoint(x: 0.5, y: Double((pinchAnchor?.offset ?? 0) / height))
                finish()
                zoomPastEnd(pinchAnchor?.id, point)
            }
        }

        func open(_ id: FileID) {
            callbacks?.open(id)
        }

        func openSelection() {
            if let first = collectionView.selectionIndexPaths.sorted().first, let id = fileId(at: first) {
                callbacks?.open(id)
            }
        }

        /// Escape: nothing stays selected.
        func clearSelection() {
            guard !collectionView.selectionIndexPaths.isEmpty else { return }
            collectionView.deselectAll(nil)
            selected.reset([])
            callbacks?.selectionChanged([])
            callbacks?.cancelSelection()
        }

        /// An arrow key with nothing selected starts at the first tile on screen.
        func selectFirstVisible() {
            let top = contentView.bounds.minY + topInset
            let visible = collectionView.indexPathsForVisibleItems().sorted()
            let first = visible.first { indexPath in
                guard let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame else { return false }
                return frame.minY >= top + CGFloat(headerHeight(section: indexPath.section)) - 1
            }
            guard let indexPath = first ?? visible.first else { return }
            collectionView.selectionIndexPaths = [indexPath]
            selected.reset(Set([fileId(at: indexPath)].compactMap { $0 }))
            callbacks?.selectionChanged(currentSelection())
        }

        func zoom(in zoomIn: Bool) {
            let next = GridColumns.step(zoomStep, zoomIn: zoomIn)
            if next != zoomStep {
                callbacks?.columnsChanged(next)
            } else if !zoomIn, let zoomPastEnd = callbacks?.zoomPastEnd {
                // ⌘− at the densest step: the Library's days.
                zoomPastEnd(anchorItem(), .top)
            }
        }

        /// P, X, U, 0–5 rate the selection and C compares it (SPEC §15.2); without modifiers only, so ⌘C and the
        /// like keep their meaning.
        func handleCullingKey(_ event: NSEvent) -> Bool {
            guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
                let character = event.charactersIgnoringModifiers?.lowercased().first, !collectionView.selectionIndexPaths.isEmpty
            else { return false }
            let ids = collectionView.selectionIndexPaths.sorted().compactMap { fileId(at: $0) }
            if character == "c", let compare = callbacks?.compare, (2...CompareLayout.maxPhotos).contains(ids.count) {
                compare(ids)
                return true
            }
            guard let command = CullingCommand(key: character), let cull = callbacks?.cull else { return false }
            cull(command, ids)
            if ids.count == 1, CullingSettings.autoAdvance { selectNext() }
            return true
        }

        /// Auto-advance: the tile after the selected one becomes the selection.
        func selectNext() {
            guard let current = collectionView.selectionIndexPaths.max(),
                let next = GridNavigation.indexPath(after: current, sectionCount: model.sections.count, itemCount: model.numberOfItems)
            else { return }
            collectionView.selectionIndexPaths = [next]
            selected.reset(Set([fileId(at: next)].compactMap { $0 }))
            callbacks?.selectionChanged(currentSelection())
            collectionView.scrollToItems(at: [next], scrollPosition: .nearestHorizontalEdge)
        }

        func menuActions(for id: FileID) -> [GridMenuAction] {
            callbacks?.menu([id]) ?? []
        }

        func menu(for indexPath: IndexPath) -> NSMenu? {
            guard let id = fileId(at: indexPath), let callbacks else { return nil }
            var ids = currentSelection()
            if !ids.contains(id) {
                collectionView.selectionIndexPaths = [indexPath]
                ids = [id]
                selected.reset(ids)
                callbacks.selectionChanged(ids)
            }
            let targets = Array(ids)
            let menu = Self.menu(callbacks.menu(targets), targets: targets)
            return menu.items.isEmpty ? nil : menu
        }

        /// The actions as menu items; submenus for actions with children, the system's Share menu for sharing.
        static func menu(_ actions: [GridMenuAction], targets: [FileID]) -> NSMenu {
            let menu = NSMenu()
            for action in actions {
                if action.startsGroup, !menu.items.isEmpty { menu.addItem(.separator()) }
                let item: NSMenuItem
                if let share = action.share {
                    item = NSSharingServicePicker(items: share()).standardShareMenuItem
                } else if !action.children.isEmpty {
                    item = NSMenuItem(title: action.title, action: nil, keyEquivalent: "")
                    item.submenu = Self.menu(action.children, targets: targets)
                } else {
                    item = MenuActionItem(title: action.title, handler: { action.handler(targets) })
                }
                if action.share == nil {
                    item.image = NSImage(systemSymbolName: action.systemImage, accessibilityDescription: nil)
                }
                menu.addItem(item)
            }
            return menu
        }

        /// Edit ▸ Copy (⌘C) while the grid has the focus.
        func copySelection() {
            let ids = currentSelection()
            guard !ids.isEmpty else { return }
            callbacks?.copy?(Array(ids))
        }

        var canCopy: Bool { callbacks?.copy != nil && !currentSelection().isEmpty }
    }
#endif
