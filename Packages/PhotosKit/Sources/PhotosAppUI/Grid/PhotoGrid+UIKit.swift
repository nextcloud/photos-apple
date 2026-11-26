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
        // What the extensions in PhotoGrid*+UIKit.swift share is internal rather than private (SPEC §20.7).
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
        var multiSelectInteraction = false
        var collectionView: UICollectionView!
        /// Model, zoom, anchor and layout bookkeeping, shared with the AppKit grid.
        let core: GridCore
        var isSelecting = false
        /// The pinch in progress: the photo under the fingers and where they are (SPEC §15.5).
        var pinch: GridPinch?
        weak var pinchRecognizer: UIPinchGestureRecognizer?
        /// After a pinch changed the zoom step: the photo that stays under the fingers through the relayout.
        var pinchAnchor: (id: FileID, y: CGFloat)?
        /// Haptic ticks at year boundaries while scrolling fast (SPEC §15.5); the date scrubber ticks itself.
        var yearTicker = YearBoundaryTicker()
        private var offsetObservation: NSKeyValueObservation?
        #if os(iOS)
            var tickFeedback: UISelectionFeedbackGenerator?
        #endif
        var selected = GridSelectionTracker()
        /// Date scrubber along the trailing edge (SPEC §6.4).
        let scrubber = GridScrubberView()
        /// Top of every section in the document, plus its height as last element (scrubber positions).
        var sectionOffsets: [Double] = []
        /// Ratings and flags shown on the tiles (SPEC §15.2).
        let culling: GridCullingObserver
        /// Edited photos' tiles are drawn again with their new rendition (SPEC §16.3).
        private let edits = GridEditObserver()
        /// Sliding across tiles while selecting, and peeking into videos, Live Photos and stacks (SPEC §16.1).
        private var rangeSelector: GridRangeSelector?
        var peek: GridPeekPresenter?
        /// The month (and moment) of the photos at the top, in a glass capsule (SPEC §17.2).
        let datePill = GridDatePillView()
        /// The section the pill was last filled from.
        var pillSection: Int?
        /// A context menu is open: hearts wait until it has closed (the tile is hidden under its preview until then).
        var menuShowing = false
        var pendingBursts: [FileID] = []
        /// The view above the first section, and its height in the document.
        var headerHost: UIHostingController<AnyView>?
        var gridHeaderHeight: CGFloat = 0
        static let gridHeaderKind = "grid-header"
        #if os(iOS)
            /// The hero header above the first row (SPEC §17.4).
            let heroHost = GridHeroHost()

            func setHero(_ hero: GridHero?) {
                guard hero != nil || heroHost.isActive else { return }
                loadViewIfNeeded()
                heroHost.update(hero, in: self, collectionView: collectionView)
            }
        #endif

        var model: GridModel { core.model }
        var squareTiles: Bool { core.squareTiles }
        var zoomStep: Int { core.zoomStep }
        var headerMetrics: GridHeaderMetrics { core.headerMetrics }

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

        // MARK: Header (the Library's memories)

        /// Told to the header's views: the stories play only while the header is on screen.
        let headerVisibility = GridHeaderVisibility()

        override func preferredContentSizeDidChange(forChildContentContainer container: any UIContentContainer) {
            super.preferredContentSizeDidChange(forChildContentContainer: container)
            updateGridHeaderHeight()
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
        var gridWidth: Double { Double(collectionView?.bounds.width ?? view.bounds.width) }

        /// Columns and tile side for the current width and zoom.
        var geometry: GridGeometry { core.geometry(width: gridWidth) }

        /// Scale for preview requests, capped at 2 (SPEC §5.5.1): a 3× preview of every tile costs more memory and
        /// traffic than it shows.
        var previewScale: Double { Double(min(view.traitCollection.displayScale, 2)) }

        var headersShown: Bool { core.headersShown }

        /// Header heights for the current text size.
        private static var currentHeaderMetrics: GridHeaderMetrics {
            GridHeaderMetrics(
                titleHeight: Double(SectionHeader.titleFont.lineHeight.rounded(.up)),
                subtitleHeight: Double(SectionHeader.subtitleFont.lineHeight.rounded(.up)))
        }

        func headerHeight(section: Int) -> Double { core.headerHeight(section: section) }

        func makeLayout() -> UICollectionViewLayout {
            // The headers scroll with their photos: the date pill stays at the top instead (SPEC §17.2).
            GridCollectionLayout { [weak self] sectionIndex, environment in
                self?.core.sectionMetrics(sectionIndex, width: Double(environment.container.effectiveContentSize.width), wholePoints: false)
                    .layoutSection(headerKind: UICollectionView.elementKindSectionHeader, pinsHeaders: false)
            }
        }

        // MARK: Layout

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

        // MARK: Edit ▸ Copy (⌘C on iPad)

        override func copy(_ sender: Any?) {
            guard !selected.ids.isEmpty else { return }
            callbacks?.copy?(Array(selected.ids))
        }

        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            if action == #selector(copy(_:)) { return callbacks?.copy != nil && !selected.ids.isEmpty }
            return super.canPerformAction(action, withSender: sender)
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

#endif
