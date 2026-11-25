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

    /// The photo grid on macOS (SPEC §6.4): rubber-band, ⇧/⌘-click selection and arrow keys come from NSCollectionView.
    ///
    /// It reaches up under the window's toolbar (SPEC §17.7): the photos scroll under the glass toolbar, which blurs and
    /// fades them with the system's scroll edge effect; the scroll view's automatic insets keep the first row below it.
    struct PhotoGrid: View {
        var update: GridFeed.Update
        var zoomStep: Int
        var selection: Set<FileID>
        var isSelecting: Bool
        var showsHeaders: Bool
        var squareTiles = true
        var moments = MomentHeaders.none
        /// Unused on the Mac: the Library's memories stay above the grid (SPEC §17.2).
        var header: AnyView? = nil
        var services: AccountServices
        var callbacks: GridCallbacks
        /// Hero headers are not the Mac's (SPEC §17.4).
        var hero: GridHero? = nil

        var body: some View {
            PhotoGridHost(
                update: update, zoomStep: zoomStep, selection: selection, isSelecting: isSelecting, showsHeaders: showsHeaders,
                squareTiles: squareTiles, moments: moments, header: header, services: services, callbacks: callbacks, hero: hero
            )
            .ignoresSafeArea(.container, edges: .top)
        }
    }

    struct PhotoGridHost: NSViewRepresentable {
        var update: GridFeed.Update
        /// Zoom step (`GridColumns.options`): sets the target tile size, the columns follow from the width.
        var zoomStep: Int
        var selection: Set<FileID>
        var isSelecting: Bool
        var showsHeaders: Bool
        /// Square tiles, or each picture whole in its tile (`TileStyle`).
        var squareTiles = true
        /// Moment titles on the day headers (the Library, SPEC §16.1).
        var moments = MomentHeaders.none
        /// Not used on the Mac: the Library keeps its memories above the grid.
        var header: AnyView? = nil
        var services: AccountServices
        var callbacks: GridCallbacks
        /// Hero headers are not the Mac's (SPEC §17.4): the title stays in the window's toolbar.
        var hero: GridHero? = nil

        func makeNSView(context: Context) -> PhotoGridScrollView {
            PhotoGridScrollView(services: services)
        }

        func updateNSView(_ view: PhotoGridScrollView, context: Context) {
            view.callbacks = callbacks
            view.update(update, zoomStep: zoomStep, selection: selection, showsHeaders: showsHeaders, squareTiles: squareTiles)
            view.setMoments(moments)
        }
    }

    final class PhotoGridScrollView: NSScrollView, NSCollectionViewDataSource, NSCollectionViewDelegate, NSCollectionViewPrefetching {
        let services: AccountServices
        var callbacks: GridCallbacks? {
            didSet {
                // "Show in library" scrolls to a tile (the zoom transition the locator serves elsewhere is not the Mac's).
                callbacks?.tileLocator?.reveal = { [weak self] id in self?.reveal(id) }
                callbacks?.tileLocator?.place = { [weak self] id, fraction in self?.place(id, fraction: fraction) }
                callbacks?.tileLocator?.topItem = { [weak self] in self?.anchorItem() }
                callbacks?.motion?.favorited = { [weak self] ids in self?.playHeartBursts(ids) }
                // The Library's zoom levels morph into and out of the tiles (SPEC §17.5).
                callbacks?.tileLocator?.frame = { [weak self] id in self?.tileFrame(id) }
                callbacks?.tileLocator?.coveredChanged = { [weak self] covered in self?.setAccessibilityHidden(covered) }
                setAccessibilityHidden(callbacks?.tileLocator?.isCovered ?? false)
            }
        }
        let collectionView = GridCollectionView()
        /// Model, zoom, anchor and layout bookkeeping, shared with the UIKit grid.
        private let core: GridCore
        /// The photo under the pointer when a trackpad pinch began, and its distance from the top of the visible area: it
        /// stays there while the pinch changes the zoom step (SPEC §15.5).
        private var pinchAnchor: (id: FileID, offset: CGFloat)?
        private let scrubber = GridScrubberView()
        private var sectionOffsets: [Double] = []
        private var refreshWork: DispatchWorkItem?
        private var selected = GridSelectionTracker()
        private lazy var promiseDelegate = FilePromiseDelegate(services: services)
        /// Ratings and flags shown on the tiles (SPEC §15.2).
        let culling: GridCullingObserver
        /// Edited photos' tiles are drawn again with their new rendition (SPEC §16.3).
        private let edits = GridEditObserver()
        /// Scrub to peek with the pointer (SPEC §16.1).
        private var peek: GridPeekHover?
        /// The tile under the pointer lifts (SPEC §17.7).
        private var hoverLift: GridHoverLift?
        /// A trackpad pinch zooms continuously between the steps (SPEC §17.7).
        private var pinchZoom = GridPinchZoom()
        private lazy var pinchScaler = GridPinchScaler(clipView: contentView)
        /// A pinch asked for another step: its relayout cross-fades from the scaled grid.
        private var pinchStepPending = false

        var model: GridModel { core.model }
        var squareTiles: Bool { core.squareTiles }
        private var zoomStep: Int { core.zoomStep }
        private var headerMetrics: GridHeaderMetrics { core.headerMetrics }

        init(services: AccountServices) {
            self.services = services
            core = GridCore(services: services, headerMetrics: GridHeaderMetrics(titleHeight: 26, subtitleHeight: 16))
            culling = GridCullingObserver(services: services)
            super.init(frame: .zero)
            culling.changed = { [weak self] ids in self?.refreshVisibleTiles(only: ids) }
            edits.changed = { [weak self] ids in self?.refreshVisibleTiles(only: ids) }
            collectionView.collectionViewLayout = makeLayout()
            collectionView.isSelectable = true
            collectionView.allowsMultipleSelection = true
            collectionView.allowsEmptySelection = true
            collectionView.dataSource = self
            collectionView.delegate = self
            collectionView.prefetchDataSource = self
            collectionView.backgroundColors = [.clear]
            collectionView.register(PhotoItem.self, forItemWithIdentifier: PhotoItem.identifier)
            collectionView.register(
                SectionHeaderView.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                withIdentifier: SectionHeaderView.identifier)
            collectionView.owner = self
            collectionView.setDraggingSourceOperationMask(.copy, forLocal: false)
            documentView = collectionView
            hasVerticalScroller = true
            drawsBackground = false

            let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick(_:)))
            doubleClick.numberOfClicksRequired = 2
            doubleClick.delaysPrimaryMouseButtonEvents = false
            collectionView.addGestureRecognizer(doubleClick)
            let magnify = NSMagnificationGestureRecognizer(target: self, action: #selector(handleMagnify(_:)))
            collectionView.addGestureRecognizer(magnify)

            scrubber.isHidden = true
            scrubber.labelAt = { [weak self] fraction in self?.scrubberLabel(at: fraction) ?? "" }
            scrubber.onScrub = { [weak self] fraction in self?.scroll(toFraction: fraction) }
            scrubber.onStep = { [weak self] delta in self?.scrollToYear(delta: delta) }
            addSubview(scrubber)
            peek = GridPeekHover(host: self)
            let lift = GridHoverLift(host: self)
            hoverLift = lift
            // A peek takes the tile's place: it is not lifted meanwhile.
            peek?.began = { [weak lift] in lift?.drop() }
            contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(didScroll(_:)), name: NSView.boundsDidChangeNotification, object: contentView)
        }

        required init?(coder: NSCoder) { fatalError() }

        // MARK: Geometry

        /// Width the tiles are laid out in.
        private var gridWidth: Double { Double(collectionView.bounds.width) }

        /// Columns and tile side for the current width and zoom.
        var geometry: GridGeometry { core.geometry(width: gridWidth) }

        private var backingScale: Double { Double(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2) }

        private var headersShown: Bool { core.headersShown }

        private func headerHeight(section: Int) -> Double { core.headerHeight(section: section) }

        func makeLayout() -> NSCollectionViewLayout {
            NSCollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
                // Whole points: fractional tiles are drawn blurry by AppKit.
                self?.core.sectionMetrics(sectionIndex, width: Double(environment.container.effectiveContentSize.width), wholePoints: true)
                    .layoutSection(headerKind: NSCollectionView.elementKindSectionHeader)
            }
        }

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
        private func playHeartBursts(_ ids: [FileID]) {
            guard window != nil else { return }
            let wanted = Set(ids)
            for case let tile as PhotoItem in collectionView.visibleItems() {
                guard let id = tile.fileId, wanted.contains(id) else { continue }
                tile.playHeartBurst()
            }
        }

        /// Reconfigures the tiles on screen: badges, and a preview that fits the current tile size. A tile keeps the
        /// picture it shows until the better one is there.
        private func refreshVisibleTiles(only ids: Set<FileID>? = nil) {
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

        // MARK: Scroll position

        private var topInset: CGFloat { contentInsets.top }

        private var isAtTop: Bool { contentView.bounds.minY <= -topInset + 1 }

        /// The first item below the pinned header, unless the grid is scrolled to the top (then it stays there).
        /// Taken from the layout, not from the views on screen, which lag behind right after a relayout.
        private func anchorItem() -> FileID? {
            let top = contentView.bounds.minY + topInset
            return core.anchorItem(isAtTop: isAtTop, top: Double(top)) { [self] in
                guard let layout = collectionView.collectionViewLayout else { return [] }
                let strip = NSRect(x: 0, y: top, width: collectionView.bounds.width, height: CGFloat(geometry.side) + 80)
                return layout.layoutAttributesForElements(in: strip).compactMap { attributes in
                    guard attributes.representedElementCategory == .item, let indexPath = attributes.indexPath else { return nil }
                    return GridAnchor.Candidate(section: indexPath.section, item: indexPath.item, maxY: Double(attributes.frame.maxY))
                }
            }
        }

        private func restore(_ anchor: FileID?) {
            core.restore(anchor) { [weak self] anchor in self?.restoreNow(anchor) }
        }

        private func restoreNow(_ anchor: FileID) {
            guard let indexPath = core.indexPath(for: anchor) else { return }
            collectionView.needsLayout = true
            collectionView.layoutSubtreeIfNeeded()
            // Scrolling is limited by the document's frame, which can still be the one of the old layout.
            if let height = collectionView.collectionViewLayout?.collectionViewContentSize.height, collectionView.frame.height < height {
                collectionView.setFrameSize(NSSize(width: collectionView.frame.width, height: height))
            }
            guard let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame else { return }
            scroll(toDocumentY: frame.minY - CGFloat(headerHeight(section: indexPath.section)))
        }

        /// The tile's frame in this view, top-left origin as SwiftUI measures it; nil when it is not on screen.
        func tileFrame(_ id: FileID) -> CGRect? {
            guard let indexPath = core.indexPath(for: id), let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame,
                contentView.documentVisibleRect.intersects(frame)
            else { return nil }
            let local = convert(frame, from: collectionView)
            return isFlipped ? local : CGRect(x: local.minX, y: bounds.height - local.maxY, width: local.width, height: local.height)
        }

        /// Scrolls so that the tile's top is at `fraction` of the visible height (a zoom from the days).
        func place(_ id: FileID, fraction: Double) {
            place(id, offset: topInset + CGFloat(fraction) * max(contentView.bounds.height - topInset, 0))
        }

        /// Scrolls so that the tile's middle is `offset` below the top of the clip view, now and after the layout pass.
        private func place(_ id: FileID, offset: CGFloat) {
            core.restore(id) { [weak self] id in
                guard let self, let indexPath = self.core.indexPath(for: id) else { return }
                self.collectionView.needsLayout = true
                self.collectionView.layoutSubtreeIfNeeded()
                if let height = self.collectionView.collectionViewLayout?.collectionViewContentSize.height,
                    self.collectionView.frame.height < height
                {
                    self.collectionView.setFrameSize(NSSize(width: self.collectionView.frame.width, height: height))
                }
                guard let frame = self.collectionView.layoutAttributesForItem(at: indexPath)?.frame else { return }
                self.scroll(toDocumentY: frame.midY - offset + self.topInset)
            }
        }

        /// Scrolls the tile into the middle of the visible area if it is not wholly visible.
        func reveal(_ id: FileID) {
            guard let indexPath = core.indexPath(for: id) else { return }
            collectionView.layoutSubtreeIfNeeded()
            if let height = collectionView.collectionViewLayout?.collectionViewContentSize.height, collectionView.frame.height < height {
                collectionView.setFrameSize(NSSize(width: collectionView.frame.width, height: height))
            }
            guard let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame else { return }
            var visible: NSRect = contentView.bounds
            visible.origin.y += topInset
            visible.size.height -= topInset
            guard !visible.contains(frame) else { return }
            scroll(toDocumentY: frame.midY - visible.height / 2)
        }

        /// Scrolls so that the document offset `y` is at the top of the visible area (below the toolbar).
        private func scroll(toDocumentY y: CGFloat) {
            let offset = GridAnchor.offset(
                documentY: Double(y), topInset: Double(topInset), contentHeight: Double(collectionView.frame.height),
                viewportHeight: Double(contentView.bounds.height))
            contentView.scroll(to: NSPoint(x: contentView.bounds.minX, y: CGFloat(offset)))
            reflectScrolledClipView(contentView)
        }

        override func setFrameSize(_ newSize: NSSize) {
            if newSize.width != frame.width, core.resizeAnchor == nil { core.resizeAnchor = anchorItem() }
            super.setFrameSize(newSize)
        }

        override func layout() {
            super.layout()
            if core.columnsChanged(width: gridWidth) {
                restore(core.resizeAnchor)
                reloadScrubber()
            }
            core.resizeAnchor = nil
            if core.sideChanged(width: gridWidth) {
                // The tile size follows the width: fetch sharper previews once resizing has settled.
                refreshWork?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.refreshVisibleTiles() }
                refreshWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
            }
            core.noteLayout(width: gridWidth)
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            // Moved to a screen with another scale: the tiles need other previews.
            refreshVisibleTiles()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Arrow keys, Return and Space work without clicking into the grid first.
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window, window.firstResponder === window else { return }
                window.makeFirstResponder(self.collectionView)
            }
        }

        // MARK: Date scrubber

        override func tile() {
            super.tile()
            let clip = contentView.frame
            let width = min(GridScrubberView.width, clip.width)
            scrubber.frame = NSRect(
                x: clip.maxX - width, y: isFlipped ? clip.minY + topInset : clip.minY, width: width, height: max(clip.height - topInset, 0))
        }

        private var scrollRange: Double {
            Double(collectionView.frame.height - contentView.bounds.height + topInset)
        }

        private func reloadScrubber() {
            let visibleHeight = Double(contentView.bounds.height - topInset)
            guard headersShown, visibleHeight > 0 else {
                scrubber.isHidden = true
                return
            }
            let sections = model.sections
            // Placeholder tiles (the first sync's skeleton) count: the scrubber covers the whole library.
            sectionOffsets = geometry.sectionOffsets(
                itemCounts: sections.map(\.tileCount), headerHeights: sections.map { headerMetrics.height(for: $0) })
            let total = sectionOffsets.last ?? 0
            let range = total - visibleHeight
            // Not worth it for a library that fits on two screens.
            guard range > visibleHeight else {
                scrubber.isHidden = true
                return
            }
            scrubber.isHidden = false
            scrubber.ticks = model.yearStarts.map { entry in
                GridScrubberView.Tick(fraction: min(sectionOffsets[entry.section] / range, 1), label: String(entry.year))
            }
        }

        private func section(atFraction fraction: Double) -> GridSection? {
            guard let total = sectionOffsets.last else { return nil }
            let range = max(total - Double(contentView.bounds.height - topInset), 0)
            // The section under the pinned header, i.e. the one whose items are at the top.
            guard let index = GridGeometry.section(at: fraction * range + 1, in: sectionOffsets) else { return nil }
            return model.sections[safe: index]
        }

        private func scrubberLabel(at fraction: Double) -> String {
            section(atFraction: fraction).map(GridHeaderTexts.scrubberLabel) ?? ""
        }

        private var scrollFraction: Double {
            let range = scrollRange
            return range > 0 ? min(max(Double(contentView.bounds.minY + topInset) / range, 0), 1) : 0
        }

        private func scroll(toFraction fraction: Double) {
            scroll(toDocumentY: CGFloat(fraction * scrollRange))
        }

        /// Jumps to the start of the next older (+1) or newer (−1) year.
        private func scrollToYear(delta: Int) {
            let years = model.yearStarts
            guard !years.isEmpty, let current = section(atFraction: scrollFraction)?.year,
                let index = years.firstIndex(where: { $0.year == current })
            else { return }
            let target = years[max(0, min(years.count - 1, index + delta))]
            guard target.section < sectionOffsets.count else { return }
            scroll(toDocumentY: CGFloat(sectionOffsets[target.section]))
        }

        @objc private func didScroll(_ notification: Notification) {
            // A peek belongs to the tile under the pointer; the grid moved away under it.
            if peek?.isPeeking == true { peek?.end() }
            hoverLift?.drop()
            guard !scrubber.isHidden else { return }
            let fraction = scrollFraction
            scrubber.scrolled(to: fraction, label: scrubberLabel(at: fraction))
        }

        // MARK: Data source

        func numberOfSections(in collectionView: NSCollectionView) -> Int { model.sections.count }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            model.numberOfItems(inSection: section)
        }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let tile = collectionView.makeItem(withIdentifier: PhotoItem.identifier, for: indexPath) as! PhotoItem
            if let item = model.item(section: indexPath.section, item: indexPath.item) {
                tile.configure(item: item, owner: self, tileSide: geometry.side, scale: backingScale)
            } else {
                // A photo the first sync has not loaded yet.
                tile.showPlaceholder()
            }
            return tile
        }

        func collectionView(
            _ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
            at indexPath: IndexPath
        ) -> NSView {
            let view =
                collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: SectionHeaderView.identifier, for: indexPath)
                as! SectionHeaderView
            configure(view, section: indexPath.section)
            return view
        }

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

        private func configure(_ header: SectionHeaderView, section index: Int) {
            guard let section = model.sections[safe: index] else { return }
            header.configure(core.headerTexts.text(for: section), metrics: headerMetrics)
            header.openMoment = { [weak self] id in self?.callbacks?.openMoment?(id) }
        }

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

        // MARK: Drag out (Finder, Mail…): file promises download the original only when dropped.

        func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
            true
        }

        func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> (
            any NSPasteboardWriting
        )? {
            guard let item = model.item(section: indexPath.section, item: indexPath.item) else { return nil }
            let type = UTType(mimeType: item.mimeType) ?? .data
            let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: promiseDelegate)
            provider.userInfo = ["fileId": item.fileId, "name": item.name]
            return provider
        }

        /// Placeholder tiles of the first sync's skeleton cannot be selected.
        func collectionView(_ collectionView: NSCollectionView, shouldSelectItemsAt indexPaths: Set<IndexPath>) -> Set<IndexPath> {
            indexPaths.filter { fileId(at: $0) != nil }
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            selected.insert(indexPaths.lazy.compactMap { self.fileId(at: $0) })
            callbacks?.selectionChanged(currentSelection())
        }

        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            selected.remove(indexPaths.lazy.compactMap { self.fileId(at: $0) })
            callbacks?.selectionChanged(currentSelection())
        }

        func collectionView(_ collectionView: NSCollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
            let requests = previewRequests(at: indexPaths)
            Task { await services.images.prefetch(requests) }
        }

        /// The items left the prefetch window (the scroll turned round): their previews are not loaded unless shown.
        func collectionView(_ collectionView: NSCollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
            let requests = previewRequests(at: indexPaths)
            Task { await services.images.cancelPrefetch(for: requests) }
        }

        private func previewRequests(at indexPaths: [IndexPath]) -> [ImagePipeline.Request] {
            core.previewRequests(at: indexPaths, width: gridWidth, scale: backingScale)
        }
    }

    /// Writes originals for file promises (drag to Finder and other apps).
    /// Peeks with the pointer (`GridGestures+AppKit`) work on this grid.
    extension PhotoGridScrollView: GridPeekHost {}

    final class FilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
        let services: AccountServices
        let queue: OperationQueue = {
            let queue = OperationQueue()
            queue.qualityOfService = .userInitiated
            return queue
        }()

        init(services: AccountServices) {
            self.services = services
        }

        func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
            ((filePromiseProvider.userInfo as? [String: Any])?["name"] as? String) ?? "Photo"
        }

        func filePromiseProvider(
            _ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping ((any Error)?) -> Void
        ) {
            guard let fileId = (filePromiseProvider.userInfo as? [String: Any])?["fileId"] as? FileID,
                let item = try? services.library.item(fileId)
            else {
                completionHandler(CocoaError(.fileNoSuchFile))
                return
            }
            let services = self.services
            let semaphore = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var result: (any Error)?
            Task.detached {
                do {
                    let original = try await services.images.originals.original(
                        fileId: item.fileId, etag: item.etag, url: services.originalURL(for: item))
                    try? FileManager.default.removeItem(at: url)
                    try FileManager.default.copyItem(at: original, to: url)
                } catch {
                    result = error
                }
                semaphore.signal()
            }
            semaphore.wait()  // runs on the promise queue, not the main thread
            completionHandler(result)
        }

        func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { queue }
    }

    /// Adds Return/Space to open, Escape to deselect, ⌘+/⌘− to zoom, and per-item context menus.
    final class GridCollectionView: NSCollectionView {
        weak var owner: PhotoGridScrollView?

        override func keyDown(with event: NSEvent) {
            let command = event.modifierFlags.contains(.command)
            if let owner, owner.handleCullingKey(event) { return }
            switch event.charactersIgnoringModifiers {
            case "\r", " ": owner?.openSelection()
            case "\u{1b}": owner?.clearSelection()
            case "+" where command, "=" where command: owner?.zoom(in: true)
            case "-" where command: owner?.zoom(in: false)
            default:
                // Arrow keys move the selection; with nothing selected they start at the first tile on screen.
                if selectionIndexPaths.isEmpty, let special = event.specialKey,
                    [.leftArrow, .rightArrow, .upArrow, .downArrow].contains(special)
                {
                    owner?.selectFirstVisible()
                } else {
                    super.keyDown(with: event)
                }
            }
        }

        override func cancelOperation(_ sender: Any?) {
            owner?.clearSelection()
        }

        /// Edit ▸ Copy: the standard menu item reaches the grid through the responder chain.
        @objc func copy(_ sender: Any?) {
            owner?.copySelection()
        }

        /// Copy is offered while something is selected.
        @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
            if item.action == #selector(copy(_:)) { return owner?.canCopy ?? false }
            return true
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            let point = convert(event.locationInWindow, from: nil)
            guard let indexPath = indexPathForItem(at: point) else { return nil }
            return owner?.menu(for: indexPath)
        }
    }

    #if DEBUG
        /// UI checks without touching the real keyboard: `PHOTOS_DEBUG_GRID_KEYS=down,right,return` hands these key
        /// events to the grid of this process, one every 0.6 s, once the grid has items.
        @MainActor
        enum GridDebugKeys {
            private static var used = false

            static func runOnce(in collectionView: NSCollectionView) {
                guard !used, let raw = ProcessInfo.processInfo.environment["PHOTOS_DEBUG_GRID_KEYS"], !raw.isEmpty else { return }
                used = true
                let keys = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                for (index, key) in keys.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3 + 0.6 * Double(index)) { [weak collectionView] in
                        guard let collectionView, let event = event(for: key, window: collectionView.window) else { return }
                        collectionView.window?.makeFirstResponder(collectionView)
                        collectionView.keyDown(with: event)
                    }
                }
            }

            static func event(for key: String, window: NSWindow?) -> NSEvent? {
                let table: [String: (String, UInt16)] = [
                    "left": (String(UnicodeScalar(NSLeftArrowFunctionKey)!), 123),
                    "right": (String(UnicodeScalar(NSRightArrowFunctionKey)!), 124),
                    "down": (String(UnicodeScalar(NSDownArrowFunctionKey)!), 125),
                    "up": (String(UnicodeScalar(NSUpArrowFunctionKey)!), 126),
                    "return": ("\r", 36), "space": (" ", 49), "escape": ("\u{1b}", 53),
                    // Culling (SPEC §15.2).
                    "p": ("p", 35), "x": ("x", 7), "u": ("u", 32), "c": ("c", 8), "0": ("0", 29), "1": ("1", 18), "2": ("2", 19),
                    "3": ("3", 20), "4": ("4", 21), "5": ("5", 23),
                ]
                guard let (characters, code) = table[key] else { return nil }
                let arrow = (123...126).contains(Int(code))
                return NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: arrow ? [.numericPad, .function] : [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0, context: nil,
                    characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
            }
        }
    #endif

    #if DEBUG
        /// UI checks of the continuous pinch without a trackpad: `PHOTOS_DEBUG_GRID_PINCH=0.06,0.12,0.18` pinches at the
        /// middle of the grid through these magnifications, one every 0.5 s, once the grid has items, and holds the last
        /// one (for a screenshot) unless the list ends with `end`. `PHOTOS_DEBUG_GRID_HOVER=0.3,0.4` lifts the tile at
        /// that point of the visible grid as if the pointer rested there.
        @MainActor
        enum GridDebugPinch {
            private static var used = false

            static func runOnce(in grid: PhotoGridScrollView) {
                guard !used else { return }
                used = true
                if let raw = ProcessInfo.processInfo.environment["PHOTOS_DEBUG_GRID_HOVER"] {
                    let fractions = raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                    if fractions.count == 2 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak grid] in
                            guard let grid else { return }
                            let clip = grid.contentView.bounds
                            let point = NSPoint(
                                x: clip.minX + clip.width * CGFloat(fractions[0]), y: clip.minY + clip.height * CGFloat(fractions[1]))
                            grid.debugHover(at: grid.collectionView.convert(point, from: grid.contentView))
                        }
                    }
                }
                guard let raw = ProcessInfo.processInfo.environment["PHOTOS_DEBUG_GRID_PINCH"], !raw.isEmpty else { return }
                let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                let values = parts.compactMap(Double.init)
                let ends = parts.last == "end"
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak grid] in
                    guard let grid else { return }
                    let clip = grid.contentView.bounds
                    let location = NSPoint(x: clip.midX, y: clip.midY)
                    grid.pinch(.began, magnification: 0, location: location) {}
                    for (index, value) in values.enumerated() {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 * Double(index + 1)) { [weak grid] in
                            grid?.pinch(.changed, magnification: value, location: location) {}
                            guard ends, index == values.count - 1 else { return }
                            grid?.pinch(.ended, magnification: value, location: location) {}
                        }
                    }
                }
            }
        }
    #endif

    final class MenuActionItem: NSMenuItem {
        let handler: @MainActor () -> Void

        init(title: String, handler: @escaping @MainActor () -> Void) {
            self.handler = handler
            super.init(title: title, action: #selector(run), keyEquivalent: "")
            target = self
        }

        required init(coder: NSCoder) { fatalError() }

        @MainActor @objc func run() { handler() }
    }

    /// The view of a tile. To accessibility it is a button: pressing it opens the photo (VoiceOver, automation).
    final class PhotoTileView: NSView {
        var label = ""
        var isTileSelected = false
        var onPress: (() -> Void)?
        var actions: (() -> [GridMenuAction])?
        var fileId: FileID?

        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .button }
        override func accessibilityLabel() -> String? { label }
        override func isAccessibilitySelected() -> Bool { isTileSelected }
        /// Badges and the picture are described by the label.
        override func accessibilityChildren() -> [Any]? { [] }

        override func accessibilityPerformPress() -> Bool {
            guard let onPress else { return false }
            onPress()
            return true
        }

        /// The context menu actions (favourite, archive, delete…) as accessibility actions.
        override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
            guard let fileId, let actions = actions?(), !actions.isEmpty else { return nil }
            return GridMenuAction.flattened(actions).map { action in
                NSAccessibilityCustomAction(name: action.title) {
                    action.handler([fileId])
                    return true
                }
            }
        }
    }

    /// Darkens the lower edge of a tile so the white badges stay readable on bright pictures.
    final class TileShadeView: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
        }

        required init?(coder: NSCoder) { fatalError() }

        override func makeBackingLayer() -> CALayer {
            let gradient = CAGradientLayer()
            let workspace = NSWorkspace.shared
            let increased = workspace.accessibilityDisplayShouldIncreaseContrast || workspace.accessibilityDisplayShouldReduceTransparency
            gradient.colors = [
                NSColor.black.withAlphaComponent(GridTile.shadeOpacity(increased: increased)).cgColor, NSColor.clear.cgColor,
            ]
            // Layer coordinates start at the bottom on the Mac: dark at the bottom, clear at the top.
            gradient.startPoint = CGPoint(x: 0.5, y: 0)
            gradient.endPoint = CGPoint(x: 0.5, y: 1)
            return gradient
        }
    }

    final class PhotoItem: NSCollectionViewItem {
        static let identifier = NSUserInterfaceItemIdentifier("PhotoItem")
        private let tileView = PhotoTileView()
        private let photoView = NSView()
        private let placeholderIcon = NSImageView()
        private let shade = TileShadeView()
        private let durationLabel = NSTextField(labelWithString: "")
        private let videoIcon = NSImageView(image: NSImage(systemSymbolName: "video.fill", accessibilityDescription: nil)!)
        private let favoriteIcon = NSImageView(image: NSImage(systemSymbolName: "heart.fill", accessibilityDescription: nil)!)
        private let liveIcon = NSImageView(image: NSImage(systemSymbolName: "livephoto", accessibilityDescription: nil)!)
        private let stackIcon = NSImageView(image: NSImage(systemSymbolName: "square.stack.fill", accessibilityDescription: nil)!)
        private let partnerIcon = NSImageView(
            image: NSImage(systemSymbolName: GridTileBadges.partnerSymbol, accessibilityDescription: nil)!)
        private let selectionRing = NSView()
        /// Rating and flag (SPEC §15.2).
        private let cullingBadge = CullingBadgeView()
        /// Rejected: the picture is dimmed.
        private var isDimmed = false
        /// Loads the preview and says what to draw; shared with the UIKit grid.
        private let picture = GridTilePicture()
        var fileId: FileID? { picture.fileId }
        /// Square tile, or the picture whole in the photo's shape (`TileStyle`).
        private var square = true
        private var aspectRatio = 1.0
        /// What the picture is now, for the way the next one arrives (`GridTileArrival`).
        private var shown = GridTileArrival.Shown.nothing

        override func loadView() {
            picture.show = { [weak self] display in self?.show(display) }
            let container = tileView
            container.wantsLayer = true
            container.layer?.masksToBounds = true
            photoView.wantsLayer = true
            // The tile's grey is the picture's: in the aspect ratio grid it has the photo's shape.
            photoView.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            photoView.layer?.contentsGravity = .resizeAspectFill
            photoView.layer?.masksToBounds = true
            placeholderIcon.contentTintColor = .tertiaryLabelColor
            placeholderIcon.imageScaling = .scaleProportionallyUpOrDown
            placeholderIcon.isHidden = true
            durationLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            durationLabel.textColor = .white
            for icon in [favoriteIcon, liveIcon, videoIcon, partnerIcon] {
                icon.contentTintColor = .white
                icon.imageScaling = .scaleProportionallyUpOrDown
            }
            // The top edge has no shade: a soft shadow keeps the white badge visible on bright pictures.
            let partnerShadow = NSShadow()
            partnerShadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
            partnerShadow.shadowBlurRadius = 2
            partnerIcon.shadow = partnerShadow
            partnerIcon.isHidden = true
            selectionRing.wantsLayer = true
            selectionRing.layer?.borderColor = NSColor.controlAccentColor.cgColor
            selectionRing.layer?.borderWidth = 3
            selectionRing.isHidden = true
            // On the picture without a shade: a soft shadow keeps it visible on bright pictures.
            stackIcon.contentTintColor = .white
            stackIcon.imageScaling = .scaleProportionallyUpOrDown
            stackIcon.isHidden = true
            let stackShadow = NSShadow()
            stackShadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
            stackShadow.shadowBlurRadius = 2
            stackIcon.shadow = stackShadow
            [
                photoView, placeholderIcon, shade, durationLabel, videoIcon, favoriteIcon, liveIcon, stackIcon, partnerIcon,
                cullingBadge, selectionRing,
            ].forEach {
                container.addSubview($0)
            }
            view = container
        }

        override func viewDidLayout() {
            super.viewDidLayout()
            // The picture's place in the tile: all of it, or the photo's shape in the aspect ratio grid. Badges and
            // the selection ring go with the picture.
            let bounds = GridTile.pictureFrame(in: view.bounds, aspectRatio: aspectRatio, square: square)
            let x = bounds.minX
            let y = bounds.minY
            photoView.frame = bounds
            selectionRing.frame = bounds
            let glyph = min(max(bounds.width * 0.34, 14), 44)
            placeholderIcon.frame = CGRect(
                x: x + (bounds.width - glyph) / 2, y: y + (bounds.height - glyph) / 2, width: glyph, height: glyph)
            shade.frame = CGRect(x: x, y: y, width: bounds.width, height: min(bounds.height * 0.4, 36))
            durationLabel.sizeToFit()
            var right = bounds.maxX - 5
            if !durationLabel.isHidden {
                durationLabel.frame.origin = CGPoint(x: right - durationLabel.frame.width, y: y + 3)
                right = durationLabel.frame.minX - 3
            }
            videoIcon.frame = CGRect(x: right - 16, y: y + 4, width: 16, height: 12)
            favoriteIcon.frame = CGRect(x: x + 5, y: y + 4, width: 13, height: 12)
            // The flag and stars take the top leading corner; the Live Photo badge follows them.
            let cullingWidth = cullingBadge.fittingWidth
            cullingBadge.frame = CGRect(x: x + 5, y: bounds.maxY - 19, width: cullingWidth, height: 15)
            liveIcon.frame = CGRect(x: x + 4 + (cullingWidth > 0 ? cullingWidth + 4 : 0), y: bounds.maxY - 20, width: 16, height: 16)
            stackIcon.frame = CGRect(x: bounds.maxX - 20, y: bounds.maxY - 20, width: 16, height: 16)
            // Both in the top trailing corner: the partner badge moves left of the stack badge.
            let partnerRight = stackIcon.isHidden ? bounds.maxX - 4 : stackIcon.frame.minX - 3
            partnerIcon.frame = CGRect(x: partnerRight - 17, y: bounds.maxY - 18, width: 17, height: 14)
        }

        override var isSelected: Bool {
            didSet {
                selectionRing.isHidden = !isSelected
                updateAlpha()
                tileView.isTileSelected = isSelected
            }
        }

        private func updateAlpha() {
            photoView.alphaValue = (isSelected ? 0.8 : 1) * (isDimmed ? 0.4 : 1)
        }

        /// Shows `item`. Called again for the same item when its badges, the zoom or the screen scale change: the
        /// picture then stays until a sharper one has loaded (no flash).
        func configure(item: GridMedia, owner: PhotoGridScrollView, tileSide: Double, scale: Double) {
            let services = owner.services
            if square != owner.squareTiles || aspectRatio != item.aspectRatio {
                square = owner.squareTiles
                aspectRatio = item.aspectRatio
                view.needsLayout = true
            }
            photoView.isHidden = false
            updateBadges(item, owner: owner)
            let culling = CullingTileBadge(owner.culling.mark(item.fileId), tileSide: tileSide)
            cullingBadge.show(culling)
            isDimmed = culling.isDimmed
            updateAlpha()
            if let text = culling.accessibilityText { tileView.label += ", " + text }
            // What the photo shows, written on this device (SPEC §16.2).
            if let text = services.descriptions.text(of: item.fileId) { tileView.label += ", " + text }
            picture.configure(
                item: item, request: services.previewRequest(for: item, tileSide: tileSide, scale: scale, square: square),
                source: GridTilePicture.Source(services: services))
        }

        /// A tile of the first sync's skeleton: grey, nothing on it, nothing to open.
        func showPlaceholder() {
            picture.reset()
            square = true
            let badges: [NSView] = [durationLabel, videoIcon, favoriteIcon, liveIcon, stackIcon, partnerIcon, shade, cullingBadge]
            for badge in badges { badge.isHidden = true }
            isDimmed = false
            updateAlpha()
            tileView.fileId = nil
            tileView.label = String(localized: "Loading…", bundle: .module)
            tileView.onPress = nil
            tileView.actions = nil
            view.needsLayout = true
        }

        private func show(_ display: GridTilePicture.Display) {
            switch display {
            case .clear:
                photoView.layer?.removeAllAnimations()
                photoView.layer?.contents = nil
                placeholderIcon.isHidden = true
                shown = .nothing
            case .blur(let image):
                photoView.layer?.contents = image
                shown = .blur
            case .picture(let image):
                let arrival = GridTileArrival.transition(
                    from: shown, isAsync: picture.isDelivering,
                    reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
                photoView.layer?.contents = image
                placeholderIcon.isHidden = true
                shown = .picture
                if view.window != nil { animateArrival(arrival) }
            case .placeholder(let symbol):
                placeholderIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                placeholderIcon.isHidden = false
                shown = .placeholder
            }
        }

        /// A heart springs up over the tile and fades (a fade only with Reduce Motion).
        func playHeartBurst() {
            guard let host = view.layer,
                let symbol = NSImage(systemSymbolName: "heart.fill", accessibilityDescription: nil)?.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(pointSize: 48, weight: .regular).applying(.init(paletteColors: [.white])))
            else { return }
            let side = min(max(min(view.bounds.width, view.bounds.height) * 0.42, 18), 72)
            let heart = CALayer()
            heart.contents = symbol
            heart.contentsGravity = .resizeAspect
            heart.frame = CGRect(x: view.bounds.midX - side / 2, y: view.bounds.midY - side / 2, width: side, height: side)
            heart.shadowColor = NSColor.black.cgColor
            heart.shadowOpacity = 0.35
            heart.shadowRadius = 6
            heart.shadowOffset = .zero
            heart.opacity = 0
            host.addSublayer(heart)
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 1, 0]
            fade.keyTimes = [0, 0.25, 0.6, 1]
            var animations: [CAAnimation] = [fade]
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let scale = CAKeyframeAnimation(keyPath: "transform.scale")
                scale.values = [0.4, 1.08, 1, 1.25]
                scale.keyTimes = [0, 0.3, 0.6, 1]
                animations.append(scale)
            }
            let group = CAAnimationGroup()
            group.animations = animations
            group.duration = 0.9
            CATransaction.begin()
            CATransaction.setCompletionBlock { heart.removeFromSuperlayer() }
            heart.add(group, forKey: "burst")
            CATransaction.commit()
        }

        /// The preview comes in over the BlurHash: a cross-fade and a tiny settle, run by Core Animation (SPEC §17.2).
        private func animateArrival(_ arrival: GridTileArrival) {
            guard arrival != .instant, let layer = photoView.layer else { return }
            let fade = CATransition()
            fade.type = .fade
            fade.duration = GridTileArrival.fadeDuration
            layer.add(fade, forKey: "arrival")
            guard arrival == .fadeAndSettle else { return }
            let settle = CABasicAnimation(keyPath: "contentsRect")
            settle.fromValue = NSValue(rect: GridTileArrival.settleContentsRect)
            settle.toValue = NSValue(rect: CGRect(x: 0, y: 0, width: 1, height: 1))
            settle.duration = GridTileArrival.settleDuration
            settle.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            layer.add(settle, forKey: "settle")
        }

        private func updateBadges(_ item: GridMedia, owner: PhotoGridScrollView) {
            let badges = GridTileBadges(item: item, isPartner: owner.services.partnerPaths.contains(directory: item.directory))
            partnerIcon.isHidden = !badges.showsPartner
            durationLabel.stringValue = badges.duration ?? ""
            durationLabel.isHidden = badges.duration == nil
            videoIcon.isHidden = !badges.showsVideo
            favoriteIcon.isHidden = !badges.showsFavorite
            liveIcon.isHidden = !badges.showsLivePhoto
            stackIcon.isHidden = !badges.showsStack
            shade.isHidden = !badges.showsShade
            let id = item.fileId
            tileView.fileId = id
            tileView.label = badges.accessibilityLabel
            tileView.onPress = { [weak owner] in owner?.open(id) }
            tileView.actions = { [weak owner] in owner?.menuActions(for: id) ?? [] }
            view.needsLayout = true
        }

        override func prepareForReuse() {
            super.prepareForReuse()
            GridHoverLift.reset(view)
            picture.reset()
        }
    }

    final class SectionHeaderView: NSVisualEffectView, NSCollectionViewElement {
        static let identifier = NSUserInterfaceItemIdentifier("SectionHeader")
        private let titleLabel = NSTextField(labelWithString: "")
        private let subtitleLabel = NSTextField(labelWithString: "")
        private var metrics = GridHeaderMetrics(titleHeight: 26, subtitleHeight: 16)
        /// The moment this day starts (SPEC §16.1): its title is a link that opens it.
        private var moment: MomentHeaders.Entry?
        private var momentLabel: String?
        var openMoment: ((String) -> Void)?
        // Bold date, light day line (SPEC §17.5).
        static var subtitleFont: NSFont { Typography.dateDetailNSFont }

        override init(frame: NSRect) {
            super.init(frame: frame)
            material = .headerView
            blendingMode = .withinWindow
            titleLabel.font = Typography.dateTitleNSFont
            titleLabel.lineBreakMode = .byTruncatingTail
            titleLabel.setAccessibilityRole(.staticText)
            subtitleLabel.font = Self.subtitleFont
            subtitleLabel.textColor = .secondaryLabelColor
            subtitleLabel.lineBreakMode = .byTruncatingTail
            addSubview(titleLabel)
            addSubview(subtitleLabel)
            let click = NSClickGestureRecognizer(target: self, action: #selector(clicked(_:)))
            addGestureRecognizer(click)
        }

        required init?(coder: NSCoder) { fatalError() }

        override var isFlipped: Bool { true }

        func configure(_ text: GridHeaderText, metrics: GridHeaderMetrics) {
            self.metrics = metrics
            titleLabel.stringValue = text.title ?? ""
            titleLabel.isHidden = text.title == nil
            moment = text.moment
            momentLabel = text.momentAccessibilityLabel
            if let moment = text.moment {
                subtitleLabel.attributedStringValue = Self.momentLine(moment.title, day: text.subtitle)
                subtitleLabel.setAccessibilityElement(false)
            } else {
                subtitleLabel.stringValue = text.subtitle ?? ""
                subtitleLabel.setAccessibilityElement(true)
            }
            subtitleLabel.isHidden = text.subtitle == nil && text.moment == nil
            needsLayout = true
            window?.invalidateCursorRects(for: self)
        }

        /// "Sunday in Lisbon ›  Sun 22 November": the moment in the label colour, the day after it as before.
        static func momentLine(_ title: String, day: String?) -> NSAttributedString {
            let line = NSMutableAttributedString(
                string: title, attributes: [.font: Typography.dateEmphasisNSFont, .foregroundColor: NSColor.labelColor])
            let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
            if let symbol = NSImage(systemSymbolName: "chevron.forward", accessibilityDescription: nil)?.withSymbolConfiguration(
                configuration)
            {
                let attachment = NSTextAttachment()
                attachment.image = symbol
                line.append(NSAttributedString(string: " "))
                line.append(NSAttributedString(attachment: attachment))
            }
            if let day {
                line.append(
                    NSAttributedString(
                        string: "  " + day, attributes: [.font: subtitleFont, .foregroundColor: NSColor.secondaryLabelColor]))
            }
            return line
        }

        /// Where a click opens the moment: the moment's line, as far as its text goes.
        private var momentRect: NSRect? {
            guard moment != nil, !subtitleLabel.isHidden else { return nil }
            let width = min(subtitleLabel.attributedStringValue.size().width + 8, subtitleLabel.frame.width)
            return NSRect(
                x: subtitleLabel.frame.minX - 4, y: subtitleLabel.frame.minY - 3, width: width, height: subtitleLabel.frame.height + 6)
        }

        @objc private func clicked(_ gesture: NSClickGestureRecognizer) {
            guard let moment, let rect = momentRect, rect.contains(gesture.location(in: self)) else { return }
            openMoment?(moment.momentId)
        }

        override func resetCursorRects() {
            super.resetCursorRects()
            if let rect = momentRect { addCursorRect(rect, cursor: .pointingHand) }
        }

        // VoiceOver: with a moment the header is a button that opens it.
        override func isAccessibilityElement() -> Bool { moment != nil }
        override func accessibilityRole() -> NSAccessibility.Role? { moment != nil ? .button : super.accessibilityRole() }
        override func accessibilityLabel() -> String? { momentLabel }
        override func accessibilityPerformPress() -> Bool {
            guard let moment else { return false }
            openMoment?(moment.momentId)
            return true
        }

        /// Laid out by hand from the same metrics the layout takes the header height from, so nothing is clipped.
        override func layout() {
            super.layout()
            let width = max(bounds.width - 24, 0)
            var y = CGFloat(metrics.top)
            if !titleLabel.isHidden {
                titleLabel.frame = NSRect(x: 12, y: y, width: width, height: CGFloat(metrics.titleHeight))
                y += CGFloat(metrics.titleHeight + metrics.gap)
            }
            if !subtitleLabel.isHidden {
                subtitleLabel.frame = NSRect(x: 12, y: y, width: width, height: CGFloat(metrics.subtitleHeight))
            }
            window?.invalidateCursorRects(for: self)
        }
    }
#endif
