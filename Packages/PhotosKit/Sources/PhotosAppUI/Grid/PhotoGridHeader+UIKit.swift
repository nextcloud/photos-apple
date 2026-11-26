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
        func collectionView(
            _ collectionView: UICollectionView, willDisplaySupplementaryView view: UICollectionReusableView,
            forElementKind elementKind: String, at indexPath: IndexPath
        ) {
            if elementKind == Self.gridHeaderKind { headerVisibility.isVisible = true }
        }

        func collectionView(
            _ collectionView: UICollectionView, didEndDisplayingSupplementaryView view: UICollectionReusableView,
            forElementOfKind elementKind: String, at indexPath: IndexPath
        ) {
            if elementKind == Self.gridHeaderKind { headerVisibility.isVisible = false }
        }

        func setHeader(_ header: AnyView?) {
            if let header {
                let header = AnyView(header.environment(headerVisibility))
                if let host = headerHost {
                    host.rootView = header
                } else {
                    let host = UIHostingController(rootView: header)
                    host.sizingOptions = [.intrinsicContentSize]
                    host.safeAreaRegions = []
                    host.view.backgroundColor = .clear
                    addChild(host)
                    host.didMove(toParent: self)
                    headerHost = host
                }
            } else if let host = headerHost {
                host.willMove(toParent: nil)
                host.view.removeFromSuperview()
                host.removeFromParent()
                headerHost = nil
            }
            updateGridHeaderHeight()
        }

        /// The header's height at the grid's width; a new height lays the grid out again with the photos kept in place.
        func updateGridHeaderHeight() {
            guard isViewLoaded else { return }
            let width = collectionView.bounds.width > 0 ? collectionView.bounds.width : view.bounds.width
            var height: CGFloat = 0
            if let host = headerHost, width > 0 {
                height = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height.rounded(.up)
            }
            guard abs(height - gridHeaderHeight) > 0.5,
                let layout = collectionView.collectionViewLayout as? UICollectionViewCompositionalLayout
            else { return }
            let wasAtTop = collectionView.contentOffset.y <= -topInset + 1
            let anchor = anchorItem()
            gridHeaderHeight = height
            let configuration = UICollectionViewCompositionalLayoutConfiguration()
            if height > 0 {
                configuration.boundarySupplementaryItems = [
                    NSCollectionLayoutBoundarySupplementaryItem(
                        layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(height)),
                        elementKind: Self.gridHeaderKind, alignment: .top)
                ]
            }
            layout.configuration = configuration
            if wasAtTop {
                // At the top it stays at the top: the header comes or goes above what is shown (the collection view would
                // keep the first tile where it was instead).
                collectionView.layoutIfNeeded()
                collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: -topInset), animated: false)
            } else {
                restore(anchor)
            }
            reloadScrubber()
        }
    }
#endif
