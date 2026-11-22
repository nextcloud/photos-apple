// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

#if os(macOS)
    import AppKit
    import PhotosCore
    import PhotosMedia
    import PhotosModel
    import PhotosStore
    import SwiftUI

    /// The photo grid on macOS (SPEC §6.4): rubber-band, ⇧/⌘-click selection and arrow keys come from NSCollectionView.
    struct PhotoGrid: NSViewRepresentable {
        var sections: [GridSection]
        var items: [FileID: GridMedia]
        var columns: Int
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
            view.update(sections: sections, items: items, columns: columns, selection: selection, showsHeaders: showsHeaders)
        }
    }

    final class PhotoGridScrollView: NSScrollView, NSCollectionViewDelegate, NSCollectionViewPrefetching {
        let services: AccountServices
        var callbacks: GridCallbacks?
        let collectionView = GridCollectionView()
        private var dataSource: NSCollectionViewDiffableDataSource<Int, FileID>!
        private(set) var items: [FileID: GridMedia] = [:]
        private var sections: [GridSection] = []
        private var columns = GridColumns.default
        private var showsHeaders = true
        private var pinchAmount: CGFloat = 0

        init(services: AccountServices) {
            self.services = services
            super.init(frame: .zero)
            collectionView.collectionViewLayout = makeLayout()
            collectionView.isSelectable = true
            collectionView.allowsMultipleSelection = true
            collectionView.allowsEmptySelection = true
            collectionView.delegate = self
            collectionView.prefetchDataSource = self
            collectionView.backgroundColors = [.clear]
            collectionView.register(PhotoItem.self, forItemWithIdentifier: PhotoItem.identifier)
            collectionView.register(
                SectionHeaderView.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                withIdentifier: SectionHeaderView.identifier)
            collectionView.owner = self
            documentView = collectionView
            hasVerticalScroller = true
            drawsBackground = false

            dataSource = NSCollectionViewDiffableDataSource(collectionView: collectionView) {
                [weak self] collectionView, indexPath, fileId in
                let item = collectionView.makeItem(withIdentifier: PhotoItem.identifier, for: indexPath) as! PhotoItem
                if let self, let gridItem = self.items[fileId] {
                    item.configure(item: gridItem, services: self.services, pixels: self.tilePixels)
                }
                return item
            }
            dataSource.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
                let view =
                    collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: SectionHeaderView.identifier, for: indexPath)
                    as! SectionHeaderView
                if let section = self?.sections[safe: indexPath.section] {
                    view.configure(title: section.title, monthTitle: section.monthTitle)
                }
                return view
            }
            let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick(_:)))
            doubleClick.numberOfClicksRequired = 2
            doubleClick.delaysPrimaryMouseButtonEvents = false
            collectionView.addGestureRecognizer(doubleClick)
            let magnify = NSMagnificationGestureRecognizer(target: self, action: #selector(handleMagnify(_:)))
            collectionView.addGestureRecognizer(magnify)
        }

        required init?(coder: NSCoder) { fatalError() }

        var tilePixels: Double {
            let width = (bounds.width - CGFloat(columns - 1) * Design.tileSpacing) / CGFloat(max(columns, 1))
            return Double(width * (window?.backingScaleFactor ?? 2))
        }

        func update(sections: [GridSection], items: [FileID: GridMedia], columns: Int, selection: Set<FileID>, showsHeaders: Bool) {
            self.items = items
            if columns != self.columns || showsHeaders != self.showsHeaders {
                self.columns = columns
                self.showsHeaders = showsHeaders
                collectionView.collectionViewLayout = makeLayout()
            }
            if sections != self.sections {
                self.sections = sections
                var snapshot = NSDiffableDataSourceSnapshot<Int, FileID>()
                snapshot.appendSections(sections.map(\.id))
                for section in sections { snapshot.appendItems(section.items, toSection: section.id) }
                dataSource.apply(snapshot, animatingDifferences: false)
            } else {
                for case let item as PhotoItem in collectionView.visibleItems() {
                    if let id = item.fileId, let gridItem = items[id] { item.updateBadges(gridItem) }
                }
            }
            let current = currentSelection()
            if current != selection {
                let paths = Set(selection.compactMap { dataSource.indexPath(for: $0) })
                collectionView.selectionIndexPaths = paths
            }
        }

        func currentSelection() -> Set<FileID> {
            Set(collectionView.selectionIndexPaths.compactMap { dataSource.itemIdentifier(for: $0) })
        }

        func makeLayout() -> NSCollectionViewLayout {
            let columns = self.columns
            let spacing = Design.tileSpacing
            let headers = showsHeaders
            return NSCollectionViewCompositionalLayout { _, environment in
                let width = environment.container.effectiveContentSize.width
                let side = floor((width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
                let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .absolute(side), heightDimension: .absolute(side)))
                let group = NSCollectionLayoutGroup.horizontal(
                    layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(side)), subitem: item, count: columns)
                group.interItemSpacing = .fixed(spacing)
                let section = NSCollectionLayoutSection(group: group)
                section.interGroupSpacing = spacing
                if headers {
                    let header = NSCollectionLayoutBoundarySupplementaryItem(
                        layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(40)),
                        elementKind: NSCollectionView.elementKindSectionHeader, alignment: .top)
                    header.pinToVisibleBounds = true
                    section.boundarySupplementaryItems = [header]
                }
                return section
            }
        }

        // MARK: Events

        @objc func handleDoubleClick(_ gesture: NSClickGestureRecognizer) {
            let point = gesture.location(in: collectionView)
            guard let indexPath = collectionView.indexPathForItem(at: point), let id = dataSource.itemIdentifier(for: indexPath) else {
                return
            }
            callbacks?.open(id)
        }

        @objc func handleMagnify(_ gesture: NSMagnificationGestureRecognizer) {
            switch gesture.state {
            case .began: pinchAmount = 0
            case .changed:
                pinchAmount = gesture.magnification
                guard abs(pinchAmount) > 0.3 else { return }
                let next = GridColumns.step(columns, zoomIn: pinchAmount > 0)
                pinchAmount = 0
                gesture.state = .ended
                if next != columns { callbacks?.columnsChanged(next) }
            default: break
            }
        }

        func openSelection() {
            if let first = collectionView.selectionIndexPaths.sorted().first, let id = dataSource.itemIdentifier(for: first) {
                callbacks?.open(id)
            }
        }

        func zoom(in zoomIn: Bool) {
            let next = GridColumns.step(columns, zoomIn: zoomIn)
            if next != columns { callbacks?.columnsChanged(next) }
        }

        func menu(for indexPath: IndexPath) -> NSMenu? {
            guard let id = dataSource.itemIdentifier(for: indexPath), let callbacks else { return nil }
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

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            callbacks?.selectionChanged(currentSelection())
        }

        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            callbacks?.selectionChanged(currentSelection())
        }

        func collectionView(_ collectionView: NSCollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
            let pixels = tilePixels
            let requests = indexPaths.compactMap { dataSource.itemIdentifier(for: $0) }.compactMap { items[$0] }
                .map { services.previewRequest(for: $0, pixels: pixels) }
            Task { await services.images.prefetch(requests) }
        }
    }

    /// Adds Return to open, ⌘+/⌘− to zoom, and per-item context menus.
    final class GridCollectionView: NSCollectionView {
        weak var owner: PhotoGridScrollView?

        override func keyDown(with event: NSEvent) {
            switch event.charactersIgnoringModifiers {
            case "\r": owner?.openSelection()
            case " ": owner?.openSelection()
            case "+",
                "=" where event.modifierFlags.contains(.command):
                owner?.zoom(in: true)
            case "-" where event.modifierFlags.contains(.command): owner?.zoom(in: false)
            default: super.keyDown(with: event)
            }
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            let point = convert(event.locationInWindow, from: nil)
            guard let indexPath = indexPathForItem(at: point) else { return nil }
            return owner?.menu(for: indexPath)
        }
    }

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

    final class PhotoItem: NSCollectionViewItem {
        static let identifier = NSUserInterfaceItemIdentifier("PhotoItem")
        private let photoView = NSImageView()
        private let durationLabel = NSTextField(labelWithString: "")
        private let favoriteIcon = NSImageView(image: NSImage(systemSymbolName: "heart.fill", accessibilityDescription: nil)!)
        private let liveIcon = NSImageView(image: NSImage(systemSymbolName: "livephoto", accessibilityDescription: nil)!)
        private let selectionRing = NSView()
        private(set) var fileId: FileID?
        private var task: Task<Void, Never>?

        override func loadView() {
            let container = NSView()
            container.wantsLayer = true
            container.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            container.layer?.masksToBounds = true
            photoView.imageScaling = .scaleAxesIndependently
            photoView.wantsLayer = true
            photoView.layer?.contentsGravity = .resizeAspectFill
            durationLabel.font = .systemFont(ofSize: 11, weight: .semibold)
            durationLabel.textColor = .white
            durationLabel.shadow = {
                let s = NSShadow(); s.shadowBlurRadius = 2; s.shadowColor = .black; return s
            }()
            for icon in [favoriteIcon, liveIcon] { icon.contentTintColor = .white }
            selectionRing.wantsLayer = true
            selectionRing.layer?.borderColor = NSColor.controlAccentColor.cgColor
            selectionRing.layer?.borderWidth = 3
            selectionRing.isHidden = true
            [photoView, durationLabel, favoriteIcon, liveIcon, selectionRing].forEach { container.addSubview($0) }
            view = container
        }

        override func viewDidLayout() {
            super.viewDidLayout()
            let bounds = view.bounds
            photoView.frame = bounds
            selectionRing.frame = bounds
            durationLabel.sizeToFit()
            durationLabel.frame.origin = CGPoint(x: bounds.width - durationLabel.frame.width - 4, y: 3)
            favoriteIcon.frame = CGRect(x: 4, y: 4, width: 13, height: 12)
            liveIcon.frame = CGRect(x: 4, y: bounds.height - 20, width: 16, height: 16)
        }

        override var isSelected: Bool {
            didSet {
                selectionRing.isHidden = !isSelected
                photoView.alphaValue = isSelected ? 0.8 : 1
            }
        }

        func configure(item: GridMedia, services: AccountServices, pixels: Double) {
            task?.cancel()
            fileId = item.fileId
            let request = services.previewRequest(for: item, pixels: pixels)
            if let image = services.images.cache.bestMemoryImage(fileId: item.fileId, etag: item.etag, upTo: request.bucket)
                ?? BlurHashCache.image(item.blurhash)
            {
                setImage(image)
            } else {
                photoView.layer?.contents = nil
            }
            updateBadges(item)
            task = Task { [weak self] in
                guard let image = await services.images.preview(request), !Task.isCancelled, self?.fileId == item.fileId else { return }
                self?.setImage(image)
            }
        }

        func setImage(_ image: CGImage) {
            photoView.image = nil
            photoView.layer?.contents = image
        }

        func updateBadges(_ item: GridMedia) {
            durationLabel.stringValue = item.kind == .video ? item.duration.map(Formatters.duration) ?? "▶︎" : ""
            durationLabel.isHidden = item.kind != .video
            favoriteIcon.isHidden = !item.isFavorite
            liveIcon.isHidden = !item.isLivePhoto
            view.setAccessibilityLabel(
                "\(item.kind == .video ? String(localized: "Video", bundle: .module) : String(localized: "Photo", bundle: .module)), \(item.timestamp.formatted(date: .long, time: .shortened))"
            )
            view.needsLayout = true
        }

        override func prepareForReuse() {
            super.prepareForReuse()
            task?.cancel()
            fileId = nil
            photoView.layer?.contents = nil
        }
    }

    final class SectionHeaderView: NSVisualEffectView, NSCollectionViewElement {
        static let identifier = NSUserInterfaceItemIdentifier("SectionHeader")
        private let monthLabel = NSTextField(labelWithString: "")
        private let dayLabel = NSTextField(labelWithString: "")

        override init(frame: NSRect) {
            super.init(frame: frame)
            material = .headerView
            blendingMode = .withinWindow
            monthLabel.font = .systemFont(ofSize: 20, weight: .bold)
            dayLabel.font = .systemFont(ofSize: 12, weight: .semibold)
            dayLabel.textColor = .secondaryLabelColor
            let stack = NSStackView(views: [monthLabel, dayLabel])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 2
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            ])
        }

        required init?(coder: NSCoder) { fatalError() }

        func configure(title: String, monthTitle: String?) {
            monthLabel.stringValue = monthTitle ?? ""
            monthLabel.isHidden = monthTitle == nil
            dayLabel.stringValue = title
            dayLabel.isHidden = title.isEmpty
        }
    }
#endif
