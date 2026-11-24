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

    /// The photo grid on iOS, iPadOS and visionOS (SPEC §6.4).
    struct PhotoGrid: UIViewControllerRepresentable {
        var update: GridFeed.Update
        /// Zoom step (`GridColumns.options`): sets the target tile size, the columns follow from the width.
        var zoomStep: Int
        var selection: Set<FileID>
        var isSelecting: Bool
        var showsHeaders: Bool
        /// Square tiles, or each picture whole in its tile (`TileStyle`).
        var squareTiles = true
        var services: AccountServices
        var callbacks: GridCallbacks

        func makeUIViewController(context: Context) -> PhotoGridController {
            PhotoGridController(services: services)
        }

        func updateUIViewController(_ controller: PhotoGridController, context: Context) {
            var callbacks = callbacks
            // `.refreshable` on a screen only reaches SwiftUI's own scroll views; the collection view gets the action
            // from the environment and shows a refresh control of its own for it.
            if callbacks.refresh == nil, let refresh = context.environment.refresh {
                callbacks.refresh = { await refresh() }
            }
            controller.callbacks = callbacks
            controller.update(
                update, zoomStep: zoomStep, selection: selection, isSelecting: isSelecting, showsHeaders: showsHeaders,
                squareTiles: squareTiles)
        }
    }

    final class PhotoGridController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate,
        UICollectionViewDataSourcePrefetching, UICollectionViewDragDelegate
    {
        let services: AccountServices
        var callbacks: GridCallbacks? {
            didSet {
                updateRefreshControl()
                if let locator = callbacks?.tileLocator {
                    locator.frame = { [weak self] id in self?.tileFrame(id) }
                    locator.reveal = { [weak self] id in self?.reveal(id) }
                }
            }
        }
        private let refreshRunner = GridRefreshRunner()
        /// A two-finger drag over the tiles is selecting right now.
        private var multiSelectInteraction = false
        private var collectionView: UICollectionView!
        /// Model, zoom, anchor and layout bookkeeping, shared with the AppKit grid.
        private let core: GridCore
        private var isSelecting = false
        private var pinchHandled = false
        private var selected = GridSelectionTracker()
        /// Date scrubber along the trailing edge (SPEC §6.4).
        private let scrubber = GridScrubberView()
        /// Top of every section in the document, plus its height as last element (scrubber positions).
        private var sectionOffsets: [Double] = []
        /// Ratings and flags shown on the tiles (SPEC §15.2).
        let culling: GridCullingObserver

        var model: GridModel { core.model }
        var squareTiles: Bool { core.squareTiles }
        private var zoomStep: Int { core.zoomStep }
        private var headerMetrics: GridHeaderMetrics { core.headerMetrics }

        init(services: AccountServices) {
            self.services = services
            core = GridCore(services: services, headerMetrics: Self.currentHeaderMetrics)
            culling = GridCullingObserver(services: services)
            super.init(nibName: nil, bundle: nil)
            culling.changed = { [weak self] ids in self?.refreshVisibleTiles(only: ids) }
        }

        required init?(coder: NSCoder) { fatalError() }

        override func viewDidLoad() {
            super.viewDidLoad()
            collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: makeLayout())
            collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            collectionView.backgroundColor = .systemBackground
            collectionView.dataSource = self
            collectionView.delegate = self
            collectionView.prefetchDataSource = self
            // iPad: tiles can be dragged into other apps (the default leaves drags off on iPhone).
            collectionView.dragDelegate = self
            // A short album can be pulled down to refresh as well.
            collectionView.alwaysBounceVertical = true
            collectionView.allowsSelection = true
            collectionView.allowsMultipleSelectionDuringEditing = true
            // Hardware keyboard: arrow keys move the focus, Return opens the focused tile.
            collectionView.allowsFocus = true
            collectionView.selectionFollowsFocus = false
            collectionView.register(PhotoCell.self, forCellWithReuseIdentifier: PhotoCell.reuseIdentifier)
            collectionView.register(
                SectionHeader.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                withReuseIdentifier: SectionHeader.reuseIdentifier)
            view.addSubview(collectionView)
            scrubber.isHidden = true
            scrubber.labelAt = { [weak self] fraction in self?.scrubberLabel(at: fraction) ?? "" }
            scrubber.onScrub = { [weak self] fraction in self?.scroll(toFraction: fraction) }
            scrubber.onStep = { [weak self] delta in self?.scrollToYear(delta: delta) }
            view.addSubview(scrubber)

            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            collectionView.addGestureRecognizer(pinch)

            // Header heights are absolute and follow the text size.
            registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (controller: PhotoGridController, _: UITraitCollection) in
                controller.core.headerMetrics = Self.currentHeaderMetrics
                controller.collectionView.collectionViewLayout.invalidateLayout()
                controller.reloadScrubber()
            }
            registerForTraitChanges([UITraitDisplayScale.self]) { (controller: PhotoGridController, _: UITraitCollection) in
                controller.refreshVisibleTiles()
            }
            updateRefreshControl()
        }

        // MARK: Pull to refresh

        /// The refresh control is there while the screen offers a refresh (`GridCallbacks.refresh`).
        private func updateRefreshControl() {
            guard isViewLoaded else { return }
            let wanted = callbacks?.refresh != nil
            if wanted, collectionView.refreshControl == nil {
                let control = UIRefreshControl()
                control.addTarget(self, action: #selector(handleRefresh(_:)), for: .valueChanged)
                collectionView.refreshControl = control
            } else if !wanted, collectionView.refreshControl != nil, !refreshRunner.isRunning {
                collectionView.refreshControl = nil
            }
        }

        /// Pulled: the control spins until the screen's refresh (a sync, an album reload) has returned.
        @objc private func handleRefresh(_ control: UIRefreshControl) {
            guard let refresh = callbacks?.refresh else {
                control.endRefreshing()
                return
            }
            refreshRunner.run(refresh) { [weak self, weak control] in
                control?.endRefreshing()
                self?.updateRefreshControl()
            }
        }

        // MARK: Geometry

        /// Width the tiles are laid out in.
        private var gridWidth: Double { Double(collectionView?.bounds.width ?? view.bounds.width) }

        /// Columns and tile side for the current width and zoom.
        var geometry: GridGeometry { core.geometry(width: gridWidth) }

        /// Scale for preview requests, capped at 2 (SPEC §5.5.1): a 3× preview of every tile costs more memory and
        /// traffic than it shows.
        private var previewScale: Double { Double(min(view.traitCollection.displayScale, 2)) }

        private var headersShown: Bool { core.headersShown }

        /// Header heights for the current text size.
        private static var currentHeaderMetrics: GridHeaderMetrics {
            GridHeaderMetrics(
                titleHeight: Double(SectionHeader.titleFont.lineHeight.rounded(.up)),
                subtitleHeight: Double(SectionHeader.subtitleFont.lineHeight.rounded(.up)))
        }

        private func headerHeight(section: Int) -> Double { core.headerHeight(section: section) }

        func makeLayout() -> UICollectionViewLayout {
            UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
                self?.core.sectionMetrics(sectionIndex, width: Double(environment.container.effectiveContentSize.width), wholePoints: false)
                    .layoutSection(headerKind: UICollectionView.elementKindSectionHeader)
            }
        }

        // MARK: Updates

        func update(
            _ update: GridFeed.Update, zoomStep: Int, selection: Set<FileID>, isSelecting: Bool, showsHeaders: Bool, squareTiles: Bool
        ) {
            loadViewIfNeeded()
            let plan = core.begin(update, zoomStep: zoomStep, showsHeaders: showsHeaders, squareTiles: squareTiles)
            if plan.relayouts {
                let anchor = anchorItem()
                core.show(update.model, relayout: true)
                let relayout: () -> Void = { [self] in
                    if plan.reloads {
                        collectionView.reloadData()
                    } else {
                        collectionView.collectionViewLayout.invalidateLayout()
                    }
                    restore(anchor)
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

        private func setSelecting(_ selecting: Bool) {
            isSelecting = selecting
            collectionView.isEditing = selecting
            collectionView.allowsMultipleSelection = selecting
        }

        /// Reconfigures the cells on screen: badges, and a preview that fits the current tile size. A cell keeps the
        /// picture it shows until the better one is there.
        private func refreshVisibleTiles(only ids: Set<FileID>? = nil) {
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

        private func indexPath(for id: FileID) -> IndexPath? { core.indexPath(for: id) }

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

        // MARK: Scroll position

        private var topInset: CGFloat { collectionView.adjustedContentInset.top }

        /// The first item below the pinned header, unless the grid is scrolled to the top (then it stays there).
        /// Taken from the layout, not from the cells on screen, which lag behind right after a relayout.
        private func anchorItem() -> FileID? {
            guard isViewLoaded else { return nil }
            let top = collectionView.contentOffset.y + topInset
            let isAtTop = collectionView.contentOffset.y <= -topInset + 1
            return core.anchorItem(isAtTop: isAtTop, top: Double(top)) { [self] in
                let strip = CGRect(x: 0, y: top, width: collectionView.bounds.width, height: CGFloat(geometry.side) + 100)
                return (collectionView.collectionViewLayout.layoutAttributesForElements(in: strip) ?? []).compactMap { attributes in
                    guard attributes.representedElementCategory == .cell else { return nil }
                    let indexPath = attributes.indexPath
                    return GridAnchor.Candidate(section: indexPath.section, item: indexPath.item, maxY: Double(attributes.frame.maxY))
                }
            }
        }

        private func restore(_ anchor: FileID?) {
            core.restore(anchor) { [weak self] anchor in self?.restoreNow(anchor) }
        }

        private func restoreNow(_ anchor: FileID) {
            guard let indexPath = indexPath(for: anchor) else { return }
            collectionView.layoutIfNeeded()
            guard let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame else { return }
            let contentHeight = max(collectionView.contentSize.height, collectionView.collectionViewLayout.collectionViewContentSize.height)
            let offset = GridAnchor.offset(
                documentY: Double(frame.minY) - headerHeight(section: indexPath.section), topInset: Double(topInset),
                contentHeight: Double(contentHeight), bottomInset: Double(collectionView.adjustedContentInset.bottom),
                viewportHeight: Double(collectionView.bounds.height))
            collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: CGFloat(offset)), animated: false)
        }

        override func viewWillLayoutSubviews() {
            super.viewWillLayoutSubviews()
            // The collection view still has its old width here.
            if collectionView.bounds.width != view.bounds.width, core.resizeAnchor == nil { core.resizeAnchor = anchorItem() }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            if core.columnsChanged(width: gridWidth) { restore(core.resizeAnchor) }
            core.resizeAnchor = nil
            if core.sideChanged(width: gridWidth) { refreshVisibleTiles() }
            core.noteLayout(width: gridWidth)
            layoutScrubber()
        }

        // MARK: Date scrubber

        /// The scrubber runs along the part of the grid that is not under the bars, inside the safe area.
        private func layoutScrubber() {
            guard isViewLoaded else { return }
            let insets = collectionView.adjustedContentInset
            let width = min(GridScrubberView.width, view.bounds.width)
            let frame = CGRect(
                x: view.bounds.maxX - view.safeAreaInsets.right - width, y: insets.top, width: width,
                height: max(view.bounds.height - insets.top - insets.bottom, 0))
            let resized = frame.size != scrubber.frame.size
            scrubber.frame = frame
            if resized { reloadScrubber() }
        }

        /// Height of the part of the grid between the bars.
        private var visibleHeight: Double {
            let insets = collectionView.adjustedContentInset
            return Double(collectionView.bounds.height - insets.top - insets.bottom)
        }

        /// How far the grid scrolls, as document offsets of its top edge.
        private var scrollRange: Double { max((sectionOffsets.last ?? 0) - visibleHeight, 0) }

        private func reloadScrubber() {
            guard isViewLoaded else { return }
            let visibleHeight = visibleHeight
            guard headersShown, visibleHeight > 0 else {
                setScrubberShown(false)
                return
            }
            let sections = model.sections
            // Placeholder tiles (the first sync's skeleton) count: the scrubber covers the whole library.
            sectionOffsets = geometry.sectionOffsets(
                itemCounts: sections.map(\.tileCount), headerHeights: sections.map { headerMetrics.height(for: $0) })
            let range = scrollRange
            // Not worth it for a library that fits on two screens.
            guard range > visibleHeight else {
                setScrubberShown(false)
                return
            }
            setScrubberShown(true)
            scrubber.ticks = model.yearStarts.map { entry in
                GridScrubberView.Tick(fraction: min(sectionOffsets[entry.section] / range, 1), label: String(entry.year))
            }
            updateScrubberPosition(userInitiated: false)
        }

        /// One indicator at the edge: the scrubber's handle where it is shown, else the scroll view's own.
        private func setScrubberShown(_ shown: Bool) {
            scrubber.isHidden = !shown
            collectionView.showsVerticalScrollIndicator = !shown
        }

        private func section(atFraction fraction: Double) -> GridSection? {
            // The section under the pinned header, i.e. the one whose items are at the top.
            guard let index = GridGeometry.section(at: fraction * scrollRange + 1, in: sectionOffsets) else { return nil }
            return model.sections[safe: index]
        }

        private func scrubberLabel(at fraction: Double) -> String {
            section(atFraction: fraction).map(GridHeaderTexts.scrubberLabel) ?? ""
        }

        private var scrollFraction: Double {
            let range = scrollRange
            return range > 0 ? min(max(Double(collectionView.contentOffset.y + topInset) / range, 0), 1) : 0
        }

        private func scroll(toFraction fraction: Double) {
            scroll(toDocumentY: fraction * scrollRange)
        }

        private func scroll(toDocumentY y: Double) {
            let offset = GridAnchor.offset(
                documentY: y, topInset: Double(topInset), contentHeight: sectionOffsets.last ?? 0,
                bottomInset: Double(collectionView.adjustedContentInset.bottom), viewportHeight: Double(collectionView.bounds.height))
            collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: CGFloat(offset)), animated: false)
        }

        /// Jumps to the start of the next older (+1) or newer (−1) year.
        private func scrollToYear(delta: Int) {
            let years = model.yearStarts
            guard !years.isEmpty, let current = section(atFraction: scrollFraction)?.year,
                let index = years.firstIndex(where: { $0.year == current })
            else { return }
            let target = years[max(0, min(years.count - 1, index + delta))]
            guard target.section < sectionOffsets.count else { return }
            scroll(toDocumentY: sectionOffsets[target.section])
            updateScrubberPosition(userInitiated: false)
            UIAccessibility.post(notification: .pageScrolled, argument: scrubberLabel(at: scrollFraction))
        }

        private func updateScrubberPosition(userInitiated: Bool) {
            guard !scrubber.isHidden else { return }
            let fraction = scrollFraction
            scrubber.scrolled(to: fraction, label: scrubberLabel(at: fraction), userInitiated: userInitiated)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            // Only the user's scrolling shows the scrubber, not a jump to a photo or a relayout.
            updateScrubberPosition(userInitiated: scrollView.isTracking || scrollView.isDecelerating)
        }

        func scrollViewDidChangeAdjustedContentInset(_ scrollView: UIScrollView) {
            layoutScrubber()
            reloadScrubber()
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .began: pinchHandled = false
            case .changed:
                guard !pinchHandled, gesture.scale > 1.35 || gesture.scale < 0.75 else { return }
                pinchHandled = true
                let next = GridColumns.step(zoomStep, zoomIn: gesture.scale > 1)
                if next != zoomStep { callbacks?.columnsChanged(next) }
            default: break
            }
        }

        // MARK: Keyboard

        override var canBecomeFirstResponder: Bool { true }

        override var keyCommands: [UIKeyCommand]? {
            guard isSelecting else { return nil }
            var commands = [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancelSelection))]
            // Hardware keyboard: rate and flag the selection, C compares it (SPEC §15.2).
            if !selected.ids.isEmpty {
                for key in CullingCommand.keys + ["c"] {
                    let command = UIKeyCommand(input: String(key), modifierFlags: [], action: #selector(cullingKey(_:)))
                    command.wantsPriorityOverSystemBehavior = true
                    commands.append(command)
                }
            }
            return commands
        }

        @objc func cullingKey(_ command: UIKeyCommand) {
            guard let character = command.input?.first else { return }
            let ids = (collectionView.indexPathsForSelectedItems ?? []).sorted().compactMap { fileId(at: $0) }
            if character == "c" {
                if (2...CompareLayout.maxPhotos).contains(ids.count) { callbacks?.compare?(ids) }
                return
            }
            guard let cull = CullingCommand(key: character), !ids.isEmpty else { return }
            callbacks?.cull?(cull, ids)
            if ids.count == 1, CullingSettings.autoAdvance, let current = collectionView.indexPathsForSelectedItems?.first,
                let next = GridNavigation.indexPath(after: current, sectionCount: model.sections.count, itemCount: model.numberOfItems)
            {
                collectionView.deselectItem(at: current, animated: false)
                collectionView.selectItem(at: next, animated: false, scrollPosition: .centeredVertically)
                selected.reset(currentSelection())
                callbacks?.selectionChanged(selected.ids)
            }
        }

        /// Escape: leave the selection mode.
        @objc func cancelSelection() {
            selected.reset([])
            callbacks?.selectionChanged([])
            callbacks?.cancelSelection()
        }

        func open(_ id: FileID) {
            callbacks?.open(id)
        }

        func menuActions(for id: FileID) -> [GridMenuAction] {
            callbacks?.menu([id]) ?? []
        }

        // MARK: Data source

        func numberOfSections(in collectionView: UICollectionView) -> Int { model.sections.count }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            model.numberOfItems(inSection: section)
        }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PhotoCell.reuseIdentifier, for: indexPath) as! PhotoCell
            if let item = model.item(section: indexPath.section, item: indexPath.item) {
                cell.configure(item: item, owner: self, tileSide: geometry.side, scale: previewScale)
            } else {
                // A photo the first sync has not loaded yet.
                cell.showPlaceholder()
            }
            return cell
        }

        func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath)
            -> UICollectionReusableView
        {
            let header =
                collectionView.dequeueReusableSupplementaryView(
                    ofKind: kind, withReuseIdentifier: SectionHeader.reuseIdentifier, for: indexPath)
                as! SectionHeader
            if let section = model.sections[safe: indexPath.section] {
                header.configure(core.headerTexts.text(for: section), metrics: headerMetrics)
            }
            return header
        }

        // MARK: Delegate

        /// Placeholder tiles of the first sync's skeleton cannot be tapped, selected or focused.
        func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
            fileId(at: indexPath) != nil
        }

        func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
            fileId(at: indexPath) != nil
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            guard let id = fileId(at: indexPath) else { return }
            if isSelecting {
                selected.insert([id])
                callbacks?.selectionChanged(selected.ids)
            } else {
                collectionView.deselectItem(at: indexPath, animated: false)
                callbacks?.open(id)
            }
        }

        func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
            guard isSelecting else { return }
            if let id = fileId(at: indexPath) { selected.remove([id]) }
            callbacks?.selectionChanged(selected.ids)
        }

        func collectionView(_ collectionView: UICollectionView, canFocusItemAt indexPath: IndexPath) -> Bool {
            fileId(at: indexPath) != nil
        }

        /// Return on the focused tile (hardware keyboard). A tap also ends up here after `didSelectItemAt`; opening the
        /// same photo twice is one and the same viewer.
        func collectionView(_ collectionView: UICollectionView, performPrimaryActionForItemAt indexPath: IndexPath) {
            guard !isSelecting, let id = fileId(at: indexPath) else { return }
            callbacks?.open(id)
        }

        func collectionView(_ collectionView: UICollectionView, shouldBeginMultipleSelectionInteractionAt indexPath: IndexPath) -> Bool {
            fileId(at: indexPath) != nil
        }

        /// A two-finger drag over the tiles starts the selection mode (as in Photos and Files): UIKit only selects
        /// while the collection view is editing, and the screen has to show its selection bar.
        func collectionView(_ collectionView: UICollectionView, didBeginMultipleSelectionInteractionAt indexPath: IndexPath) {
            multiSelectInteraction = true
            guard !isSelecting else { return }
            setSelecting(true)
            callbacks?.beginSelection()
        }

        func collectionViewDidEndMultipleSelectionInteraction(_ collectionView: UICollectionView) {
            multiSelectInteraction = false
            selected.reset(currentSelection())
            callbacks?.selectionChanged(selected.ids)
        }

        func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint)
            -> UIContextMenuConfiguration?
        {
            let ids = indexPaths.compactMap { fileId(at: $0) }
            guard !ids.isEmpty, let callbacks else { return nil }
            let actions = callbacks.menu(ids)
            guard !actions.isEmpty else { return nil }
            // One photo: a large preview above the menu. Several (a selection): UIKit shows the tiles themselves.
            var identifier: NSNumber?
            var preview: UIContextMenuContentPreviewProvider?
            if ids.count == 1, let item = model[ids[0]] {
                identifier = NSNumber(value: item.fileId)
                let services = services
                let shown = (collectionView.cellForItem(at: indexPaths[0]) as? PhotoCell)?.picture
                preview = { GridMenuPreviewController(item: item, services: services, placeholder: shown) }
            }
            return UIContextMenuConfiguration(identifier: identifier, previewProvider: preview) { [weak self] _ in
                UIMenu(children: self?.menuElements(actions, ids: ids, at: indexPaths[0]) ?? [])
            }
        }

        /// Each group is an inline menu (UIKit draws the separators between them); actions with children are submenus,
        /// sharing opens the share sheet from the tile.
        func menuElements(_ actions: [GridMenuAction], ids: [FileID], at indexPath: IndexPath) -> [UIMenuElement] {
            GridMenuAction.groups(actions).map { group in
                UIMenu(
                    options: .displayInline,
                    children: group.map { action -> UIMenuElement in
                        let image = UIImage(systemName: action.systemImage)
                        if !action.children.isEmpty {
                            let children: [UIMenuElement] = menuElements(action.children, ids: ids, at: indexPath)
                            return UIMenu(title: action.title, image: image, children: children)
                        }
                        if let share = action.share {
                            return UIAction(title: action.title, image: image) { [weak self] _ in
                                self?.presentShareSheet(share(), from: indexPath)
                            }
                        }
                        return UIAction(title: action.title, image: image, attributes: action.isDestructive ? .destructive : []) { _ in
                            action.handler(ids)
                        }
                    })
            }
        }

        func presentShareSheet(_ providers: [NSItemProvider], from indexPath: IndexPath) {
            guard !providers.isEmpty else { return }
            let sheet = UIActivityViewController(activityItemsConfiguration: UIActivityItemsConfiguration(itemProviders: providers))
            if let popover = sheet.popoverPresentationController {
                if let cell = collectionView.cellForItem(at: indexPath) {
                    popover.sourceView = cell
                    popover.sourceRect = cell.bounds
                } else {
                    popover.sourceView = collectionView
                }
            }
            present(sheet, animated: true)
        }

        // MARK: Edit ▸ Copy (⌘C on iPad)

        override func copy(_ sender: Any?) {
            guard !selected.ids.isEmpty else { return }
            callbacks?.copy?(Array(selected.ids))
        }

        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            if action == #selector(copy(_:)) { return callbacks?.copy != nil && !selected.ids.isEmpty }
            return super.canPerformAction(action, withSender: sender)
        }

        /// A tap on the menu's preview opens the photo.
        func collectionView(
            _ collectionView: UICollectionView, willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration,
            animator: any UIContextMenuInteractionCommitAnimating
        ) {
            guard !isSelecting, let id = (configuration.identifier as? NSNumber)?.int64Value else { return }
            animator.preferredCommitStyle = .dismiss
            animator.addCompletion { [weak self] in self?.callbacks?.open(id) }
        }

        // MARK: Drag out (iPad: Files, Notes, Mail…): the original is downloaded when it is dropped.

        func collectionView(_ collectionView: UICollectionView, itemsForBeginning session: any UIDragSession, at indexPath: IndexPath)
            -> [UIDragItem]
        {
            guard let id = fileId(at: indexPath) else { return [] }
            let model = model
            let ids = GridDrag.ids(dragged: id, selection: currentSelection(), isSelecting: isSelecting) { id in
                model.position(of: id).flatMap { model.flatIndex(section: $0.section, item: $0.item) }
            }
            return ids.compactMap { dragItem(for: $0) }
        }

        /// A tap on another tile during a drag adds it.
        func collectionView(
            _ collectionView: UICollectionView, itemsForAddingTo session: any UIDragSession, at indexPath: IndexPath, point: CGPoint
        ) -> [UIDragItem] {
            guard let id = fileId(at: indexPath), !session.items.contains(where: { ($0.localObject as? NSNumber)?.int64Value == id })
            else { return [] }
            return [dragItem(for: id)].compactMap { $0 }
        }

        private func dragItem(for id: FileID) -> UIDragItem? {
            guard let item = model[id] else { return nil }
            let dragItem = UIDragItem(itemProvider: GridDrag.itemProvider(for: item, services: services))
            dragItem.localObject = NSNumber(value: id)
            return dragItem
        }

        func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
            let requests = previewRequests(at: indexPaths)
            Task { await services.images.prefetch(requests) }
        }

        /// The items left the prefetch window (the scroll turned round): their previews are not loaded unless shown.
        func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
            let requests = previewRequests(at: indexPaths)
            Task { await services.images.cancelPrefetch(for: requests) }
        }

        private func previewRequests(at indexPaths: [IndexPath]) -> [ImagePipeline.Request] {
            core.previewRequests(at: indexPaths, width: gridWidth, scale: previewScale)
        }
    }

    final class PhotoCell: UICollectionViewCell {
        static let reuseIdentifier = "PhotoCell"
        private let imageView = UIImageView()
        private let placeholderIcon = UIImageView()
        private let durationLabel = UILabel()
        private let videoIcon = UIImageView(image: UIImage(systemName: "video.fill"))
        private let favoriteIcon = UIImageView(image: UIImage(systemName: "heart.fill"))
        private let liveIcon = UIImageView(image: UIImage(systemName: "livephoto"))
        private let stackIcon = UIImageView(image: UIImage(systemName: "square.stack.fill"))
        private let partnerIcon = UIImageView(image: UIImage(systemName: GridTileBadges.partnerSymbol))
        private let checkmark = UIImageView()
        private let gradient = CAGradientLayer()
        /// Rating and flag (SPEC §15.2); rejected photos are dimmed.
        private let cullingBadge = CullingBadgeView()
        private var isDimmed = false
        private var isTileSelected = false
        /// Loads the preview and says what to draw; shared with the AppKit grid.
        private let tilePicture = GridTilePicture()
        var fileId: FileID? { tilePicture.fileId }
        private var menuActions: (() -> [GridMenuAction])?
        /// Square tile, or the picture whole in the photo's shape (`TileStyle`).
        private var square = true
        private var aspectRatio = 1.0

        override init(frame: CGRect) {
            super.init(frame: frame)
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.backgroundColor = .secondarySystemFill
            contentView.addSubview(imageView)
            placeholderIcon.tintColor = .tertiaryLabel
            placeholderIcon.contentMode = .scaleAspectFit
            placeholderIcon.isHidden = true
            contentView.addSubview(placeholderIcon)
            contentView.layer.addSublayer(gradient)
            durationLabel.font = .monospacedDigitSystemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize, weight: .semibold)
            durationLabel.textColor = .white
            for icon in [favoriteIcon, liveIcon, videoIcon, partnerIcon] {
                icon.tintColor = .white
                icon.contentMode = .scaleAspectFit
            }
            // The top edge has no shade: a soft shadow keeps the white badge visible on bright pictures.
            partnerIcon.layer.shadowColor = UIColor.black.cgColor
            partnerIcon.layer.shadowOpacity = 0.5
            partnerIcon.layer.shadowRadius = 1.5
            partnerIcon.layer.shadowOffset = .zero
            partnerIcon.isHidden = true
            checkmark.contentMode = .scaleAspectFit
            // The empty circle is white on the photo: a soft shadow keeps it visible on bright pictures.
            checkmark.layer.shadowColor = UIColor.black.cgColor
            checkmark.layer.shadowOpacity = 0.35
            checkmark.layer.shadowRadius = 1.5
            checkmark.layer.shadowOffset = .zero
            // On the picture without a shade: a soft shadow keeps it visible on bright pictures.
            stackIcon.tintColor = .white
            stackIcon.contentMode = .scaleAspectFit
            stackIcon.layer.shadowColor = UIColor.black.cgColor
            stackIcon.layer.shadowOpacity = 0.5
            stackIcon.layer.shadowRadius = 1.5
            stackIcon.layer.shadowOffset = .zero
            stackIcon.isHidden = true
            [durationLabel, videoIcon, favoriteIcon, liveIcon, stackIcon, partnerIcon, cullingBadge, checkmark].forEach {
                contentView.addSubview($0)
            }
            // Pointer (iPad trackpad or mouse) and gaze (Vision Pro): the tile under it is highlighted.
            hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect)
            tilePicture.show = { [weak self] display in self?.show(display) }
            isAccessibilityElement = true
            // Double-tap (VoiceOver), Switch Control and Voice Control activate the cell like a tap: it opens the photo.
            accessibilityTraits = [.image, .button]
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layoutSubviews() {
            super.layoutSubviews()
            // The picture's place in the tile: all of it, or the photo's shape in the aspect ratio grid. Badges and
            // the selection mark go with the picture.
            let bounds = GridTile.pictureFrame(in: contentView.bounds, aspectRatio: aspectRatio, square: square)
            let x = bounds.minX
            let y = bounds.minY
            imageView.frame = bounds
            let glyph = min(max(bounds.width * 0.34, 14), 44)
            placeholderIcon.frame = CGRect(
                x: x + (bounds.width - glyph) / 2, y: y + (bounds.height - glyph) / 2, width: glyph, height: glyph)
            gradient.frame = CGRect(x: x, y: y + bounds.height * 0.6, width: bounds.width, height: bounds.height * 0.4)
            // The selection mark sits in the bottom trailing corner, as in Apple Photos; duration and video badge
            // move left of it.
            let mark = CGFloat(GridTile.checkmarkSide(tileSide: Double(min(bounds.width, bounds.height))))
            checkmark.frame = CGRect(x: bounds.maxX - mark - 4, y: bounds.maxY - mark - 4, width: mark, height: mark)
            let markShown = !checkmark.isHidden
            let trailingBadges = GridTile.showsTrailingBadges(tileSide: Double(bounds.width), checkmarkShown: markShown)
            durationLabel.alpha = trailingBadges ? 1 : 0
            videoIcon.alpha = trailingBadges ? 1 : 0
            durationLabel.sizeToFit()
            var right = markShown ? checkmark.frame.minX - 4 : bounds.maxX - 4
            if !durationLabel.isHidden {
                durationLabel.frame.origin = CGPoint(
                    x: right - durationLabel.bounds.width, y: bounds.maxY - durationLabel.bounds.height - 3)
                right = durationLabel.frame.minX - 3
            }
            videoIcon.frame = CGRect(x: right - 16, y: bounds.maxY - 16, width: 16, height: 12)
            favoriteIcon.frame = CGRect(x: x + 4, y: bounds.maxY - 16, width: 13, height: 12)
            // The flag and stars take the top leading corner; the Live Photo badge follows them.
            let cullingWidth = cullingBadge.fittingWidth
            cullingBadge.frame = CGRect(x: x + 5, y: y + 5, width: cullingWidth, height: 15)
            liveIcon.frame = CGRect(x: x + 4 + (cullingWidth > 0 ? cullingWidth + 4 : 0), y: y + 4, width: 16, height: 16)
            stackIcon.frame = CGRect(x: bounds.maxX - 20, y: y + 4, width: 16, height: 16)
            // Both in the top trailing corner: the partner badge moves left of the stack badge.
            let partnerRight = stackIcon.isHidden ? bounds.maxX - 4 : stackIcon.frame.minX - 3
            partnerIcon.frame = CGRect(x: partnerRight - 17, y: y + 4, width: 17, height: 14)
        }

        /// The picture the tile shows right now (first picture of the context menu's preview).
        var picture: UIImage? { tilePicture.hasPicture ? imageView.image : nil }

        /// Called by UIKit whenever the cell is selected or deselected and when the collection view starts or stops
        /// editing (the selection mode), also for cells that are not on screen yet.
        override func updateConfiguration(using state: UICellConfigurationState) {
            super.updateConfiguration(using: state)
            updateSelection(editing: state.isEditing, selected: state.isSelected)
        }

        func updateSelection(editing: Bool, selected: Bool) {
            let wasHidden = checkmark.isHidden
            checkmark.isHidden = !(editing || selected)
            checkmark.image =
                selected
                ? UIImage(
                    systemName: "checkmark.circle.fill",
                    withConfiguration: UIImage.SymbolConfiguration(paletteColors: [.white, .tintColor]))
                : UIImage(systemName: "circle")
            // Selected: a white tick on the accent colour (the view's inherited tint). Not selected: a white ring.
            checkmark.tintColor = selected ? nil : .white
            isTileSelected = selected
            imageView.alpha = (selected ? 0.75 : 1) * (isDimmed ? 0.4 : 1)
            if selected { accessibilityTraits.insert(.selected) } else { accessibilityTraits.remove(.selected) }
            // The badges make room for the mark.
            if wasHidden != checkmark.isHidden { setNeedsLayout() }
        }

        /// Shows `item`. Called again for the same item when its badges, the zoom or the screen scale change: the
        /// picture then stays until a sharper one has loaded (no flash).
        func configure(item: GridMedia, owner: PhotoGridController, tileSide: Double, scale: Double) {
            let services = owner.services
            if square != owner.squareTiles || aspectRatio != item.aspectRatio {
                square = owner.squareTiles
                aspectRatio = item.aspectRatio
                setNeedsLayout()
            }
            updateBadges(item, owner: owner)
            let culling = CullingTileBadge(owner.culling.mark(item.fileId), tileSide: tileSide)
            cullingBadge.show(culling)
            isDimmed = culling.isDimmed
            imageView.alpha = (isTileSelected ? 0.75 : 1) * (isDimmed ? 0.4 : 1)
            if let text = culling.accessibilityText { accessibilityLabel = (accessibilityLabel ?? "") + ", " + text }
            setNeedsUpdateConfiguration()
            tilePicture.configure(
                item: item, request: services.previewRequest(for: item, tileSide: tileSide, scale: scale, square: square),
                source: GridTilePicture.Source(services: services))
        }

        /// A tile of the first sync's skeleton: grey, nothing on it, nothing to open.
        func showPlaceholder() {
            tilePicture.reset()
            square = true
            let badges: [UIView] = [durationLabel, videoIcon, favoriteIcon, liveIcon, stackIcon, partnerIcon, cullingBadge]
            for badge in badges { badge.isHidden = true }
            isDimmed = false
            gradient.isHidden = true
            menuActions = nil
            accessibilityLabel = String(localized: "Loading…", bundle: .module)
            setNeedsLayout()
        }

        private func show(_ display: GridTilePicture.Display) {
            switch display {
            case .clear:
                imageView.image = nil
                placeholderIcon.isHidden = true
            case .blur(let image):
                imageView.image = UIImage(cgImage: image)
            case .picture(let image):
                imageView.image = UIImage(cgImage: image)
                placeholderIcon.isHidden = true
            case .placeholder(let symbol):
                placeholderIcon.image = UIImage(systemName: symbol)
                placeholderIcon.isHidden = false
            }
        }

        private func updateBadges(_ item: GridMedia, owner: PhotoGridController) {
            let badges = GridTileBadges(item: item, isPartner: owner.services.partnerPaths.contains(directory: item.directory))
            partnerIcon.isHidden = !badges.showsPartner
            durationLabel.text = badges.duration
            durationLabel.isHidden = badges.duration == nil
            videoIcon.isHidden = !badges.showsVideo
            favoriteIcon.isHidden = !badges.showsFavorite
            liveIcon.isHidden = !badges.showsLivePhoto
            stackIcon.isHidden = !badges.showsStack
            gradient.isHidden = !badges.showsShade
            let increased = UIAccessibility.isDarkerSystemColorsEnabled || UIAccessibility.isReduceTransparencyEnabled
            gradient.colors = [
                UIColor.clear.cgColor, UIColor.black.withAlphaComponent(GridTile.shadeOpacity(increased: increased)).cgColor,
            ]
            accessibilityLabel = badges.accessibilityLabel
            let id = item.fileId
            menuActions = { [weak owner] in owner?.menuActions(for: id) ?? [] }
            setNeedsLayout()
        }

        /// The context menu actions (favourite, archive, delete…) for VoiceOver's actions rotor.
        override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
            get {
                guard let fileId, let actions = menuActions?() else { return nil }
                return GridMenuAction.flattened(actions).map { action in
                    UIAccessibilityCustomAction(name: action.title) { _ in
                        action.handler([fileId])
                        return true
                    }
                }
            }
            set {}
        }

        override func prepareForReuse() {
            super.prepareForReuse()
            tilePicture.reset()
        }
    }

    /// The large picture above a tile's context menu: what the tile shows at once, then the 1024 px preview.
    final class GridMenuPreviewController: UIViewController {
        private let item: GridMedia
        private let services: AccountServices
        private let imageView = UIImageView()
        private var task: Task<Void, Never>?

        init(item: GridMedia, services: AccountServices, placeholder: UIImage?) {
            self.item = item
            self.services = services
            super.init(nibName: nil, bundle: nil)
            imageView.image = placeholder
            preferredContentSize = GridTile.previewSize(aspectRatio: item.aspectRatio)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .secondarySystemBackground
            imageView.frame = view.bounds
            imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            // Fills the preview, which has the photo's shape: nothing is cut off unless the stored size was wrong.
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            view.addSubview(imageView)
            let request = services.menuPreviewRequest(for: item)
            let services = services
            task = Task { [weak self] in
                guard let image = await services.images.preview(request), !Task.isCancelled, let self else { return }
                self.imageView.image = UIImage(cgImage: image)
                // The index does not know the size of every file: the picture itself does.
                self.preferredContentSize = GridTile.previewSize(aspectRatio: Double(image.width) / Double(max(image.height, 1)))
            }
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            task?.cancel()
        }
    }

    final class SectionHeader: UICollectionReusableView {
        static let reuseIdentifier = "SectionHeader"
        static var titleFont: UIFont { .preferredFont(forTextStyle: .title2).withWeight(.bold) }
        static var subtitleFont: UIFont { .preferredFont(forTextStyle: .subheadline).withWeight(.semibold) }
        private let titleLabel = UILabel()
        private let subtitleLabel = UILabel()
        private let background = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
        private var metrics = GridHeaderMetrics(titleHeight: 28, subtitleHeight: 20)

        override init(frame: CGRect) {
            super.init(frame: frame)
            addSubview(background)
            subtitleLabel.textColor = .secondaryLabel
            titleLabel.accessibilityTraits = .header
            addSubview(titleLabel)
            addSubview(subtitleLabel)
        }

        required init?(coder: NSCoder) { fatalError() }

        /// Laid out by hand from the same metrics the layout takes the header height from, so nothing is clipped.
        override func layoutSubviews() {
            super.layoutSubviews()
            background.frame = bounds
            let area = bounds.inset(by: layoutMargins)
            var y = CGFloat(metrics.top)
            if !titleLabel.isHidden {
                titleLabel.frame = CGRect(x: area.minX, y: y, width: area.width, height: CGFloat(metrics.titleHeight))
                y += CGFloat(metrics.titleHeight + metrics.gap)
            }
            if !subtitleLabel.isHidden {
                subtitleLabel.frame = CGRect(x: area.minX, y: y, width: area.width, height: CGFloat(metrics.subtitleHeight))
            }
        }

        func configure(_ text: GridHeaderText, metrics: GridHeaderMetrics) {
            self.metrics = metrics
            titleLabel.font = Self.titleFont
            subtitleLabel.font = Self.subtitleFont
            titleLabel.text = text.title
            titleLabel.isHidden = text.title == nil
            subtitleLabel.text = text.subtitle
            subtitleLabel.isHidden = text.subtitle == nil
            setNeedsLayout()
        }
    }

    extension UIFont {
        func withWeight(_ weight: UIFont.Weight) -> UIFont {
            UIFont.systemFont(ofSize: pointSize, weight: weight)
        }
    }
#endif
