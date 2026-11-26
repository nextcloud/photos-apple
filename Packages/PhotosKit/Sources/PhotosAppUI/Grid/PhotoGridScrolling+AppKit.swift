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
        // MARK: Scroll position

        var topInset: CGFloat { contentInsets.top }

        private var isAtTop: Bool { contentView.bounds.minY <= -topInset + 1 }

        /// The first item below the pinned header, unless the grid is scrolled to the top (then it stays there).
        /// Taken from the layout, not from the views on screen, which lag behind right after a relayout.
        func anchorItem() -> FileID? {
            let top = contentView.bounds.minY + topInset
            return core.anchorItem(isAtTop: isAtTop, top: Double(top)) { [self] in
                guard let layout = collectionView.collectionViewLayout else { return [] }
                let strip = NSRect(x: 0, y: top, width: collectionView.bounds.width, height: CGFloat(geometry.side) + 80)
                return layout.layoutAttributesForElements(in: strip).compactMap { attributes in
                    guard attributes.representedElementCategory == .item, let indexPath = attributes.indexPath else { return nil }
                    return GridAnchor.Candidate(section: indexPath.section, item: indexPath.item, maxY: Double(attributes.frame.maxY))
                }
            }
        }

        func restore(_ anchor: FileID?) {
            core.restore(anchor) { [weak self] anchor in self?.restoreNow(anchor) }
        }

        private func restoreNow(_ anchor: FileID) {
            guard let indexPath = core.indexPath(for: anchor) else { return }
            collectionView.needsLayout = true
            collectionView.layoutSubtreeIfNeeded()
            // Scrolling is limited by the document's frame, which can still be the one of the old layout.
            if let height = collectionView.collectionViewLayout?.collectionViewContentSize.height, collectionView.frame.height < height {
                collectionView.setFrameSize(NSSize(width: collectionView.frame.width, height: height))
            }
            guard let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame else { return }
            scroll(toDocumentY: frame.minY - CGFloat(headerHeight(section: indexPath.section)))
        }

        /// The tile's frame in this view, top-left origin as SwiftUI measures it; nil when it is not on screen.
        func tileFrame(_ id: FileID) -> CGRect? {
            guard let indexPath = core.indexPath(for: id), let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame,
                contentView.documentVisibleRect.intersects(frame)
            else { return nil }
            let local = convert(frame, from: collectionView)
            return isFlipped ? local : CGRect(x: local.minX, y: bounds.height - local.maxY, width: local.width, height: local.height)
        }

        /// Scrolls so that the tile's top is at `fraction` of the visible height (a zoom from the days).
        func place(_ id: FileID, fraction: Double) {
            place(id, offset: topInset + CGFloat(fraction) * max(contentView.bounds.height - topInset, 0))
        }

        /// Scrolls so that the tile's middle is `offset` below the top of the clip view, now and after the layout pass.
        func place(_ id: FileID, offset: CGFloat) {
            core.restore(id) { [weak self] id in
                guard let self, let indexPath = self.core.indexPath(for: id) else { return }
                self.collectionView.needsLayout = true
                self.collectionView.layoutSubtreeIfNeeded()
                if let height = self.collectionView.collectionViewLayout?.collectionViewContentSize.height,
                    self.collectionView.frame.height < height
                {
                    self.collectionView.setFrameSize(NSSize(width: self.collectionView.frame.width, height: height))
                }
                guard let frame = self.collectionView.layoutAttributesForItem(at: indexPath)?.frame else { return }
                self.scroll(toDocumentY: frame.midY - offset + self.topInset)
            }
        }

        /// Scrolls the tile into the middle of the visible area if it is not wholly visible.
        func reveal(_ id: FileID) {
            guard let indexPath = core.indexPath(for: id) else { return }
            collectionView.layoutSubtreeIfNeeded()
            if let height = collectionView.collectionViewLayout?.collectionViewContentSize.height, collectionView.frame.height < height {
                collectionView.setFrameSize(NSSize(width: collectionView.frame.width, height: height))
            }
            guard let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame else { return }
            var visible: NSRect = contentView.bounds
            visible.origin.y += topInset
            visible.size.height -= topInset
            guard !visible.contains(frame) else { return }
            scroll(toDocumentY: frame.midY - visible.height / 2)
        }

        /// Scrolls so that the document offset `y` is at the top of the visible area (below the toolbar).
        private func scroll(toDocumentY y: CGFloat) {
            let offset = GridAnchor.offset(
                documentY: Double(y), topInset: Double(topInset), contentHeight: Double(collectionView.frame.height),
                viewportHeight: Double(contentView.bounds.height))
            contentView.scroll(to: NSPoint(x: contentView.bounds.minX, y: CGFloat(offset)))
            reflectScrolledClipView(contentView)
        }

        private var scrollRange: Double {
            Double(collectionView.frame.height - contentView.bounds.height + topInset)
        }

        func reloadScrubber() {
            let visibleHeight = Double(contentView.bounds.height - topInset)
            guard headersShown, visibleHeight > 0 else {
                scrubber.isHidden = true
                return
            }
            let sections = model.sections
            // Placeholder tiles (the first sync's skeleton) count: the scrubber covers the whole library.
            sectionOffsets = geometry.sectionOffsets(
                itemCounts: sections.map(\.tileCount), headerHeights: sections.map { headerMetrics.height(for: $0) })
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

        func scrubberLabel(at fraction: Double) -> String {
            section(atFraction: fraction).map(GridHeaderTexts.scrubberLabel) ?? ""
        }

        private var scrollFraction: Double {
            let range = scrollRange
            return range > 0 ? min(max(Double(contentView.bounds.minY + topInset) / range, 0), 1) : 0
        }

        func scroll(toFraction fraction: Double) {
            scroll(toDocumentY: CGFloat(fraction * scrollRange))
        }

        /// Jumps to the start of the next older (+1) or newer (−1) year.
        func scrollToYear(delta: Int) {
            let years = model.yearStarts
            guard !years.isEmpty, let current = section(atFraction: scrollFraction)?.year,
                let index = years.firstIndex(where: { $0.year == current })
            else { return }
            let target = years[max(0, min(years.count - 1, index + delta))]
            guard target.section < sectionOffsets.count else { return }
            scroll(toDocumentY: CGFloat(sectionOffsets[target.section]))
        }

        @objc func didScroll(_ notification: Notification) {
            // A peek belongs to the tile under the pointer; the grid moved away under it.
            if peek?.isPeeking == true { peek?.end() }
            hoverLift?.drop()
            guard !scrubber.isHidden else { return }
            let fraction = scrollFraction
            scrubber.scrolled(to: fraction, label: scrubberLabel(at: fraction))
        }
    }
#endif
