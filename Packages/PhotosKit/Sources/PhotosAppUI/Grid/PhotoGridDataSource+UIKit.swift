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
#endif
