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

    extension PhotoGridScrollView {
        // MARK: Data source

        func numberOfSections(in collectionView: NSCollectionView) -> Int { model.sections.count }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            model.numberOfItems(inSection: section)
        }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let tile = collectionView.makeItem(withIdentifier: PhotoItem.identifier, for: indexPath) as! PhotoItem
            if let item = model.item(section: indexPath.section, item: indexPath.item) {
                tile.configure(item: item, owner: self, tileSide: geometry.side, scale: backingScale)
            } else {
                // A photo the first sync has not loaded yet.
                tile.showPlaceholder()
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
            configure(view, section: indexPath.section)
            return view
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

        /// Placeholder tiles of the first sync's skeleton cannot be selected.
        func collectionView(_ collectionView: NSCollectionView, shouldSelectItemsAt indexPaths: Set<IndexPath>) -> Set<IndexPath> {
            indexPaths.filter { fileId(at: $0) != nil }
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            selected.insert(indexPaths.lazy.compactMap { self.fileId(at: $0) })
            callbacks?.selectionChanged(currentSelection())
        }

        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            selected.remove(indexPaths.lazy.compactMap { self.fileId(at: $0) })
            callbacks?.selectionChanged(currentSelection())
        }

        func collectionView(_ collectionView: NSCollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
            let requests = previewRequests(at: indexPaths)
            Task { await services.images.prefetch(requests) }
        }

        /// The items left the prefetch window (the scroll turned round): their previews are not loaded unless shown.
        func collectionView(_ collectionView: NSCollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
            let requests = previewRequests(at: indexPaths)
            Task { await services.images.cancelPrefetch(for: requests) }
        }

        private func previewRequests(at indexPaths: [IndexPath]) -> [ImagePipeline.Request] {
            core.previewRequests(at: indexPaths, width: gridWidth, scale: backingScale)
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
#endif
