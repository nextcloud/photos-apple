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
        /// Moment titles on the day headers (the Library, SPEC §16.1).
        var moments = MomentHeaders.none
        /// A view that scrolls above the first section (the Library's memories, SPEC §17.2); nil: none.
        var header: AnyView? = nil
        var services: AccountServices
        var callbacks: GridCallbacks
        /// A cover with the title above the first row (iPhone, iPad; SPEC §17.4).
        var hero: GridHero? = nil

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
            controller.setMoments(moments)
            // The header is hosted inside the collection view, so it scrolls with the photos; it gets this view's
            // environment (session, navigation) so that its links and buttons work as before.
            controller.setHeader(header.map { AnyView($0.environment(\.self, context.environment)) })
            #if os(iOS)
                controller.setHero(hero)
            #endif
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
                    locator.place = { [weak self] id, fraction in self?.place(id, fraction: fraction) }
                    locator.topItem = { [weak self] in self?.anchorItem() }
                    locator.coveredChanged = { [weak self] covered in self?.setCovered(covered) }
                    if isViewLoaded { setCovered(locator.isCovered) }
                }
                callbacks?.motion?.favorited = { [weak self] ids in self?.playHeartBursts(ids) }
            }
        }
        private let refreshRunner = GridRefreshRunner()
        /// A two-finger drag over the tiles is selecting right now.
        private var multiSelectInteraction = false
        private var collectionView: UICollectionView!
        /// Model, zoom, anchor and layout bookkeeping, shared with the AppKit grid.
        private let core: GridCore
        private var isSelecting = false
        /// The pinch in progress: the photo under the fingers and where they are (SPEC §15.5).
        private var pinch: GridPinch?
        private weak var pinchRecognizer: UIPinchGestureRecognizer?
        /// After a pinch changed the zoom step: the photo that stays under the fingers through the relayout.
        private var pinchAnchor: (id: FileID, y: CGFloat)?
        /// Haptic ticks at year boundaries while scrolling fast (SPEC §15.5); the date scrubber ticks itself.
        private var yearTicker = YearBoundaryTicker()
        private var offsetObservation: NSKeyValueObservation?
        #if os(iOS)
            private var tickFeedback: UISelectionFeedbackGenerator?
        #endif
        private var selected = GridSelectionTracker()
        /// Date scrubber along the trailing edge (SPEC §6.4).
        private let scrubber = GridScrubberView()
        /// Top of every section in the document, plus its height as last element (scrubber positions).
        private var sectionOffsets: [Double] = []
        /// Ratings and flags shown on the tiles (SPEC §15.2).
        let culling: GridCullingObserver
        /// Edited photos' tiles are drawn again with their new rendition (SPEC §16.3).
        private let edits = GridEditObserver()
        /// Sliding across tiles while selecting, and peeking into videos, Live Photos and stacks (SPEC §16.1).
        private var rangeSelector: GridRangeSelector?
        private var peek: GridPeekPresenter?
        /// The month (and moment) of the photos at the top, in a glass capsule (SPEC §17.2).
        private let datePill = GridDatePillView()
        /// The section the pill was last filled from.
        private var pillSection: Int?
        /// A context menu is open: hearts wait until it has closed (the tile is hidden under its preview until then).
        private var menuShowing = false
        private var pendingBursts: [FileID] = []
        /// The view above the first section, and its height in the document.
        private var headerHost: UIHostingController<AnyView>?
        private var gridHeaderHeight: CGFloat = 0
        static let gridHeaderKind = "grid-header"
        #if os(iOS)
            /// The hero header above the first row (SPEC §17.4).
            private let heroHost = GridHeroHost()

            func setHero(_ hero: GridHero?) {
                guard hero != nil || heroHost.isActive else { return }
                loadViewIfNeeded()
                heroHost.update(hero, in: self, collectionView: collectionView)
            }
        #endif

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
            edits.changed = { [weak self] ids in self?.refreshVisibleTiles(only: ids) }
        }

        required init?(coder: NSCoder) { fatalError() }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            // The tab bar minimises while the grid scrolls down, the bars get their scroll edge effect (SPEC §17.3).
            registerContentScrollView(collectionView)
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: makeLayout())
            collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            collectionView.backgroundColor = .systemBackground
            collectionView.dataSource = self
            setCovered(callbacks?.tileLocator?.isCovered ?? false)
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
            collectionView.register(
                GridHeaderSlot.self, forSupplementaryViewOfKind: Self.gridHeaderKind, withReuseIdentifier: GridHeaderSlot.reuseIdentifier)
            view.addSubview(collectionView)
            // Edge to edge (SPEC §17.2): the photos scroll under the bars, which soften them with the system's blur.
            collectionView.topEdgeEffect.style = .soft
            // The date pill floats over the photos; the edge blur reaches down under it.
            let edgeElements = UIScrollEdgeElementContainerInteraction()
            edgeElements.scrollView = collectionView
            edgeElements.edge = .top
            datePill.addInteraction(edgeElements)
            view.addSubview(datePill)
            scrubber.isHidden = true
            scrubber.labelAt = { [weak self] fraction in self?.scrubberLabel(at: fraction) ?? "" }
            scrubber.onScrub = { [weak self] fraction in self?.scroll(toFraction: fraction) }
            scrubber.onStep = { [weak self] delta in self?.scrollToYear(delta: delta) }
            view.addSubview(scrubber)

            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            collectionView.addGestureRecognizer(pinch)
            pinchRecognizer = pinch
            rangeSelector = GridRangeSelector(host: self)
            peek = GridPeekPresenter(host: self)
            offsetObservation = collectionView.observe(\.contentOffset, options: []) { [weak self] _, _ in
                // UIKit changes the offset on the main thread.
                MainActor.assumeIsolated { self?.contentOffsetChanged() }
            }

            // Header heights are absolute and follow the text size.
            registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (controller: PhotoGridController, _: UITraitCollection) in
                controller.core.headerMetrics = Self.currentHeaderMetrics
                controller.collectionView.collectionViewLayout.invalidateLayout()
                controller.reloadScrubber()
                controller.pillSection = nil
                controller.updateDatePill(animated: false)
            }
            registerForTraitChanges([UITraitDisplayScale.self]) { (controller: PhotoGridController, _: UITraitCollection) in
                controller.refreshVisibleTiles()
            }
            updateRefreshControl()
        }

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

        private func configure(_ header: SectionHeader, section index: Int) {
            guard let section = model.sections[safe: index] else { return }
            header.configure(core.headerTexts.text(for: section), metrics: headerMetrics)
            header.openMoment = { [weak self] id in self?.callbacks?.openMoment?(id) }
        }

        // MARK: Header (the Library's memories)

        func setHeader(_ header: AnyView?) {
            if let header {
                if let host = headerHost {
                    host.rootView = header
                } else {
                    let host = UIHostingController(rootView: header)
                    host.sizingOptions = [.intrinsicContentSize]
                    host.safeAreaRegions = []
                    host.view.backgroundColor = .clear
                    addChild(host)
                    host.didMove(toParent: self)
                    headerHost = host
                }
            } else if let host = headerHost {
                host.willMove(toParent: nil)
                host.view.removeFromSuperview()
                host.removeFromParent()
                headerHost = nil
            }
            updateGridHeaderHeight()
        }

        override func preferredContentSizeDidChange(forChildContentContainer container: any UIContentContainer) {
            super.preferredContentSizeDidChange(forChildContentContainer: container)
            updateGridHeaderHeight()
        }

        /// The header's height at the grid's width; a new height lays the grid out again with the photos kept in place.
        private func updateGridHeaderHeight() {
            guard isViewLoaded else { return }
            let width = collectionView.bounds.width > 0 ? collectionView.bounds.width : view.bounds.width
            var height: CGFloat = 0
            if let host = headerHost, width > 0 {
                height = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height.rounded(.up)
            }
            guard abs(height - gridHeaderHeight) > 0.5,
                let layout = collectionView.collectionViewLayout as? UICollectionViewCompositionalLayout
            else { return }
            let wasAtTop = collectionView.contentOffset.y <= -topInset + 1
            let anchor = anchorItem()
            gridHeaderHeight = height
            let configuration = UICollectionViewCompositionalLayoutConfiguration()
            if height > 0 {
                configuration.boundarySupplementaryItems = [
                    NSCollectionLayoutBoundarySupplementaryItem(
                        layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(height)),
                        elementKind: Self.gridHeaderKind, alignment: .top)
                ]
            }
            layout.configuration = configuration
            if wasAtTop {
                // At the top it stays at the top: the header comes or goes above what is shown (the collection view would
                // keep the first tile where it was instead).
                collectionView.layoutIfNeeded()
                collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: -topInset), animated: false)
            } else {
                restore(anchor)
            }
            reloadScrubber()
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
            // The headers scroll with their photos: the date pill stays at the top instead (SPEC §17.2).
            GridCollectionLayout { [weak self] sectionIndex, environment in
                self?.core.sectionMetrics(sectionIndex, width: Double(environment.container.effectiveContentSize.width), wholePoints: false)
                    .layoutSection(headerKind: UICollectionView.elementKindSectionHeader, pinsHeaders: false)
            }
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
        private func playHeartBursts(_ ids: [FileID]) {
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

        private func setSelecting(_ selecting: Bool) {
            isSelecting = selecting
            collectionView.isEditing = selecting
            collectionView.allowsMultipleSelection = selecting
            if selecting { peek?.end() }
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

        /// The Library's years, months or days cover the grid (SPEC §17.5): its tiles, headers and scrubber are out of
        /// VoiceOver's reach meanwhile.
        private func setCovered(_ covered: Bool) {
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
            #if os(iOS)
                heroHost.layout(collectionView)
            #endif
            if core.columnsChanged(width: gridWidth) { restore(core.resizeAnchor) }
            core.resizeAnchor = nil
            if core.sideChanged(width: gridWidth) { refreshVisibleTiles() }
            core.noteLayout(width: gridWidth)
            if headerHost != nil { updateGridHeaderHeight() }
            layoutScrubber()
            layoutDatePill()
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
            defer {
                pillSection = nil
                updateDatePill(animated: false)
            }
            let visibleHeight = visibleHeight
            guard headersShown, visibleHeight > 0 else {
                setScrubberShown(false)
                return
            }
            let sections = model.sections
            // Placeholder tiles (the first sync's skeleton) count: the scrubber covers the whole library.
            // The header above the first section (memories) comes first in the document.
            let headerOffset = Double(gridHeaderHeight)
            sectionOffsets = geometry.sectionOffsets(
                itemCounts: sections.map(\.tileCount), headerHeights: sections.map { headerMetrics.height(for: $0) }
            ).map { $0 + headerOffset }
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
            #if os(iOS)
                heroHost.layout(collectionView)
            #endif
            // Only the user's scrolling shows the scrubber, not a jump to a photo or a relayout.
            updateScrubberPosition(userInitiated: scrollView.isTracking || scrollView.isDecelerating)
            updateDatePill(animated: true)
            // A peek belongs to the tile under the pointer; the grid moved away under it.
            if peek?.isPeeking == true, scrollView.isTracking || scrollView.isDecelerating { peek?.end() }
        }

        func scrollViewDidChangeAdjustedContentInset(_ scrollView: UIScrollView) {
            layoutScrubber()
            reloadScrubber()
            layoutDatePill()
        }

        // MARK: Date pill (SPEC §17.2)

        /// The pill sits under the bars at the leading edge, clear of the date scrubber.
        private func layoutDatePill() {
            guard isViewLoaded else { return }
            let inset: CGFloat = 16
            // Clear of the scrubber's handle at the trailing edge (its view is wider: it holds the date bubble too).
            let maxWidth = max(view.bounds.width - view.safeAreaInsets.left - view.safeAreaInsets.right - 2 * inset - 56, 80)
            let size = datePill.fittingSize(maxWidth: maxWidth)
            let rightToLeft = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
            let x = rightToLeft ? view.bounds.maxX - view.safeAreaInsets.right - inset - size.width : view.safeAreaInsets.left + inset
            let frame = CGRect(x: x, y: barInset + 8, width: size.width, height: size.height)
            guard frame != datePill.frame else { return }
            // Bounds and centre, not the frame: the pill may be scaled while it fades in.
            datePill.bounds = CGRect(origin: .zero, size: frame.size)
            datePill.center = CGPoint(x: frame.midX, y: frame.midY)
        }

        /// The bars' part of the top inset: a hero header (SPEC §17.4) adds its height to the content inset, but the pill
        /// stays under the bars and names what is just below them.
        private var barInset: CGFloat { collectionView.adjustedContentInset.top - collectionView.contentInset.top }

        /// The section under the pill names it; the text changes only when the month or the moment does. Cheap per frame:
        /// a binary search over the section offsets, text only when the section changes.
        private func updateDatePill(animated: Bool) {
            guard isViewLoaded, headersShown, sectionOffsets.count > 1 else {
                pillSection = nil
                datePill.show(nil, handover: .none)
                datePill.setShown(false, animated: animated)
                return
            }
            let top = Double(collectionView.contentOffset.y + barInset)
            let probe = top + 8 + Double(datePill.bounds.height)
            if let index = GridGeometry.section(at: max(probe, 0), in: sectionOffsets), index != pillSection {
                let handover = GridDatePill.handover(from: pillSection, to: index)
                pillSection = index
                let pill = GridDatePill.make(sections: model.sections, index: index, moments: core.headerTexts.moments)
                if datePill.show(pill, handover: handover) { layoutDatePill() }
            }
            datePill.setShown(top > Double(gridHeaderHeight) + GridDatePill.revealOffset && datePill.pill != nil, animated: animated)
        }

        // MARK: Pinch (SPEC §15.5)

        /// The tiles follow the fingers (scaled around them); on release the grid settles on the step the pinch was heading
        /// for, with the photo under the fingers kept under them. Out of the densest step the Library's days take over.
        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .began:
                let location = gesture.location(in: collectionView)
                pinch = GridPinch(fileId: fileId(near: location), location: gesture.location(in: view))
            case .changed:
                guard let pinch else { return }
                let stop = LibraryZoomStop.grid(step: zoomStep)
                let pastEnd: Bool = callbacks?.zoomPastEnd != nil || stop != GridPinch.ladder.densestGrid
                let canZoomOut = GridPinch.ladder.canZoomOut(from: stop) && pastEnd
                let scale = LibraryZoomGesture.displayScale(
                    Double(gesture.scale), canZoomIn: GridPinch.ladder.canZoomIn(from: stop), canZoomOut: canZoomOut)
                collectionView.transform = pinch.transform(scale: CGFloat(scale), center: CGPoint(x: view.bounds.midX, y: view.bounds.midY))
            case .ended:
                guard let pinch else { return }
                self.pinch = nil
                let projected = LibraryZoomGesture.projectedScale(scale: Double(gesture.scale), velocity: Double(gesture.velocity))
                let target = GridPinch.ladder.moved(.grid(step: zoomStep), by: LibraryZoomGesture.steps(projectedScale: projected))
                switch target {
                case .grid(let step) where step != zoomStep:
                    snapFeedback(at: pinch.location)
                    pinchAnchor = pinch.fileId.map { ($0, pinch.location.y) }
                    callbacks?.columnsChanged(step)
                    // Should the zoom not arrive (nothing changed after all), the tiles still go back to their size.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                        self?.pinchAnchor = nil
                        self?.settleTransform()
                    }
                case .grid:
                    settleTransform()
                default:
                    if let zoomPastEnd = callbacks?.zoomPastEnd {
                        // The level change plays its own tap (`LibraryZoomOverlay`).
                        let point = UnitPoint(
                            x: Double(pinch.location.x / max(view.bounds.width, 1)),
                            y: Double(pinch.location.y / max(view.bounds.height, 1)))
                        zoomPastEnd(pinch.fileId, point)
                        // Covered by the days by now; back to its size underneath.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                            self?.collectionView.transform = .identity
                        }
                    } else {
                        settleTransform()
                    }
                }
            case .cancelled, .failed:
                pinch = nil
                settleTransform()
            default: break
            }
        }

        /// Springs the tiles back to their size.
        private func settleTransform() {
            guard collectionView.transform != .identity else { return }
            UIView.animate(
                withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0, options: [.allowUserInteraction]
            ) {
                self.collectionView.transform = .identity
            }
        }

        /// The photo under a point of the grid, or the one closest to it (between tiles, under a header).
        private func fileId(near location: CGPoint) -> FileID? {
            if let indexPath = collectionView.indexPathForItem(at: location), let id = fileId(at: indexPath) { return id }
            let visible = collectionView.indexPathsForVisibleItems.compactMap { indexPath -> (FileID, CGFloat)? in
                guard let id = fileId(at: indexPath), let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame else {
                    return nil
                }
                return (id, hypot(frame.midX - location.x, frame.midY - location.y))
            }
            return visible.min { $0.1 < $1.1 }?.0 ?? anchorItem()
        }

        /// A light tap when a pinch snaps to another zoom step or level (iPhone, iPad; the system's haptics setting applies).
        private func snapFeedback(at location: CGPoint) {
            #if os(iOS)
                UIImpactFeedbackGenerator(style: .light, view: view).impactOccurred(at: location)
            #endif
        }

        /// Scrolls so that the tile's top is at `fraction` of the visible height (a zoom from the days).
        func place(_ id: FileID, fraction: Double) {
            guard isViewLoaded else { return }
            let visible = collectionView.bounds.height - topInset - collectionView.adjustedContentInset.bottom
            place(id, viewY: topInset + CGFloat(fraction) * max(visible, 0))
        }

        /// Scrolls so that the tile's middle is at `viewY` in the controller's view, now and after the layout pass.
        private func place(_ id: FileID, viewY: CGFloat) {
            core.restore(id) { [weak self] id in
                guard let self, let indexPath = self.indexPath(for: id) else { return }
                self.collectionView.layoutIfNeeded()
                guard let frame = self.collectionView.layoutAttributesForItem(at: indexPath)?.frame else { return }
                let contentHeight = max(
                    self.collectionView.contentSize.height, self.collectionView.collectionViewLayout.collectionViewContentSize.height)
                let inCollection = viewY - self.collectionView.frame.minY
                let offset = GridAnchor.offset(
                    documentY: Double(frame.midY - inCollection + self.topInset), topInset: Double(self.topInset),
                    contentHeight: Double(contentHeight), bottomInset: Double(self.collectionView.adjustedContentInset.bottom),
                    viewportHeight: Double(self.collectionView.bounds.height))
                self.collectionView.setContentOffset(CGPoint(x: self.collectionView.contentOffset.x, y: CGFloat(offset)), animated: false)
            }
        }

        // MARK: Year ticks (SPEC §15.5)

        private func contentOffsetChanged() {
            #if os(iOS)
                // While the date scrubber is dragged it ticks per year itself.
                guard headersShown, core.pendingAnchor == nil, view.window != nil, !scrubber.isScrubbing else { return }
                let top = collectionView.contentOffset.y + topInset
                let probe = CGPoint(x: min(8, collectionView.bounds.width / 2), y: top + CGFloat(headerMetrics.titleHeight) + 24)
                let year = collectionView.indexPathForItem(at: probe).flatMap { model.sections[safe: $0.section]?.year }
                let now = ProcessInfo.processInfo.systemUptime
                let tick = yearTicker.update(
                    year: year, offset: Double(collectionView.contentOffset.y), time: now,
                    isUserScrolling: collectionView.isTracking || collectionView.isDecelerating,
                    isScrubbing: false)
                guard tick else { return }
                if tickFeedback == nil { tickFeedback = UISelectionFeedbackGenerator(view: view) }
                tickFeedback?.selectionChanged()
            #endif
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
            if kind == Self.gridHeaderKind {
                let slot =
                    collectionView.dequeueReusableSupplementaryView(
                        ofKind: kind, withReuseIdentifier: GridHeaderSlot.reuseIdentifier, for: indexPath) as! GridHeaderSlot
                slot.hold(headerHost?.view)
                return slot
            }
            let header =
                collectionView.dequeueReusableSupplementaryView(
                    ofKind: kind, withReuseIdentifier: SectionHeader.reuseIdentifier, for: indexPath)
                as! SectionHeader
            configure(header, section: indexPath.section)
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
            // Two fingers that pinch are zooming, not selecting.
            let pinching = pinch != nil || pinchRecognizer?.state == .began || pinchRecognizer?.state == .changed
            return !pinching && fileId(at: indexPath) != nil
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
                // A Live Photo's badge comes alive while it is held (SPEC §17.2).
                if item.isLivePhoto { (collectionView.cellForItem(at: indexPaths[0]) as? PhotoCell)?.setLiveActive(true) }
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

        func collectionView(
            _ collectionView: UICollectionView, willDisplayContextMenu configuration: UIContextMenuConfiguration,
            animator: (any UIContextMenuInteractionAnimating)?
        ) {
            menuShowing = true
        }

        func collectionView(
            _ collectionView: UICollectionView, willEndContextMenuInteraction configuration: UIContextMenuConfiguration,
            animator: (any UIContextMenuInteractionAnimating)?
        ) {
            for case let cell as PhotoCell in collectionView.visibleCells { cell.setLiveActive(false) }
            let finish: () -> Void = { [weak self] in
                guard let self else { return }
                self.menuShowing = false
                let ids = self.pendingBursts
                self.pendingBursts = []
                if !ids.isEmpty { self.playHeartBursts(ids) }
            }
            if let animator { animator.addCompletion(finish) } else { finish() }
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

    /// Range selection and peeks (`GridGestures+UIKit`) work on this grid.
    extension PhotoGridController: GridGestureHost {
        var gestureCollectionView: UICollectionView { collectionView }
        var gestureIsSelecting: Bool { isSelecting }

        func applyRangeChanges(_ changes: [(index: Int, selected: Bool)]) {
            guard !changes.isEmpty else { return }
            var added: [FileID] = []
            var removed: [FileID] = []
            for change in changes {
                guard let indexPath = indexPath(ofIndex: change.index), let id = fileId(at: indexPath) else { continue }
                if change.selected {
                    collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
                    added.append(id)
                } else {
                    collectionView.deselectItem(at: indexPath, animated: false)
                    removed.append(id)
                }
            }
            selected.insert(added)
            selected.remove(removed)
            callbacks?.selectionChanged(selected.ids)
        }
    }

    final class PhotoCell: UICollectionViewCell {
        static let reuseIdentifier = "PhotoCell"
        private let imageView = UIImageView()
        private let placeholderIcon = UIImageView()
        /// The video's duration in a small glass capsule (SPEC §17.2).
        private let videoPill = GridVideoPill()
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
        /// The photo the selection look was last drawn for: only a change of the same tile animates (not a reused cell).
        private var selectionShownFor: FileID?
        /// What the picture is now, for the way the next one arrives (`GridTileArrival`).
        private var shown = GridTileArrival.Shown.nothing
        /// Loads the preview and says what to draw; shared with the AppKit grid.
        private let tilePicture = GridTilePicture()
        var fileId: FileID? { tilePicture.fileId }
        private var menuActions: (() -> [GridMenuAction])?
        /// Square tile, or the picture whole in the photo's shape (`TileStyle`).
        private var square = true
        private var aspectRatio = 1.0
        /// "1:05" of a video.
        private var duration: String?

        override init(frame: CGRect) {
            super.init(frame: frame)
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.layer.cornerCurve = .continuous
            imageView.backgroundColor = .secondarySystemFill
            contentView.addSubview(imageView)
            placeholderIcon.tintColor = .tertiaryLabel
            placeholderIcon.contentMode = .scaleAspectFit
            placeholderIcon.isHidden = true
            contentView.addSubview(placeholderIcon)
            contentView.layer.addSublayer(gradient)
            for icon in [favoriteIcon, liveIcon, partnerIcon] {
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
            // The Live badge stays readable on bright pictures without a shade.
            liveIcon.layer.shadowColor = UIColor.black.cgColor
            liveIcon.layer.shadowOpacity = 0.4
            liveIcon.layer.shadowRadius = 1.5
            liveIcon.layer.shadowOffset = .zero
            [videoPill, favoriteIcon, liveIcon, stackIcon, partnerIcon, cullingBadge, checkmark].forEach {
                contentView.addSubview($0)
            }
            // Pointer (iPad trackpad or mouse): the tile under it is highlighted. Vision Pro: the tile looked at lifts
            // towards the eyes with the system's lift effect, drawn by the system outside the app (SPEC §17.7).
            #if os(visionOS)
                hoverStyle = UIHoverStyle(effect: .lift, shape: .rect(cornerRadius: GridTile.visionHoverCornerRadius))
            #else
                hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect)
            #endif
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
            let pill = GridVideoPillLayout.layout(tileWidth: Double(bounds.width))
            videoPill.alpha = trailingBadges && pill != .hidden ? 1 : 0
            videoPill.show(duration: pill == .duration ? duration : nil)
            let pillHeight = (GridVideoPill.font.lineHeight + 4).rounded(.up)
            let pillWidth = videoPill.fittingWidth(height: pillHeight)
            let right = markShown ? checkmark.frame.minX - 4 : bounds.maxX - 4
            videoPill.frame = CGRect(x: right - pillWidth, y: bounds.maxY - pillHeight - 4, width: pillWidth, height: pillHeight)
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
            // Only a tile on screen whose own state changed animates (not a reused cell, not the first configuration).
            let animated = window != nil && selectionShownFor == fileId && fileId != nil && selected != isTileSelected
            selectionShownFor = fileId
            checkmark.isHidden = !(editing || selected)
            let image =
                selected
                ? UIImage(
                    systemName: "checkmark.circle.fill",
                    withConfiguration: UIImage.SymbolConfiguration(paletteColors: [.white, .tintColor]))
                : UIImage(systemName: "circle")
            // Selected: a white tick on the accent colour (the view's inherited tint). Not selected: a white ring.
            checkmark.tintColor = selected ? nil : .white
            let reduceMotion = UIAccessibility.isReduceMotionEnabled
            if let image {
                if animated, !wasHidden {
                    // The tick springs in (SPEC §17.2).
                    checkmark.setSymbolImage(image, contentTransition: .replace.downUp)
                    if selected, !reduceMotion { checkmark.addSymbolEffect(.bounce) }
                } else {
                    checkmark.image = image
                }
            }
            isTileSelected = selected
            // Pressed into the page: a selected tile shrinks a little and rounds its corners (no shrink with Reduce
            // Motion).
            let side = Double(min(contentView.bounds.width, contentView.bounds.height))
            let look = { [self] in
                imageView.alpha = (selected ? GridSelectionLook.selectedAlpha : 1) * (isDimmed ? 0.4 : 1)
                imageView.layer.cornerRadius = selected ? CGFloat(GridSelectionLook.cornerRadius(tileSide: side)) : 0
                let scale = selected && !reduceMotion ? CGFloat(GridSelectionLook.scale) : 1
                contentView.transform = scale == 1 ? .identity : CGAffineTransform(scaleX: scale, y: scale)
            }
            if animated {
                UIView.animate(
                    springDuration: 0.3, bounce: reduceMotion ? 0 : 0.2, options: [.allowUserInteraction, .beginFromCurrentState]
                ) {
                    look()
                }
            } else {
                look()
            }
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
            imageView.alpha = (isTileSelected ? GridSelectionLook.selectedAlpha : 1) * (isDimmed ? 0.4 : 1)
            if let text = culling.accessibilityText { accessibilityLabel = (accessibilityLabel ?? "") + ", " + text }
            // What the photo shows, written on this device (SPEC §16.2).
            if let text = services.descriptions.text(of: item.fileId) { accessibilityLabel = (accessibilityLabel ?? "") + ", " + text }
            setNeedsUpdateConfiguration()
            tilePicture.configure(
                item: item, request: services.previewRequest(for: item, tileSide: tileSide, scale: scale, square: square),
                source: GridTilePicture.Source(services: services))
        }

        /// A tile of the first sync's skeleton: grey, nothing on it, nothing to open.
        func showPlaceholder() {
            tilePicture.reset()
            square = true
            let badges: [UIView] = [videoPill, favoriteIcon, liveIcon, stackIcon, partnerIcon, cullingBadge]
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
                imageView.layer.removeAnimation(forKey: "arrival")
                imageView.layer.removeAnimation(forKey: "settle")
                imageView.image = nil
                placeholderIcon.isHidden = true
                shown = .nothing
            case .blur(let image):
                imageView.image = UIImage(cgImage: image)
                shown = .blur
            case .picture(let image):
                let arrival = GridTileArrival.transition(
                    from: shown, isAsync: tilePicture.isDelivering, reduceMotion: UIAccessibility.isReduceMotionEnabled)
                imageView.image = UIImage(cgImage: image)
                placeholderIcon.isHidden = true
                shown = .picture
                if window != nil { animateArrival(arrival) }
            case .placeholder(let symbol):
                placeholderIcon.image = UIImage(systemName: symbol)
                placeholderIcon.isHidden = false
                shown = .placeholder
            }
        }

        /// The preview comes in over the BlurHash: a cross-fade and a tiny settle, both run by Core Animation (nothing
        /// per frame on the main thread, no layout change).
        private func animateArrival(_ arrival: GridTileArrival) {
            guard arrival != .instant else { return }
            let fade = CATransition()
            fade.type = .fade
            fade.duration = GridTileArrival.fadeDuration
            imageView.layer.add(fade, forKey: "arrival")
            guard arrival == .fadeAndSettle else { return }
            let settle = CABasicAnimation(keyPath: "contentsRect")
            settle.fromValue = NSValue(cgRect: GridTileArrival.settleContentsRect)
            settle.toValue = NSValue(cgRect: CGRect(x: 0, y: 0, width: 1, height: 1))
            settle.duration = GridTileArrival.settleDuration
            settle.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            imageView.layer.add(settle, forKey: "settle")
        }

        /// A heart over the tile (favourite).
        func playHeartBurst() {
            contentView.playHeartBurst(side: min(contentView.bounds.width, contentView.bounds.height))
        }

        /// The Live badge plays (layer by layer) while the tile is held, hovered or peeked into.
        func setLiveActive(_ active: Bool) {
            guard !liveIcon.isHidden else { return }
            if active {
                liveIcon.addSymbolEffect(.variableColor.iterative.reversing, options: .repeating)
            } else {
                liveIcon.removeAllSymbolEffects()
            }
        }

        private func updateBadges(_ item: GridMedia, owner: PhotoGridController) {
            let badges = GridTileBadges(item: item, isPartner: owner.services.partnerPaths.contains(directory: item.directory))
            partnerIcon.isHidden = !badges.showsPartner
            duration = badges.duration
            videoPill.isHidden = !badges.showsVideo
            if favoriteIcon.isHidden, badges.showsFavorite, fileId == item.fileId, window != nil {
                // Made a favourite while on screen: the badge bounces in.
                favoriteIcon.isHidden = false
                if !UIAccessibility.isReduceMotionEnabled { favoriteIcon.addSymbolEffect(.bounce) }
            }
            favoriteIcon.isHidden = !badges.showsFavorite
            liveIcon.isHidden = !badges.showsLivePhoto
            stackIcon.isHidden = !badges.showsStack
            // Videos have their glass capsule; the shade is only under the favourite's heart.
            gradient.isHidden = !badges.showsFavorite
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
            selectionShownFor = nil
            liveIcon.removeAllSymbolEffects()
            contentView.transform = .identity
            imageView.layer.cornerRadius = 0
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

    /// The place of the grid's header in the collection view: it holds the one hosting view.
    final class GridHeaderSlot: UICollectionReusableView {
        static let reuseIdentifier = "GridHeaderSlot"

        func hold(_ content: UIView?) {
            guard let content else { return }
            if content.superview !== self {
                content.removeFromSuperview()
                addSubview(content)
            }
            content.frame = bounds
            content.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        }
    }

    final class SectionHeader: UICollectionReusableView {
        static let reuseIdentifier = "SectionHeader"
        // Bold date, light day line (SPEC §17.5).
        static var titleFont: UIFont { Typography.dateTitleUIFont }
        static var subtitleFont: UIFont { Typography.dateDetailUIFont }
        private let titleLabel = UILabel()
        private let subtitleLabel = UILabel()
        private var metrics = GridHeaderMetrics(titleHeight: 28, subtitleHeight: 20)
        /// The moment's title and the day: a button that opens the moment (SPEC §16.1).
        private let momentButton = UIControl()
        private var moment: MomentHeaders.Entry?
        var openMoment: ((String) -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            // No band behind the text: the headers scroll with the photos, the date pill stays (SPEC §17.2).
            subtitleLabel.textColor = .secondaryLabel
            titleLabel.accessibilityTraits = .header
            addSubview(titleLabel)
            addSubview(subtitleLabel)
            momentButton.isHidden = true
            momentButton.isAccessibilityElement = true
            momentButton.accessibilityTraits = [.button, .header]
            // Pointer (iPad) and gaze (Vision Pro): the title is highlighted like a button.
            momentButton.hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 6))
            momentButton.addTarget(self, action: #selector(momentTapped), for: .touchUpInside)
            addSubview(momentButton)
        }

        required init?(coder: NSCoder) { fatalError() }

        /// Laid out by hand from the same metrics the layout takes the header height from, so nothing is clipped.
        override func layoutSubviews() {
            super.layoutSubviews()
            let area = bounds.inset(by: layoutMargins)
            var y = CGFloat(metrics.top)
            if !titleLabel.isHidden {
                titleLabel.frame = CGRect(x: area.minX, y: y, width: area.width, height: CGFloat(metrics.titleHeight))
                y += CGFloat(metrics.titleHeight + metrics.gap)
            }
            if !subtitleLabel.isHidden {
                subtitleLabel.frame = CGRect(x: area.minX, y: y, width: area.width, height: CGFloat(metrics.subtitleHeight))
                // The button covers the text (and a little around it), not the whole width of the header.
                let textWidth = min(subtitleLabel.intrinsicContentSize.width, area.width)
                momentButton.frame = CGRect(x: area.minX - 6, y: y - 4, width: textWidth + 12, height: CGFloat(metrics.subtitleHeight) + 8)
            }
        }

        func configure(_ text: GridHeaderText, metrics: GridHeaderMetrics) {
            self.metrics = metrics
            titleLabel.font = Self.titleFont
            subtitleLabel.font = Self.subtitleFont
            titleLabel.text = text.title
            titleLabel.isHidden = text.title == nil
            moment = text.moment
            if let moment = text.moment {
                subtitleLabel.attributedText = Self.momentLine(moment.title, day: text.subtitle, font: Self.subtitleFont)
                momentButton.accessibilityLabel = text.momentAccessibilityLabel
                momentButton.accessibilityHint = String(
                    localized: "Opens the moment", bundle: .module,
                    comment: "VoiceOver hint of a moment title on a day header of the library.")
                subtitleLabel.isAccessibilityElement = false
            } else {
                subtitleLabel.attributedText = nil
                subtitleLabel.text = text.subtitle
                subtitleLabel.isAccessibilityElement = true
            }
            momentButton.isHidden = text.moment == nil
            subtitleLabel.isHidden = text.subtitle == nil && text.moment == nil
            setNeedsLayout()
        }

        /// "Sunday in Lisbon ›  Sun 22 November": the moment in the label colour, the day after it as before.
        static func momentLine(_ title: String, day: String?, font: UIFont) -> NSAttributedString {
            let line = NSMutableAttributedString(
                string: title, attributes: [.font: Typography.dateEmphasisUIFont.withSize(font.pointSize), .foregroundColor: UIColor.label])
            let symbol = UIImage(
                systemName: "chevron.forward", withConfiguration: UIImage.SymbolConfiguration(font: font.withSize(font.pointSize * 0.75)))
            if let symbol {
                let attachment = NSTextAttachment(image: symbol.withTintColor(.tertiaryLabel, renderingMode: .alwaysOriginal))
                line.append(NSAttributedString(string: " "))
                line.append(NSAttributedString(attachment: attachment))
            }
            if let day {
                line.append(
                    NSAttributedString(string: "  " + day, attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel]))
            }
            return line
        }

        @objc private func momentTapped() {
            guard let moment else { return }
            openMoment?(moment.momentId)
        }
    }

    extension UIFont {
        func withWeight(_ weight: UIFont.Weight) -> UIFont {
            UIFont.systemFont(ofSize: pointSize, weight: weight)
        }
    }
    /// A pinch on the grid: the photo under the fingers and where the fingers are in the grid's view.
    @MainActor
    struct GridPinch {
        static let ladder = LibraryZoomLadder(gridSteps: GridColumns.options)

        var fileId: FileID?
        var location: CGPoint

        /// Scales the grid by `scale` around the fingers (the view's transform works around its centre).
        func transform(scale: CGFloat, center: CGPoint) -> CGAffineTransform {
            let dx = location.x - center.x
            let dy = location.y - center.y
            return CGAffineTransform(translationX: dx, y: dy).scaledBy(x: scale, y: scale).translatedBy(x: -dx, y: -dy)
        }
    }
#endif
