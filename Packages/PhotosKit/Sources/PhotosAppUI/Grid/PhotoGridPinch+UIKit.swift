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
        // MARK: Pinch (SPEC §15.5)

        /// The tiles follow the fingers (scaled around them); on release the grid settles on the step the pinch was heading
        /// for, with the photo under the fingers kept under them. Out of the densest step the Library's days take over.
        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .began:
                let location = gesture.location(in: collectionView)
                pinch = GridPinch(fileId: fileId(near: location), location: gesture.location(in: view))
            case .changed:
                guard let pinch else { return }
                let stop = LibraryZoomStop.grid(step: zoomStep)
                let pastEnd: Bool = callbacks?.zoomPastEnd != nil || stop != GridPinch.ladder.densestGrid
                let canZoomOut = GridPinch.ladder.canZoomOut(from: stop) && pastEnd
                let scale = LibraryZoomGesture.displayScale(
                    Double(gesture.scale), canZoomIn: GridPinch.ladder.canZoomIn(from: stop), canZoomOut: canZoomOut)
                collectionView.transform = pinch.transform(scale: CGFloat(scale), center: CGPoint(x: view.bounds.midX, y: view.bounds.midY))
            case .ended:
                guard let pinch else { return }
                self.pinch = nil
                let projected = LibraryZoomGesture.projectedScale(scale: Double(gesture.scale), velocity: Double(gesture.velocity))
                let target = GridPinch.ladder.moved(.grid(step: zoomStep), by: LibraryZoomGesture.steps(projectedScale: projected))
                switch target {
                case .grid(let step) where step != zoomStep:
                    snapFeedback(at: pinch.location)
                    pinchAnchor = pinch.fileId.map { ($0, pinch.location.y) }
                    callbacks?.columnsChanged(step)
                    // Should the zoom not arrive (nothing changed after all), the tiles still go back to their size.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                        self?.pinchAnchor = nil
                        self?.settleTransform()
                    }
                case .grid:
                    settleTransform()
                default:
                    if let zoomPastEnd = callbacks?.zoomPastEnd {
                        // The level change plays its own tap (`LibraryZoomOverlay`).
                        let point = UnitPoint(
                            x: Double(pinch.location.x / max(view.bounds.width, 1)),
                            y: Double(pinch.location.y / max(view.bounds.height, 1)))
                        zoomPastEnd(pinch.fileId, point)
                        // Covered by the days by now; back to its size underneath.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                            self?.collectionView.transform = .identity
                        }
                    } else {
                        settleTransform()
                    }
                }
            case .cancelled, .failed:
                pinch = nil
                settleTransform()
            default: break
            }
        }

        /// Springs the tiles back to their size.
        private func settleTransform() {
            guard collectionView.transform != .identity else { return }
            UIView.animate(
                withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0, options: [.allowUserInteraction]
            ) {
                self.collectionView.transform = .identity
            }
        }

        /// The photo under a point of the grid, or the one closest to it (between tiles, under a header).
        private func fileId(near location: CGPoint) -> FileID? {
            if let indexPath = collectionView.indexPathForItem(at: location), let id = fileId(at: indexPath) { return id }
            let visible = collectionView.indexPathsForVisibleItems.compactMap { indexPath -> (FileID, CGFloat)? in
                guard let id = fileId(at: indexPath), let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame else {
                    return nil
                }
                return (id, hypot(frame.midX - location.x, frame.midY - location.y))
            }
            return visible.min { $0.1 < $1.1 }?.0 ?? anchorItem()
        }

        /// A light tap when a pinch snaps to another zoom step or level (iPhone, iPad; the system's haptics setting applies).
        private func snapFeedback(at location: CGPoint) {
            #if os(iOS)
                UIImpactFeedbackGenerator(style: .light, view: view).impactOccurred(at: location)
            #endif
        }

        /// Scrolls so that the tile's top is at `fraction` of the visible height (a zoom from the days).
        func place(_ id: FileID, fraction: Double) {
            guard isViewLoaded else { return }
            let visible = collectionView.bounds.height - topInset - collectionView.adjustedContentInset.bottom
            place(id, viewY: topInset + CGFloat(fraction) * max(visible, 0))
        }

        /// Scrolls so that the tile's middle is at `viewY` in the controller's view, now and after the layout pass.
        func place(_ id: FileID, viewY: CGFloat) {
            core.restore(id) { [weak self] id in
                guard let self, let indexPath = self.indexPath(for: id) else { return }
                self.collectionView.layoutIfNeeded()
                guard let frame = self.collectionView.layoutAttributesForItem(at: indexPath)?.frame else { return }
                let contentHeight = max(
                    self.collectionView.contentSize.height, self.collectionView.collectionViewLayout.collectionViewContentSize.height)
                let inCollection = viewY - self.collectionView.frame.minY
                let offset = GridAnchor.offset(
                    documentY: Double(frame.midY - inCollection + self.topInset), topInset: Double(self.topInset),
                    contentHeight: Double(contentHeight), bottomInset: Double(self.collectionView.adjustedContentInset.bottom),
                    viewportHeight: Double(self.collectionView.bounds.height))
                self.collectionView.setContentOffset(CGPoint(x: self.collectionView.contentOffset.x, y: CGFloat(offset)), animated: false)
            }
        }
    }

    /// A pinch on the grid: the photo under the fingers and where the fingers are in the grid's view.
    @MainActor
    struct GridPinch {
        static let ladder = LibraryZoomLadder(gridSteps: GridColumns.options)

        var fileId: FileID?
        var location: CGPoint

        /// Scales the grid by `scale` around the fingers (the view's transform works around its centre).
        func transform(scale: CGFloat, center: CGPoint) -> CGAffineTransform {
            let dx = location.x - center.x
            let dy = location.y - center.y
            return CGAffineTransform(translationX: dx, y: dy).scaledBy(x: scale, y: scale).translatedBy(x: -dx, y: -dy)
        }
    }
#endif
