// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

#if canImport(UIKit)
    import PhotosCore
    import PhotosMedia
    import PhotosModel
    import PhotosStore
    import SwiftUI
    import UIKit

    /// The photo grid on iOS, iPadOS and visionOS (SPEC §6.4).
    struct PhotoGrid: UIViewControllerRepresentable {
        var sections: [GridSection]
        var items: [FileID: GridMedia]
        var columns: Int
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
            controller.update(
                sections: sections, items: items, columns: columns, selection: selection, isSelecting: isSelecting,
                showsHeaders: showsHeaders)
        }
    }

    final class PhotoGridController: UIViewController, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
        let services: AccountServices
        var callbacks: GridCallbacks?
        private var collectionView: UICollectionView!
        private var dataSource: GridDataSource!
        private var items: [FileID: GridMedia] = [:]
        private var sections: [GridSection] = []
        private var columns = GridColumns.default
        private var showsHeaders = true
        private var isSelecting = false
        private var pinchHandled = false

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
            collectionView.delegate = self
            collectionView.prefetchDataSource = self
            collectionView.allowsSelection = true
            collectionView.allowsMultipleSelectionDuringEditing = true
            collectionView.register(PhotoCell.self, forCellWithReuseIdentifier: PhotoCell.reuseIdentifier)
            collectionView.register(
                SectionHeader.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                withReuseIdentifier: SectionHeader.reuseIdentifier)
            view.addSubview(collectionView)

            dataSource = GridDataSource(collectionView: collectionView) { [weak self] collectionView, indexPath, fileId in
                let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PhotoCell.reuseIdentifier, for: indexPath) as! PhotoCell
                if let self, let item = self.items[fileId] {
                    cell.configure(item: item, services: self.services, pixels: self.tilePixels)
                }
                return cell
            }
            dataSource.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
                let header =
                    collectionView.dequeueReusableSupplementaryView(
                        ofKind: kind, withReuseIdentifier: SectionHeader.reuseIdentifier, for: indexPath)
                    as! SectionHeader
                if let section = self?.sections[safe: indexPath.section] {
                    header.configure(title: section.title, monthTitle: section.monthTitle)
                }
                return header
            }
            dataSource.indexTitlesProvider = { [weak self] in self?.yearIndex() ?? ([], []) }

            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            collectionView.addGestureRecognizer(pinch)
        }

        var tilePixels: Double {
            let width = (view.bounds.width - CGFloat(columns - 1) * Design.tileSpacing) / CGFloat(max(columns, 1))
            return Double(width * min(view.traitCollection.displayScale, 2))
        }

        func update(
            sections: [GridSection], items: [FileID: GridMedia], columns: Int, selection: Set<FileID>, isSelecting: Bool, showsHeaders: Bool
        ) {
            loadViewIfNeeded()
            self.items = items
            let layoutChanged = columns != self.columns || showsHeaders != self.showsHeaders
            self.columns = columns
            self.showsHeaders = showsHeaders
            if layoutChanged { collectionView.setCollectionViewLayout(makeLayout(), animated: true) }
            if sections != self.sections {
                self.sections = sections
                var snapshot = NSDiffableDataSourceSnapshot<Int, FileID>()
                snapshot.appendSections(sections.map(\.id))
                for section in sections { snapshot.appendItems(section.items, toSection: section.id) }
                dataSource.apply(snapshot, animatingDifferences: false)
            } else {
                // Same structure: refresh visible cells for changed badges (favorite etc.).
                for cell in collectionView.visibleCells {
                    if let cell = cell as? PhotoCell, let id = cell.fileId, let item = items[id] { cell.updateBadges(item) }
                }
            }
            if isSelecting != self.isSelecting {
                self.isSelecting = isSelecting
                collectionView.isEditing = isSelecting
                collectionView.allowsMultipleSelection = isSelecting
            }
            syncSelection(selection)
        }

        func syncSelection(_ selection: Set<FileID>) {
            let selected = Set((collectionView.indexPathsForSelectedItems ?? []).compactMap { dataSource.itemIdentifier(for: $0) })
            guard selected != selection else { return }
            for id in selected.subtracting(selection) {
                if let indexPath = dataSource.indexPath(for: id) { collectionView.deselectItem(at: indexPath, animated: false) }
            }
            for id in selection.subtracting(selected) {
                if let indexPath = dataSource.indexPath(for: id) {
                    collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
                }
            }
        }

        func makeLayout() -> UICollectionViewLayout {
            let columns = self.columns
            let spacing = Design.tileSpacing
            let headers = showsHeaders
            return UICollectionViewCompositionalLayout { _, environment in
                let width = environment.container.effectiveContentSize.width
                let side = (width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
                let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .absolute(side), heightDimension: .absolute(side)))
                let group = NSCollectionLayoutGroup.horizontal(
                    layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(side)), repeatingSubitem: item,
                    count: columns)
                group.interItemSpacing = .fixed(spacing)
                let section = NSCollectionLayoutSection(group: group)
                section.interGroupSpacing = spacing
                if headers {
                    let header = NSCollectionLayoutBoundarySupplementaryItem(
                        layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(44)),
                        elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
                    header.pinToVisibleBounds = true
                    section.boundarySupplementaryItems = [header]
                }
                return section
            }
        }

        func yearIndex() -> ([String], [Int]) {
            var titles: [String] = []
            var sectionIndexes: [Int] = []
            for (index, section) in sections.enumerated() {
                guard let year = section.year, titles.last != String(year) else { continue }
                titles.append(String(year))
                sectionIndexes.append(index)
            }
            return titles.count > 1 ? (titles, sectionIndexes) : ([], [])
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .began: pinchHandled = false
            case .changed:
                guard !pinchHandled, gesture.scale > 1.35 || gesture.scale < 0.75 else { return }
                pinchHandled = true
                let next = GridColumns.step(columns, zoomIn: gesture.scale > 1)
                if next != columns { callbacks?.columnsChanged(next) }
            default: break
            }
        }

        // MARK: Delegate

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
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

        func collectionView(_ collectionView: UICollectionView, shouldBeginMultipleSelectionInteractionAt indexPath: IndexPath) -> Bool {
            true
        }

        func collectionView(_ collectionView: UICollectionView, didBeginMultipleSelectionInteractionAt indexPath: IndexPath) {
            if !isSelecting { callbacks?.selectionChanged(currentSelection()) }
        }

        func currentSelection() -> Set<FileID> {
            Set((collectionView.indexPathsForSelectedItems ?? []).compactMap { dataSource.itemIdentifier(for: $0) })
        }

        func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint)
            -> UIContextMenuConfiguration?
        {
            let ids = indexPaths.compactMap { dataSource.itemIdentifier(for: $0) }
            guard !ids.isEmpty, let callbacks else { return nil }
            let actions = callbacks.menu(ids)
            guard !actions.isEmpty else { return nil }
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
                UIMenu(
                    children: actions.map { action in
                        UIAction(
                            title: action.title, image: UIImage(systemName: action.systemImage),
                            attributes: action.isDestructive ? .destructive : []
                        ) { _ in action.handler(ids) }
                    })
            }
        }

        func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
            let pixels = tilePixels
            let requests = indexPaths.compactMap { dataSource.itemIdentifier(for: $0) }.compactMap { items[$0] }
                .map { services.previewRequest(for: $0, pixels: pixels) }
            Task { await services.images.prefetch(requests) }
        }
    }

    /// Diffable data source with a year index (native section index as date scrubber).
    final class GridDataSource: UICollectionViewDiffableDataSource<Int, FileID> {
        var indexTitlesProvider: (() -> ([String], [Int]))?

        override func indexTitles(for collectionView: UICollectionView) -> [String]? {
            let titles = indexTitlesProvider?().0 ?? []
            return titles.isEmpty ? nil : titles
        }

        override func collectionView(_ collectionView: UICollectionView, indexPathForIndexTitle title: String, at index: Int) -> IndexPath {
            let sections = indexTitlesProvider?().1 ?? []
            return IndexPath(item: 0, section: sections[safe: index] ?? 0)
        }
    }

    final class PhotoCell: UICollectionViewCell {
        static let reuseIdentifier = "PhotoCell"
        private let imageView = UIImageView()
        private let durationLabel = UILabel()
        private let favoriteIcon = UIImageView(image: UIImage(systemName: "heart.fill"))
        private let liveIcon = UIImageView(image: UIImage(systemName: "livephoto"))
        private let checkmark = UIImageView()
        private let gradient = CAGradientLayer()
        private(set) var fileId: FileID?
        private var task: Task<Void, Never>?

        override init(frame: CGRect) {
            super.init(frame: frame)
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.backgroundColor = .secondarySystemFill
            contentView.addSubview(imageView)
            gradient.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.45).cgColor]
            contentView.layer.addSublayer(gradient)
            durationLabel.font = .preferredFont(forTextStyle: .caption2).withWeight(.semibold)
            durationLabel.textColor = .white
            for icon in [favoriteIcon, liveIcon] {
                icon.tintColor = .white
                icon.contentMode = .scaleAspectFit
            }
            checkmark.contentMode = .scaleAspectFit
            [durationLabel, favoriteIcon, liveIcon, checkmark].forEach { contentView.addSubview($0) }
            isAccessibilityElement = true
            accessibilityTraits = .image
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layoutSubviews() {
            super.layoutSubviews()
            let bounds = contentView.bounds
            imageView.frame = bounds
            gradient.frame = CGRect(x: 0, y: bounds.height * 0.6, width: bounds.width, height: bounds.height * 0.4)
            durationLabel.sizeToFit()
            durationLabel.frame.origin = CGPoint(
                x: bounds.width - durationLabel.bounds.width - 4, y: bounds.height - durationLabel.bounds.height - 3)
            favoriteIcon.frame = CGRect(x: 4, y: bounds.height - 16, width: 13, height: 12)
            liveIcon.frame = CGRect(x: 4, y: 4, width: 16, height: 16)
            checkmark.frame = CGRect(x: bounds.width - 26, y: bounds.height - 26, width: 22, height: 22)
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
        }

        func configure(item: GridMedia, services: AccountServices, pixels: Double) {
            task?.cancel()
            fileId = item.fileId
            let request = services.previewRequest(for: item, pixels: pixels)
            if let image = services.images.cache.memoryImage(fileId: item.fileId, etag: item.etag, bucket: request.bucket)
                ?? services.images.cache.bestMemoryImage(fileId: item.fileId, etag: item.etag, upTo: request.bucket)
            {
                imageView.image = UIImage(cgImage: image)
            } else {
                imageView.image = BlurHashCache.image(item.blurhash).map { UIImage(cgImage: $0) }
            }
            updateBadges(item)
            updateSelection()
            task = Task { [weak self] in
                guard let image = await services.images.preview(request), !Task.isCancelled, self?.fileId == item.fileId else { return }
                self?.imageView.image = UIImage(cgImage: image)
            }
        }

        func updateBadges(_ item: GridMedia) {
            durationLabel.text = item.kind == .video ? item.duration.map(Formatters.duration) ?? "▶︎" : nil
            durationLabel.isHidden = item.kind != .video
            favoriteIcon.isHidden = !item.isFavorite
            liveIcon.isHidden = !item.isLivePhoto
            gradient.isHidden = item.kind != .video && !item.isFavorite
            accessibilityLabel = [
                item.kind == .video ? String(localized: "Video", bundle: .module) : String(localized: "Photo", bundle: .module),
                item.timestamp.formatted(date: .long, time: .shortened),
                item.isFavorite ? String(localized: "Favorite", bundle: .module) : nil,
            ].compactMap { $0 }.joined(separator: ", ")
            setNeedsLayout()
        }

        override func prepareForReuse() {
            super.prepareForReuse()
            task?.cancel()
            fileId = nil
            imageView.image = nil
        }
    }

    final class SectionHeader: UICollectionReusableView {
        static let reuseIdentifier = "SectionHeader"
        private let monthLabel = UILabel()
        private let dayLabel = UILabel()
        private let stack = UIStackView()
        private let background = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))

        override init(frame: CGRect) {
            super.init(frame: frame)
            addSubview(background)
            monthLabel.font = .preferredFont(forTextStyle: .title2).withWeight(.bold)
            monthLabel.adjustsFontForContentSizeCategory = true
            dayLabel.font = .preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
            dayLabel.textColor = .secondaryLabel
            dayLabel.adjustsFontForContentSizeCategory = true
            stack.axis = .vertical
            stack.spacing = 2
            stack.addArrangedSubview(monthLabel)
            stack.addArrangedSubview(dayLabel)
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
                stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            ])
            monthLabel.accessibilityTraits = .header
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layoutSubviews() {
            super.layoutSubviews()
            background.frame = bounds
        }

        func configure(title: String, monthTitle: String?) {
            monthLabel.text = monthTitle
            monthLabel.isHidden = monthTitle == nil
            dayLabel.text = title
            dayLabel.isHidden = title.isEmpty
        }
    }

    extension UIFont {
        func withWeight(_ weight: UIFont.Weight) -> UIFont {
            UIFont.systemFont(ofSize: pointSize, weight: weight)
        }
    }
#endif

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
