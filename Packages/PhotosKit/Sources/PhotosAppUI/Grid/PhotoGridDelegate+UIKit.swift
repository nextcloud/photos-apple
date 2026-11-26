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

    extension PhotoGridController {
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
#endif
