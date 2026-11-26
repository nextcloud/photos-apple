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
        // What the extensions in PhotoGrid*+AppKit.swift share is internal rather than private (SPEC §20.7).
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
        let core: GridCore
        /// The photo under the pointer when a trackpad pinch began, and its distance from the top of the visible area: it
        /// stays there while the pinch changes the zoom step (SPEC §15.5).
        var pinchAnchor: (id: FileID, offset: CGFloat)?
        let scrubber = GridScrubberView()
        var sectionOffsets: [Double] = []
        private var refreshWork: DispatchWorkItem?
        var selected = GridSelectionTracker()
        lazy var promiseDelegate = FilePromiseDelegate(services: services)
        /// Ratings and flags shown on the tiles (SPEC §15.2).
        let culling: GridCullingObserver
        /// Edited photos' tiles are drawn again with their new rendition (SPEC §16.3).
        private let edits = GridEditObserver()
        /// Scrub to peek with the pointer (SPEC §16.1).
        var peek: GridPeekHover?
        /// The tile under the pointer lifts (SPEC §17.7).
        var hoverLift: GridHoverLift?
        /// A trackpad pinch zooms continuously between the steps (SPEC §17.7).
        var pinchZoom = GridPinchZoom()
        lazy var pinchScaler = GridPinchScaler(clipView: contentView)
        /// A pinch asked for another step: its relayout cross-fades from the scaled grid.
        var pinchStepPending = false

        var model: GridModel { core.model }
        var squareTiles: Bool { core.squareTiles }
        var zoomStep: Int { core.zoomStep }
        var headerMetrics: GridHeaderMetrics { core.headerMetrics }

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
        var gridWidth: Double { Double(collectionView.bounds.width) }

        /// Columns and tile side for the current width and zoom.
        var geometry: GridGeometry { core.geometry(width: gridWidth) }

        var backingScale: Double { Double(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2) }

        var headersShown: Bool { core.headersShown }

        func headerHeight(section: Int) -> Double { core.headerHeight(section: section) }

        func makeLayout() -> NSCollectionViewLayout {
            NSCollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
                // Whole points: fractional tiles are drawn blurry by AppKit.
                self?.core.sectionMetrics(sectionIndex, width: Double(environment.container.effectiveContentSize.width), wholePoints: true)
                    .layoutSection(headerKind: NSCollectionView.elementKindSectionHeader)
            }
        }

        // MARK: Layout

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
    }

    /// Peeks with the pointer (`GridGestures+AppKit`) work on this grid.
    extension PhotoGridScrollView: GridPeekHost {}
#endif
