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
        // MARK: Scroll position

        var topInset: CGFloat { collectionView.adjustedContentInset.top }

        /// The first item below the pinned header, unless the grid is scrolled to the top (then it stays there).
        /// Taken from the layout, not from the cells on screen, which lag behind right after a relayout.
        func anchorItem() -> FileID? {
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

        func restore(_ anchor: FileID?) {
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

        // MARK: Date scrubber

        /// The scrubber runs along the part of the grid that is not under the bars, inside the safe area.
        func layoutScrubber() {
            guard isViewLoaded else { return }
            let insets = collectionView.adjustedContentInset
            let width = min(GridScrubberView.width, view.bounds.width)
            let frame = CGRect(
                x: view.bounds.maxX - view.safeAreaInsets.right - width, y: insets.top, width: width,
                height: max(view.bounds.height - insets.top - insets.bottom, 0))
            let resized = frame.size != scrubber.frame.size
            scrubber.frame = frame
            if resized { reloadScrubber() }
        }

        /// Height of the part of the grid between the bars.
        private var visibleHeight: Double {
            let insets = collectionView.adjustedContentInset
            return Double(collectionView.bounds.height - insets.top - insets.bottom)
        }

        /// How far the grid scrolls, as document offsets of its top edge.
        private var scrollRange: Double { max((sectionOffsets.last ?? 0) - visibleHeight, 0) }

        func reloadScrubber() {
            guard isViewLoaded else { return }
            defer {
                pillSection = nil
                updateDatePill(animated: false)
            }
            let visibleHeight = visibleHeight
            guard headersShown, visibleHeight > 0 else {
                setScrubberShown(false)
                return
            }
            let sections = model.sections
            // Placeholder tiles (the first sync's skeleton) count: the scrubber covers the whole library.
            // The header above the first section (memories) comes first in the document.
            let headerOffset = Double(gridHeaderHeight)
            sectionOffsets = geometry.sectionOffsets(
                itemCounts: sections.map(\.tileCount), headerHeights: sections.map { headerMetrics.height(for: $0) }
            ).map { $0 + headerOffset }
            let range = scrollRange
            // Not worth it for a library that fits on two screens.
            guard range > visibleHeight else {
                setScrubberShown(false)
                return
            }
            setScrubberShown(true)
            scrubber.ticks = model.yearStarts.map { entry in
                GridScrubberView.Tick(fraction: min(sectionOffsets[entry.section] / range, 1), label: String(entry.year))
            }
            updateScrubberPosition(userInitiated: false)
        }

        /// One indicator at the edge: the scrubber's handle where it is shown, else the scroll view's own.
        private func setScrubberShown(_ shown: Bool) {
            scrubber.isHidden = !shown
            collectionView.showsVerticalScrollIndicator = !shown
        }

        private func section(atFraction fraction: Double) -> GridSection? {
            // The section under the pinned header, i.e. the one whose items are at the top.
            guard let index = GridGeometry.section(at: fraction * scrollRange + 1, in: sectionOffsets) else { return nil }
            return model.sections[safe: index]
        }

        func scrubberLabel(at fraction: Double) -> String {
            section(atFraction: fraction).map(GridHeaderTexts.scrubberLabel) ?? ""
        }

        private var scrollFraction: Double {
            let range = scrollRange
            return range > 0 ? min(max(Double(collectionView.contentOffset.y + topInset) / range, 0), 1) : 0
        }

        func scroll(toFraction fraction: Double) {
            scroll(toDocumentY: fraction * scrollRange)
        }

        private func scroll(toDocumentY y: Double) {
            let offset = GridAnchor.offset(
                documentY: y, topInset: Double(topInset), contentHeight: sectionOffsets.last ?? 0,
                bottomInset: Double(collectionView.adjustedContentInset.bottom), viewportHeight: Double(collectionView.bounds.height))
            collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: CGFloat(offset)), animated: false)
        }

        /// Jumps to the start of the next older (+1) or newer (−1) year.
        func scrollToYear(delta: Int) {
            let years = model.yearStarts
            guard !years.isEmpty, let current = section(atFraction: scrollFraction)?.year,
                let index = years.firstIndex(where: { $0.year == current })
            else { return }
            let target = years[max(0, min(years.count - 1, index + delta))]
            guard target.section < sectionOffsets.count else { return }
            scroll(toDocumentY: sectionOffsets[target.section])
            updateScrubberPosition(userInitiated: false)
            UIAccessibility.post(notification: .pageScrolled, argument: scrubberLabel(at: scrollFraction))
        }

        private func updateScrubberPosition(userInitiated: Bool) {
            guard !scrubber.isHidden else { return }
            let fraction = scrollFraction
            scrubber.scrolled(to: fraction, label: scrubberLabel(at: fraction), userInitiated: userInitiated)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            #if os(iOS)
                heroHost.layout(collectionView)
            #endif
            // Only the user's scrolling shows the scrubber, not a jump to a photo or a relayout.
            updateScrubberPosition(userInitiated: scrollView.isTracking || scrollView.isDecelerating)
            updateDatePill(animated: true)
            // A peek belongs to the tile under the pointer; the grid moved away under it.
            if peek?.isPeeking == true, scrollView.isTracking || scrollView.isDecelerating { peek?.end() }
        }

        func scrollViewDidChangeAdjustedContentInset(_ scrollView: UIScrollView) {
            layoutScrubber()
            reloadScrubber()
            layoutDatePill()
        }

        // MARK: Date pill (SPEC §17.2)

        /// The pill sits under the bars at the leading edge, clear of the date scrubber.
        func layoutDatePill() {
            guard isViewLoaded else { return }
            let inset: CGFloat = 16
            // Clear of the scrubber's handle at the trailing edge (its view is wider: it holds the date bubble too).
            let maxWidth = max(view.bounds.width - view.safeAreaInsets.left - view.safeAreaInsets.right - 2 * inset - 56, 80)
            let size = datePill.fittingSize(maxWidth: maxWidth)
            let rightToLeft = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
            let x = rightToLeft ? view.bounds.maxX - view.safeAreaInsets.right - inset - size.width : view.safeAreaInsets.left + inset
            let frame = CGRect(x: x, y: barInset + 8, width: size.width, height: size.height)
            guard frame != datePill.frame else { return }
            // Bounds and centre, not the frame: the pill may be scaled while it fades in.
            datePill.bounds = CGRect(origin: .zero, size: frame.size)
            datePill.center = CGPoint(x: frame.midX, y: frame.midY)
        }

        /// The bars' part of the top inset: a hero header (SPEC §17.4) adds its height to the content inset, but the pill
        /// stays under the bars and names what is just below them.
        private var barInset: CGFloat { collectionView.adjustedContentInset.top - collectionView.contentInset.top }

        /// The section under the pill names it; the text changes only when the month or the moment does. Cheap per frame:
        /// a binary search over the section offsets, text only when the section changes.
        func updateDatePill(animated: Bool) {
            guard isViewLoaded, headersShown, sectionOffsets.count > 1 else {
                pillSection = nil
                datePill.show(nil, handover: .none)
                datePill.setShown(false, animated: animated)
                return
            }
            let top = Double(collectionView.contentOffset.y + barInset)
            let probe = top + 8 + Double(datePill.bounds.height)
            if let index = GridGeometry.section(at: max(probe, 0), in: sectionOffsets), index != pillSection {
                let handover = GridDatePill.handover(from: pillSection, to: index)
                pillSection = index
                let pill = GridDatePill.make(sections: model.sections, index: index, moments: core.headerTexts.moments)
                if datePill.show(pill, handover: handover) { layoutDatePill() }
            }
            datePill.setShown(top > Double(gridHeaderHeight) + GridDatePill.revealOffset && datePill.pill != nil, animated: animated)
        }

        // MARK: Year ticks (SPEC §15.5)

        func contentOffsetChanged() {
            #if os(iOS)
                // While the date scrubber is dragged it ticks per year itself.
                guard headersShown, core.pendingAnchor == nil, view.window != nil, !scrubber.isScrubbing else { return }
                let top = collectionView.contentOffset.y + topInset
                let probe = CGPoint(x: min(8, collectionView.bounds.width / 2), y: top + CGFloat(headerMetrics.titleHeight) + 24)
                let year = collectionView.indexPathForItem(at: probe).flatMap { model.sections[safe: $0.section]?.year }
                let now = ProcessInfo.processInfo.systemUptime
                let tick = yearTicker.update(
                    year: year, offset: Double(collectionView.contentOffset.y), time: now,
                    isUserScrolling: collectionView.isTracking || collectionView.isDecelerating,
                    isScrubbing: false)
                guard tick else { return }
                if tickFeedback == nil { tickFeedback = UISelectionFeedbackGenerator(view: view) }
                tickFeedback?.selectionChanged()
            #endif
        }
    }
#endif
