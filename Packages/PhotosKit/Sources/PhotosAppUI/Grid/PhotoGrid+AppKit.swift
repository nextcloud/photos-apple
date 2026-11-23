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
    struct PhotoGrid: NSViewRepresentable {
        var update: GridFeed.Update
        /// Zoom step (`GridColumns.options`): sets the target tile size, the columns follow from the width.
        var zoomStep: Int
        var selection: Set<FileID>
        var isSelecting: Bool
        var showsHeaders: Bool
        var services: AccountServices
        var callbacks: GridCallbacks

        func makeNSView(context: Context) -> PhotoGridScrollView {
            PhotoGridScrollView(services: services)
        }

        func updateNSView(_ view: PhotoGridScrollView, context: Context) {
            view.callbacks = callbacks
            view.update(update, zoomStep: zoomStep, selection: selection, showsHeaders: showsHeaders)
        }
    }

    final class PhotoGridScrollView: NSScrollView, NSCollectionViewDataSource, NSCollectionViewDelegate, NSCollectionViewPrefetching {
        let services: AccountServices
        var callbacks: GridCallbacks?
        let collectionView = GridCollectionView()
        private(set) var model = GridModel.empty
        private var revision = -1
        private var zoomStep = GridColumns.default
        private var showsHeaders = true
        private var pinchAmount: CGFloat = 0
        private let headerTexts = GridHeaderTexts()
        private let headerMetrics = GridHeaderMetrics(titleHeight: 26, subtitleHeight: 16)
        private let scrubber = GridScrubberView()
        private var sectionOffsets: [Double] = []
        /// Item to keep in place across a relayout caused by a new width.
        private var resizeAnchor: FileID?
        /// Item a restore is still under way for.
        private var pendingAnchor: FileID?
        private var laidOutColumns = 0
        private var laidOutSide = 0.0
        private var refreshWork: DispatchWorkItem?
        private lazy var promiseDelegate = FilePromiseDelegate(services: services)

        init(services: AccountServices) {
            self.services = services
            super.init(frame: .zero)
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
            contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(didScroll(_:)), name: NSView.boundsDidChangeNotification, object: contentView)
        }

        required init?(coder: NSCoder) { fatalError() }

        // MARK: Geometry

        /// Columns and tile side for the current width and zoom.
        var geometry: GridGeometry {
            GridColumns.geometry(width: Double(collectionView.bounds.width), step: zoomStep)
        }

        private var backingScale: Double { Double(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2) }

        private var headersShown: Bool { showsHeaders && model.hasHeaders }

        private func headerHeight(section: Int) -> Double {
            guard headersShown, let section = model.sections[safe: section] else { return 0 }
            return headerMetrics.height(for: section)
        }

        func makeLayout() -> NSCollectionViewLayout {
            NSCollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
                self?.layoutSection(sectionIndex, width: environment.container.effectiveContentSize.width)
            }
        }

        private func layoutSection(_ sectionIndex: Int, width: CGFloat) -> NSCollectionLayoutSection {
            let geometry = GridColumns.geometry(width: Double(width), step: zoomStep)
            let spacing = CGFloat(geometry.spacing)
            let side = floor(CGFloat(geometry.side))
            let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .absolute(side), heightDimension: .absolute(side)))
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(side)), subitem: item,
                count: geometry.columns)
            group.interItemSpacing = .fixed(spacing)
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = spacing
            let height = headerHeight(section: sectionIndex)
            if height > 0 {
                let header = NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(CGFloat(height))),
                    elementKind: NSCollectionView.elementKindSectionHeader, alignment: .top)
                header.pinToVisibleBounds = true
                section.boundarySupplementaryItems = [header]
            }
            return section
        }

        // MARK: Updates

        func update(_ update: GridFeed.Update, zoomStep: Int, selection: Set<FileID>, showsHeaders: Bool) {
            let layoutChanged = zoomStep != self.zoomStep || showsHeaders != self.showsHeaders
            var change = GridModel.Change.none
            if update.revision != revision {
                // A change is relative to the revision before it; after skipped revisions everything is reloaded.
                change = update.revision == revision + 1 ? update.change : .structure
                revision = update.revision
            }
            self.zoomStep = zoomStep
            self.showsHeaders = showsHeaders

            if layoutChanged || change == .structure {
                let anchor = anchorItem()
                model = update.model
                headerTexts.reset()
                if change == .structure {
                    collectionView.reloadData()
                } else {
                    collectionView.collectionViewLayout?.invalidateLayout()
                }
                restore(anchor)
                noteLayout()
                refreshVisibleTiles()
                reloadScrubber()
            } else if case .content(let ids) = change {
                model = update.model
                refreshVisibleTiles(only: ids)
            }
            apply(selection: selection)
            #if DEBUG
                if !model.isEmpty { GridDebugKeys.runOnce(in: collectionView) }
            #endif
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

        private func apply(selection: Set<FileID>) {
            guard currentSelection() != selection else { return }
            var paths: Set<IndexPath> = []
            for id in selection {
                if let position = model.position(of: id) { paths.insert(IndexPath(item: position.item, section: position.section)) }
            }
            collectionView.selectionIndexPaths = paths
            if paths.count != selection.count {
                // Selected items that are gone (deleted, filtered out): tell SwiftUI, outside of its view update.
                let remaining = currentSelection()
                DispatchQueue.main.async { [weak self] in self?.callbacks?.selectionChanged(remaining) }
            }
        }

        func currentSelection() -> Set<FileID> {
            Set(collectionView.selectionIndexPaths.compactMap { fileId(at: $0) })
        }

        func fileId(at indexPath: IndexPath) -> FileID? {
            model.item(section: indexPath.section, item: indexPath.item)?.fileId
        }

        // MARK: Scroll position

        private var topInset: CGFloat { contentInsets.top }

        private var isAtTop: Bool { contentView.bounds.minY <= -topInset + 1 }

        /// The first item below the pinned header, unless the grid is scrolled to the top (then it stays there).
        /// Taken from the layout, not from the views on screen, which lag behind right after a relayout.
        private func anchorItem() -> FileID? {
            if let pendingAnchor { return pendingAnchor }
            guard !isAtTop, !model.isEmpty, let layout = collectionView.collectionViewLayout else { return nil }
            let top = contentView.bounds.minY + topInset
            let strip = NSRect(x: 0, y: top, width: collectionView.bounds.width, height: CGFloat(geometry.side) + 80)
            var best: IndexPath?
            for attributes in layout.layoutAttributesForElements(in: strip) where attributes.representedElementCategory == .item {
                guard let indexPath = attributes.indexPath else { continue }
                guard attributes.frame.maxY > top + CGFloat(headerHeight(section: indexPath.section)) + 1 else { continue }
                if best.map({ indexPath < $0 }) ?? true { best = indexPath }
            }
            return best.flatMap { fileId(at: $0) }
        }

        private func restore(_ anchor: FileID?) {
            guard let anchor else { return }
            pendingAnchor = anchor
            restoreNow(anchor)
            // The collection view may only take its new height in the next layout pass: make sure of the position then.
            // Until then the anchor stays the same, whatever else is relaid out in between.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.pendingAnchor == anchor else { return }
                self.restoreNow(anchor)
                self.pendingAnchor = nil
            }
        }

        private func restoreNow(_ anchor: FileID) {
            guard let position = model.position(of: anchor) else { return }
            collectionView.needsLayout = true
            collectionView.layoutSubtreeIfNeeded()
            // Scrolling is limited by the document's frame, which can still be the one of the old layout.
            if let height = collectionView.collectionViewLayout?.collectionViewContentSize.height, collectionView.frame.height < height {
                collectionView.setFrameSize(NSSize(width: collectionView.frame.width, height: height))
            }
            let indexPath = IndexPath(item: position.item, section: position.section)
            guard let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame else { return }
            scroll(toDocumentY: frame.minY - CGFloat(headerHeight(section: position.section)))
        }

        /// Scrolls so that the document offset `y` is at the top of the visible area (below the toolbar).
        private func scroll(toDocumentY y: CGFloat) {
            let maxY = max(collectionView.frame.height - contentView.bounds.height, -topInset)
            contentView.scroll(to: NSPoint(x: contentView.bounds.minX, y: min(max(y - topInset, -topInset), maxY)))
            reflectScrolledClipView(contentView)
        }

        override func setFrameSize(_ newSize: NSSize) {
            if newSize.width != frame.width, resizeAnchor == nil { resizeAnchor = anchorItem() }
            super.setFrameSize(newSize)
        }

        override func layout() {
            super.layout()
            let geometry = geometry
            if geometry.columns != laidOutColumns, laidOutColumns != 0 {
                restore(resizeAnchor)
                reloadScrubber()
            }
            resizeAnchor = nil
            if geometry.side != laidOutSide {
                // The tile size follows the width: fetch sharper previews once resizing has settled.
                refreshWork?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.refreshVisibleTiles() }
                refreshWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
            }
            noteLayout()
        }

        private func noteLayout() {
            let geometry = geometry
            laidOutColumns = geometry.columns
            laidOutSide = geometry.side
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
            sectionOffsets = geometry.sectionOffsets(
                itemCounts: sections.map(\.range.count), headerHeights: sections.map { headerMetrics.height(for: $0) })
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
            if let section = model.sections[safe: indexPath.section] {
                view.configure(headerTexts.text(for: section), metrics: headerMetrics)
            }
            return view
        }

        // MARK: Events

        @objc func handleDoubleClick(_ gesture: NSClickGestureRecognizer) {
            let point = gesture.location(in: collectionView)
            guard let indexPath = collectionView.indexPathForItem(at: point), let id = fileId(at: indexPath) else { return }
            callbacks?.open(id)
        }

        @objc func handleMagnify(_ gesture: NSMagnificationGestureRecognizer) {
            switch gesture.state {
            case .began: pinchAmount = 0
            case .changed:
                pinchAmount = gesture.magnification
                guard abs(pinchAmount) > 0.3 else { return }
                let zoomIn = pinchAmount > 0
                pinchAmount = 0
                gesture.state = .ended
                zoom(in: zoomIn)
            default: break
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
            callbacks?.selectionChanged(currentSelection())
        }

        func zoom(in zoomIn: Bool) {
            let next = GridColumns.step(zoomStep, zoomIn: zoomIn)
            if next != zoomStep { callbacks?.columnsChanged(next) }
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
                callbacks.selectionChanged(ids)
            }
            let targets = Array(ids)
            let menu = NSMenu()
            for action in callbacks.menu(targets) {
                let item = MenuActionItem(title: action.title, handler: { action.handler(targets) })
                item.image = NSImage(systemSymbolName: action.systemImage, accessibilityDescription: nil)
                menu.addItem(item)
            }
            return menu.items.isEmpty ? nil : menu
        }

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

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            callbacks?.selectionChanged(currentSelection())
        }

        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            callbacks?.selectionChanged(currentSelection())
        }

        func collectionView(_ collectionView: NSCollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
            let side = geometry.side
            let scale = backingScale
            let requests = indexPaths.compactMap { model.item(section: $0.section, item: $0.item) }
                .map { services.previewRequest(for: $0, tileSide: side, scale: scale) }
            Task { await services.images.prefetch(requests) }
        }
    }

    /// Writes originals for file promises (drag to Finder and other apps).
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
                    "left": (String(UnicodeScalar(NSLeftArrowFunctionKey)!), 123), "right": (String(UnicodeScalar(NSRightArrowFunctionKey)!), 124),
                    "down": (String(UnicodeScalar(NSDownArrowFunctionKey)!), 125), "up": (String(UnicodeScalar(NSUpArrowFunctionKey)!), 126),
                    "return": ("\r", 36), "space": (" ", 49), "escape": ("\u{1b}", 53),
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
            return actions.map { action in
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
            gradient.colors = [NSColor.black.withAlphaComponent(0.5).cgColor, NSColor.clear.cgColor]
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
        private let selectionRing = NSView()
        private(set) var fileId: FileID?
        private var request: ImagePipeline.Request?
        /// A real picture (not just the BlurHash) is shown.
        private var hasPicture = false
        private var isLoading = false
        private var task: Task<Void, Never>?

        override func loadView() {
            let container = tileView
            container.wantsLayer = true
            container.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            container.layer?.masksToBounds = true
            photoView.wantsLayer = true
            photoView.layer?.contentsGravity = .resizeAspectFill
            photoView.layer?.masksToBounds = true
            placeholderIcon.contentTintColor = .tertiaryLabelColor
            placeholderIcon.imageScaling = .scaleProportionallyUpOrDown
            placeholderIcon.isHidden = true
            durationLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            durationLabel.textColor = .white
            for icon in [favoriteIcon, liveIcon, videoIcon] {
                icon.contentTintColor = .white
                icon.imageScaling = .scaleProportionallyUpOrDown
            }
            selectionRing.wantsLayer = true
            selectionRing.layer?.borderColor = NSColor.controlAccentColor.cgColor
            selectionRing.layer?.borderWidth = 3
            selectionRing.isHidden = true
            [photoView, placeholderIcon, shade, durationLabel, videoIcon, favoriteIcon, liveIcon, selectionRing].forEach {
                container.addSubview($0)
            }
            view = container
        }

        override func viewDidLayout() {
            super.viewDidLayout()
            let bounds = view.bounds
            photoView.frame = bounds
            selectionRing.frame = bounds
            let glyph = min(max(bounds.width * 0.34, 14), 44)
            placeholderIcon.frame = CGRect(x: (bounds.width - glyph) / 2, y: (bounds.height - glyph) / 2, width: glyph, height: glyph)
            shade.frame = CGRect(x: 0, y: 0, width: bounds.width, height: min(bounds.height * 0.4, 36))
            durationLabel.sizeToFit()
            var right = bounds.width - 5
            if !durationLabel.isHidden {
                durationLabel.frame.origin = CGPoint(x: right - durationLabel.frame.width, y: 3)
                right = durationLabel.frame.minX - 3
            }
            videoIcon.frame = CGRect(x: right - 16, y: 4, width: 16, height: 12)
            favoriteIcon.frame = CGRect(x: 5, y: 4, width: 13, height: 12)
            liveIcon.frame = CGRect(x: 4, y: bounds.height - 20, width: 16, height: 16)
        }

        override var isSelected: Bool {
            didSet {
                selectionRing.isHidden = !isSelected
                photoView.alphaValue = isSelected ? 0.8 : 1
                tileView.isTileSelected = isSelected
            }
        }

        /// Shows `item`. Called again for the same item when its badges, the zoom or the screen scale change: the
        /// picture then stays until a sharper one has loaded (no flash).
        func configure(item: GridMedia, owner: PhotoGridScrollView, tileSide: Double, scale: Double) {
            let services = owner.services
            let request = services.previewRequest(for: item, tileSide: tileSide, scale: scale)
            let sameItem = fileId == item.fileId && self.request?.etag == item.etag
            fileId = item.fileId
            updateBadges(item, owner: owner)
            if sameItem, request == self.request, hasPicture || isLoading { return }
            task?.cancel()
            self.request = request
            if !sameItem {
                hasPicture = false
                photoView.layer?.contents = nil
                placeholderIcon.isHidden = true
            }
            let cache = services.images.cache
            if let best = cache.bestMemoryImage(fileId: item.fileId, etag: item.etag, upTo: 4096) {
                setPicture(best)
                // Large enough (for instance after zooming out): nothing to load.
                if GridTile.covers(best, bucket: request.bucket) {
                    isLoading = false
                    return
                }
            } else if !hasPicture, let blur = BlurHashCache.image(item.blurhash) {
                photoView.layer?.contents = blur
            }
            isLoading = true
            task = Task { [weak self] in
                let image = await services.images.preview(request)
                guard !Task.isCancelled, let self, self.request == request else { return }
                self.isLoading = false
                if let image {
                    self.setPicture(image)
                } else if !self.hasPicture {
                    // No preview to be had (no server preview, broken or unsupported file): say what it is.
                    self.showPlaceholder(for: item)
                }
            }
        }

        private func setPicture(_ image: CGImage) {
            photoView.layer?.contents = image
            hasPicture = true
            placeholderIcon.isHidden = true
        }

        private func showPlaceholder(for item: GridMedia) {
            let symbol = GridTile.placeholderSymbol(for: item)
            placeholderIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            placeholderIcon.isHidden = false
        }

        private func updateBadges(_ item: GridMedia, owner: PhotoGridScrollView) {
            let duration = GridTile.durationText(for: item)
            durationLabel.stringValue = duration ?? ""
            durationLabel.isHidden = duration == nil
            videoIcon.isHidden = item.kind != .video
            favoriteIcon.isHidden = !item.isFavorite
            liveIcon.isHidden = !item.isLivePhoto
            shade.isHidden = !GridTile.showsBottomShade(for: item)
            let id = item.fileId
            tileView.fileId = id
            tileView.label = GridTile.accessibilityLabel(for: item)
            tileView.onPress = { [weak owner] in owner?.open(id) }
            tileView.actions = { [weak owner] in owner?.menuActions(for: id) ?? [] }
            view.needsLayout = true
        }

        override func prepareForReuse() {
            super.prepareForReuse()
            task?.cancel()
            task = nil
            fileId = nil
            request = nil
            hasPicture = false
            isLoading = false
            photoView.layer?.contents = nil
            placeholderIcon.isHidden = true
        }
    }

    final class SectionHeaderView: NSVisualEffectView, NSCollectionViewElement {
        static let identifier = NSUserInterfaceItemIdentifier("SectionHeader")
        private let titleLabel = NSTextField(labelWithString: "")
        private let subtitleLabel = NSTextField(labelWithString: "")
        private var metrics = GridHeaderMetrics(titleHeight: 26, subtitleHeight: 16)

        override init(frame: NSRect) {
            super.init(frame: frame)
            material = .headerView
            blendingMode = .withinWindow
            titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
            titleLabel.lineBreakMode = .byTruncatingTail
            titleLabel.setAccessibilityRole(.staticText)
            subtitleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
            subtitleLabel.textColor = .secondaryLabelColor
            subtitleLabel.lineBreakMode = .byTruncatingTail
            addSubview(titleLabel)
            addSubview(subtitleLabel)
        }

        required init?(coder: NSCoder) { fatalError() }

        override var isFlipped: Bool { true }

        func configure(_ text: GridHeaderText, metrics: GridHeaderMetrics) {
            self.metrics = metrics
            titleLabel.stringValue = text.title ?? ""
            titleLabel.isHidden = text.title == nil
            subtitleLabel.stringValue = text.subtitle ?? ""
            subtitleLabel.isHidden = text.subtitle == nil
            needsLayout = true
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
        }
    }
#endif
