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
            controller.update(update, zoomStep: zoomStep, selection: selection, isSelecting: isSelecting, showsHeaders: showsHeaders)
        }
    }

    final class PhotoGridController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate,
        UICollectionViewDataSourcePrefetching, UICollectionViewDragDelegate
    {
        let services: AccountServices
        var callbacks: GridCallbacks? {
            didSet { updateRefreshControl() }
        }
        private let refreshRunner = GridRefreshRunner()
        /// A two-finger drag over the tiles is selecting right now.
        private var multiSelectInteraction = false
        private var collectionView: UICollectionView!
        /// Model, zoom, anchor and layout bookkeeping, shared with the AppKit grid.
        private let core: GridCore
        private var isSelecting = false
        private var pinchHandled = false

        var model: GridModel { core.model }
        private var zoomStep: Int { core.zoomStep }
        private var headerMetrics: GridHeaderMetrics { core.headerMetrics }

        init(services: AccountServices) {
            self.services = services
            core = GridCore(services: services, headerMetrics: Self.currentHeaderMetrics)
            super.init(nibName: nil, bundle: nil)
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

            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            collectionView.addGestureRecognizer(pinch)

            // Header heights are absolute and follow the text size.
            registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (controller: PhotoGridController, _: UITraitCollection) in
                controller.core.headerMetrics = Self.currentHeaderMetrics
                controller.collectionView.collectionViewLayout.invalidateLayout()
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

        func update(_ update: GridFeed.Update, zoomStep: Int, selection: Set<FileID>, isSelecting: Bool, showsHeaders: Bool) {
            loadViewIfNeeded()
            let plan = core.begin(update, zoomStep: zoomStep, showsHeaders: showsHeaders)
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
            } else if case .content(let ids) = plan.change {
                core.show(update.model, relayout: false)
                refreshVisibleTiles(only: ids)
            }
            // While a two-finger drag selects, SwiftUI may not have heard of the selection mode yet: it stays on.
            if isSelecting != self.isSelecting, isSelecting || !multiSelectInteraction {
                setSelecting(isSelecting)
            }
            syncSelection(selection)
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

        func syncSelection(_ selection: Set<FileID>) {
            let selected = currentSelection()
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
            return [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancelSelection))]
        }

        /// Escape: leave the selection mode.
        @objc func cancelSelection() {
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

        /// Year index (native section index as date scrubber).
        func indexTitles(for collectionView: UICollectionView) -> [String]? {
            guard headersShown else { return nil }
            let years = model.yearStarts
            return years.count > 1 ? years.map { String($0.year) } : nil
        }

        func collectionView(_ collectionView: UICollectionView, indexPathForIndexTitle title: String, at index: Int) -> IndexPath {
            IndexPath(item: 0, section: model.yearStarts[safe: index]?.section ?? 0)
        }

        // MARK: Delegate

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            guard let id = fileId(at: indexPath) else { return }
            if isSelecting {
                callbacks?.selectionChanged(currentSelection())
            } else {
                collectionView.deselectItem(at: indexPath, animated: false)
                callbacks?.open(id)
            }
        }

        func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
            if isSelecting { callbacks?.selectionChanged(currentSelection()) }
        }

        func collectionView(_ collectionView: UICollectionView, canFocusItemAt indexPath: IndexPath) -> Bool { true }

        /// Return on the focused tile (hardware keyboard). A tap also ends up here after `didSelectItemAt`; opening the
        /// same photo twice is one and the same viewer.
        func collectionView(_ collectionView: UICollectionView, performPrimaryActionForItemAt indexPath: IndexPath) {
            guard !isSelecting, let id = fileId(at: indexPath) else { return }
            callbacks?.open(id)
        }

        func collectionView(_ collectionView: UICollectionView, shouldBeginMultipleSelectionInteractionAt indexPath: IndexPath) -> Bool {
            true
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
            callbacks?.selectionChanged(currentSelection())
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
            return UIContextMenuConfiguration(identifier: identifier, previewProvider: preview) { _ in
                // Each group is an inline menu: UIKit draws the separators between them.
                let groups: [UIMenuElement] = GridMenuAction.groups(actions).map { group in
                    UIMenu(
                        options: .displayInline,
                        children: group.map { action in
                            UIAction(
                                title: action.title, image: UIImage(systemName: action.systemImage),
                                attributes: action.isDestructive ? .destructive : []
                            ) { _ in action.handler(ids) }
                        })
                }
                return UIMenu(children: groups)
            }
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
        private let checkmark = UIImageView()
        private let gradient = CAGradientLayer()
        /// Loads the preview and says what to draw; shared with the AppKit grid.
        private let tilePicture = GridTilePicture()
        var fileId: FileID? { tilePicture.fileId }
        private var menuActions: (() -> [GridMenuAction])?

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
            for icon in [favoriteIcon, liveIcon, videoIcon] {
                icon.tintColor = .white
                icon.contentMode = .scaleAspectFit
            }
            checkmark.contentMode = .scaleAspectFit
            // The empty circle is white on the photo: a soft shadow keeps it visible on bright pictures.
            checkmark.layer.shadowColor = UIColor.black.cgColor
            checkmark.layer.shadowOpacity = 0.35
            checkmark.layer.shadowRadius = 1.5
            checkmark.layer.shadowOffset = .zero
            [durationLabel, videoIcon, favoriteIcon, liveIcon, checkmark].forEach { contentView.addSubview($0) }
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
            let bounds = contentView.bounds
            imageView.frame = bounds
            let glyph = min(max(bounds.width * 0.34, 14), 44)
            placeholderIcon.frame = CGRect(x: (bounds.width - glyph) / 2, y: (bounds.height - glyph) / 2, width: glyph, height: glyph)
            gradient.frame = CGRect(x: 0, y: bounds.height * 0.6, width: bounds.width, height: bounds.height * 0.4)
            // The selection mark sits in the bottom trailing corner, as in Apple Photos; duration and video badge
            // move left of it.
            let mark = CGFloat(GridTile.checkmarkSide(tileSide: Double(bounds.width)))
            checkmark.frame = CGRect(x: bounds.width - mark - 4, y: bounds.height - mark - 4, width: mark, height: mark)
            let markShown = !checkmark.isHidden
            let trailingBadges = GridTile.showsTrailingBadges(tileSide: Double(bounds.width), checkmarkShown: markShown)
            durationLabel.alpha = trailingBadges ? 1 : 0
            videoIcon.alpha = trailingBadges ? 1 : 0
            durationLabel.sizeToFit()
            var right = markShown ? checkmark.frame.minX - 4 : bounds.width - 4
            if !durationLabel.isHidden {
                durationLabel.frame.origin = CGPoint(
                    x: right - durationLabel.bounds.width, y: bounds.height - durationLabel.bounds.height - 3)
                right = durationLabel.frame.minX - 3
            }
            videoIcon.frame = CGRect(x: right - 16, y: bounds.height - 16, width: 16, height: 12)
            favoriteIcon.frame = CGRect(x: 4, y: bounds.height - 16, width: 13, height: 12)
            liveIcon.frame = CGRect(x: 4, y: 4, width: 16, height: 16)
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
            imageView.alpha = selected ? 0.75 : 1
            if selected { accessibilityTraits.insert(.selected) } else { accessibilityTraits.remove(.selected) }
            // The badges make room for the mark.
            if wasHidden != checkmark.isHidden { setNeedsLayout() }
        }

        /// Shows `item`. Called again for the same item when its badges, the zoom or the screen scale change: the
        /// picture then stays until a sharper one has loaded (no flash).
        func configure(item: GridMedia, owner: PhotoGridController, tileSide: Double, scale: Double) {
            let services = owner.services
            updateBadges(item, owner: owner)
            setNeedsUpdateConfiguration()
            tilePicture.configure(
                item: item, request: services.previewRequest(for: item, tileSide: tileSide, scale: scale),
                source: GridTilePicture.Source(services: services))
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
            let badges = GridTileBadges(item: item)
            durationLabel.text = badges.duration
            durationLabel.isHidden = badges.duration == nil
            videoIcon.isHidden = !badges.showsVideo
            favoriteIcon.isHidden = !badges.showsFavorite
            liveIcon.isHidden = !badges.showsLivePhoto
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
                return actions.map { action in
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
