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
            controller.callbacks = callbacks
            controller.update(update, zoomStep: zoomStep, selection: selection, isSelecting: isSelecting, showsHeaders: showsHeaders)
        }
    }

    final class PhotoGridController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate,
        UICollectionViewDataSourcePrefetching
    {
        let services: AccountServices
        var callbacks: GridCallbacks?
        private var collectionView: UICollectionView!
        private(set) var model = GridModel.empty
        private var revision = -1
        private var zoomStep = GridColumns.default
        private var showsHeaders = true
        private var isSelecting = false
        private var pinchHandled = false
        private let headerTexts = GridHeaderTexts()
        /// Item to keep in place across a relayout caused by a new width (rotation, split view).
        private var resizeAnchor: FileID?
        /// Item a restore is still under way for.
        private var pendingAnchor: FileID?
        private var laidOutColumns = 0
        private var laidOutSide = 0.0

        init(services: AccountServices) {
            self.services = services
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
                controller.collectionView.collectionViewLayout.invalidateLayout()
            }
            registerForTraitChanges([UITraitDisplayScale.self]) { (controller: PhotoGridController, _: UITraitCollection) in
                controller.refreshVisibleTiles()
            }
        }

        // MARK: Geometry

        /// Columns and tile side for the current width and zoom.
        var geometry: GridGeometry {
            GridColumns.geometry(width: Double(collectionView?.bounds.width ?? view.bounds.width), step: zoomStep)
        }

        /// Scale for preview requests, capped at 2 (SPEC §5.5.1): a 3× preview of every tile costs more memory and
        /// traffic than it shows.
        private var previewScale: Double { Double(min(view.traitCollection.displayScale, 2)) }

        private var headersShown: Bool { showsHeaders && model.hasHeaders }

        private var headerMetrics: GridHeaderMetrics {
            GridHeaderMetrics(
                titleHeight: Double(SectionHeader.titleFont.lineHeight.rounded(.up)),
                subtitleHeight: Double(SectionHeader.subtitleFont.lineHeight.rounded(.up)))
        }

        private func headerHeight(section: Int, metrics: GridHeaderMetrics? = nil) -> Double {
            guard headersShown, let section = model.sections[safe: section] else { return 0 }
            return (metrics ?? headerMetrics).height(for: section)
        }

        func makeLayout() -> UICollectionViewLayout {
            UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
                self?.layoutSection(sectionIndex, width: environment.container.effectiveContentSize.width)
            }
        }

        private func layoutSection(_ sectionIndex: Int, width: CGFloat) -> NSCollectionLayoutSection {
            let geometry = GridColumns.geometry(width: Double(width), step: zoomStep)
            let spacing = CGFloat(geometry.spacing)
            let side = CGFloat(geometry.side)
            let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .absolute(side), heightDimension: .absolute(side)))
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(side)), repeatingSubitem: item,
                count: geometry.columns)
            group.interItemSpacing = .fixed(spacing)
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = spacing
            let height = headerHeight(section: sectionIndex)
            if height > 0 {
                let header = NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(CGFloat(height))),
                    elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
                header.pinToVisibleBounds = true
                section.boundarySupplementaryItems = [header]
            }
            return section
        }

        // MARK: Updates

        func update(_ update: GridFeed.Update, zoomStep: Int, selection: Set<FileID>, isSelecting: Bool, showsHeaders: Bool) {
            loadViewIfNeeded()
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
                let relayout: () -> Void = { [self] in
                    if change == .structure {
                        collectionView.reloadData()
                    } else {
                        collectionView.collectionViewLayout.invalidateLayout()
                    }
                    restore(anchor)
                }
                if layoutChanged, view.window != nil, !UIAccessibility.isReduceMotionEnabled {
                    // Zoom: a short cross-fade between the two layouts.
                    UIView.transition(with: collectionView, duration: 0.2, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                        relayout()
                    }
                } else {
                    relayout()
                }
                noteLayout()
                refreshVisibleTiles()
            } else if case .content(let ids) = change {
                model = update.model
                refreshVisibleTiles(only: ids)
            }
            if isSelecting != self.isSelecting {
                self.isSelecting = isSelecting
                collectionView.isEditing = isSelecting
                collectionView.allowsMultipleSelection = isSelecting
            }
            syncSelection(selection)
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

        func fileId(at indexPath: IndexPath) -> FileID? {
            model.item(section: indexPath.section, item: indexPath.item)?.fileId
        }

        private func indexPath(for id: FileID) -> IndexPath? {
            model.position(of: id).map { IndexPath(item: $0.item, section: $0.section) }
        }

        // MARK: Scroll position

        private var topInset: CGFloat { collectionView.adjustedContentInset.top }

        /// The first item below the pinned header, unless the grid is scrolled to the top (then it stays there).
        /// Taken from the layout, not from the cells on screen, which lag behind right after a relayout.
        private func anchorItem() -> FileID? {
            if let pendingAnchor { return pendingAnchor }
            guard isViewLoaded, !model.isEmpty, collectionView.contentOffset.y > -topInset + 1 else { return nil }
            let top = collectionView.contentOffset.y + topInset
            let metrics = headerMetrics
            let strip = CGRect(x: 0, y: top, width: collectionView.bounds.width, height: CGFloat(geometry.side) + 100)
            var best: IndexPath?
            for attributes in collectionView.collectionViewLayout.layoutAttributesForElements(in: strip) ?? []
            where attributes.representedElementCategory == .cell {
                let indexPath = attributes.indexPath
                guard attributes.frame.maxY > top + CGFloat(headerHeight(section: indexPath.section, metrics: metrics)) + 1 else {
                    continue
                }
                if best.map({ indexPath < $0 }) ?? true { best = indexPath }
            }
            return best.flatMap { fileId(at: $0) }
        }

        private func restore(_ anchor: FileID?) {
            guard let anchor else { return }
            pendingAnchor = anchor
            restoreNow(anchor)
            // Once more when the layout pass is through. Until then the anchor stays the same, whatever else is relaid
            // out in between.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.pendingAnchor == anchor else { return }
                self.restoreNow(anchor)
                self.pendingAnchor = nil
            }
        }

        private func restoreNow(_ anchor: FileID) {
            guard let indexPath = indexPath(for: anchor) else { return }
            collectionView.layoutIfNeeded()
            guard let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame else { return }
            let contentHeight = max(collectionView.contentSize.height, collectionView.collectionViewLayout.collectionViewContentSize.height)
            let maxY = max(contentHeight + collectionView.adjustedContentInset.bottom - collectionView.bounds.height, -topInset)
            let y = frame.minY - CGFloat(headerHeight(section: indexPath.section)) - topInset
            collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: min(max(y, -topInset), maxY)), animated: false)
        }

        override func viewWillLayoutSubviews() {
            super.viewWillLayoutSubviews()
            // The collection view still has its old width here.
            if collectionView.bounds.width != view.bounds.width, resizeAnchor == nil { resizeAnchor = anchorItem() }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            let geometry = geometry
            if geometry.columns != laidOutColumns, laidOutColumns != 0 { restore(resizeAnchor) }
            resizeAnchor = nil
            if geometry.side != laidOutSide { refreshVisibleTiles() }
            noteLayout()
        }

        private func noteLayout() {
            let geometry = geometry
            laidOutColumns = geometry.columns
            laidOutSide = geometry.side
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
                header.configure(headerTexts.text(for: section), metrics: headerMetrics)
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

        func collectionView(_ collectionView: UICollectionView, didBeginMultipleSelectionInteractionAt indexPath: IndexPath) {
            if !isSelecting { callbacks?.selectionChanged(currentSelection()) }
        }

        func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint)
            -> UIContextMenuConfiguration?
        {
            let ids = indexPaths.compactMap { fileId(at: $0) }
            guard !ids.isEmpty, let callbacks else { return nil }
            let actions = callbacks.menu(ids)
            guard !actions.isEmpty else { return nil }
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
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
            let side = geometry.side
            let scale = previewScale
            return indexPaths.compactMap { model.item(section: $0.section, item: $0.item) }
                .map { services.previewRequest(for: $0, tileSide: side, scale: scale) }
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
        private(set) var fileId: FileID?
        private var request: ImagePipeline.Request?
        /// A real picture (not just the BlurHash) is shown.
        private var hasPicture = false
        private var isLoading = false
        private var task: Task<Void, Never>?
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
            [durationLabel, videoIcon, favoriteIcon, liveIcon, checkmark].forEach { contentView.addSubview($0) }
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
            durationLabel.sizeToFit()
            var right = bounds.width - 4
            if !durationLabel.isHidden {
                durationLabel.frame.origin = CGPoint(
                    x: right - durationLabel.bounds.width, y: bounds.height - durationLabel.bounds.height - 3)
                right = durationLabel.frame.minX - 3
            }
            videoIcon.frame = CGRect(x: right - 16, y: bounds.height - 16, width: 16, height: 12)
            favoriteIcon.frame = CGRect(x: 4, y: bounds.height - 16, width: 13, height: 12)
            liveIcon.frame = CGRect(x: 4, y: 4, width: 16, height: 16)
            checkmark.frame = CGRect(x: bounds.width - 26, y: 4, width: 22, height: 22)
        }

        override var isSelected: Bool {
            didSet { updateSelection() }
        }

        func updateSelection() {
            let editing = (superview as? UICollectionView)?.isEditing ?? false
            checkmark.isHidden = !(editing || isSelected)
            checkmark.image = UIImage(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            checkmark.tintColor = isSelected ? .tintColor : .white
            imageView.alpha = isSelected ? 0.75 : 1
            if isSelected { accessibilityTraits.insert(.selected) } else { accessibilityTraits.remove(.selected) }
        }

        /// Shows `item`. Called again for the same item when its badges, the zoom or the screen scale change: the
        /// picture then stays until a sharper one has loaded (no flash).
        func configure(item: GridMedia, owner: PhotoGridController, tileSide: Double, scale: Double) {
            let services = owner.services
            let request = services.previewRequest(for: item, tileSide: tileSide, scale: scale)
            let sameItem = fileId == item.fileId && self.request?.etag == item.etag
            fileId = item.fileId
            updateBadges(item, owner: owner)
            updateSelection()
            if sameItem, request == self.request, hasPicture || isLoading { return }
            task?.cancel()
            self.request = request
            if !sameItem {
                hasPicture = false
                imageView.image = nil
                placeholderIcon.isHidden = true
            }
            let cache = services.images.cache
            if let best = cache.bestMemoryImage(fileId: item.fileId, etag: item.etag, upTo: 4096) {
                setPicture(best)
                // Large enough (for instance after zooming out): nothing to load.
                if GridTile.covers(best, pixels: request.decodeSize) {
                    isLoading = false
                    return
                }
            } else if !hasPicture, let blur = BlurHashCache.image(item.blurhash) {
                imageView.image = UIImage(cgImage: blur)
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
                    self.placeholderIcon.image = UIImage(systemName: GridTile.placeholderSymbol(for: item))
                    self.placeholderIcon.isHidden = false
                }
            }
        }

        private func setPicture(_ image: CGImage) {
            imageView.image = UIImage(cgImage: image)
            hasPicture = true
            placeholderIcon.isHidden = true
        }

        private func updateBadges(_ item: GridMedia, owner: PhotoGridController) {
            let duration = GridTile.durationText(for: item)
            durationLabel.text = duration
            durationLabel.isHidden = duration == nil
            videoIcon.isHidden = item.kind != .video
            favoriteIcon.isHidden = !item.isFavorite
            liveIcon.isHidden = !item.isLivePhoto
            gradient.isHidden = !GridTile.showsBottomShade(for: item)
            let increased = UIAccessibility.isDarkerSystemColorsEnabled || UIAccessibility.isReduceTransparencyEnabled
            gradient.colors = [
                UIColor.clear.cgColor, UIColor.black.withAlphaComponent(GridTile.shadeOpacity(increased: increased)).cgColor,
            ]
            accessibilityLabel = GridTile.accessibilityLabel(for: item)
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
            task?.cancel()
            task = nil
            fileId = nil
            request = nil
            hasPicture = false
            isLoading = false
            imageView.image = nil
            placeholderIcon.isHidden = true
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
