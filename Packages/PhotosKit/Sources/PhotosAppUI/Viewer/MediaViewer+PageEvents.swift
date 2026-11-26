// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosStore
import SwiftUI

extension MediaViewer {
    // MARK: Page events

    var pageEvents: ViewerPage.Events {
        ViewerPage.Events(
            tapped: { pageTapped() },
            scaleChanged: { scale in zoomScale = scale },
            verticalDrag: { phase in handleSwipe(phase) })
    }

    /// A tap on a photo hides or shows the bars (iPhone, iPad); on the Mac it gives the viewer the keyboard.
    func pageTapped() {
        focused = true
        #if os(iOS)
            withAnimation(reduceMotion ? nil : .default) { chromeHidden.toggle() }
        #endif
    }

    /// Swipe down closes the viewer, swipe up shows the info panel (SPEC VW-1, §7.4). Dragged down, the photo follows
    /// the finger and shrinks while the grid comes back behind it; let go, it lands in its tile or springs back
    /// (SPEC §17.1). With the info card open, a swipe down closes the card.
    func handleSwipe(_ phase: ViewerSwipe.Phase) {
        switch phase {
        case .changed(let translation):
            guard !showingInfo, translation.height > 0 || dismissPose != .rest else { return }
            if dismissPose == .rest { viewerExit?.setTileHidden(landingTile != nil) }
            dismissPose = ViewerDismissal.dragPose(
                translation: CGSize(width: translation.width, height: max(0, translation.height)), page: pageSize,
                photo: currentPhotoRect)
        case .ended(let translation, let velocity):
            switch ViewerSwipe.outcome(translation: translation.height, velocity: velocity.dy) {
            case .dismiss:
                if showingInfo {
                    toggleInfo()
                } else {
                    land(velocity: velocity)
                }
            case .showInfo:
                settle(velocity: .zero)
                if !showingInfo { toggleInfo() }
            case .none:
                settle(velocity: velocity)
            }
        case .cancelled:
            settle(velocity: .zero)
        }
    }

    /// The tile of the page shown, when the grid behind has it on screen.
    var landingTile: CGRect? {
        guard let current, let tile = viewerExit?.tileFrame(current) else { return nil }
        let screen: CGRect = pageFrame.isEmpty ? CGRect(origin: .zero, size: pageSize) : pageFrame
        return ViewerDismissal.isLandable(tile: tile, screen: screen) ? tile : nil
    }

    /// Lands the photo in its tile with a spring that starts at the finger's speed, then closes at once. Without a tile
    /// on screen the viewer closes the usual way; with Reduce Motion the photo fades out where it is.
    func land(velocity: CGVector) {
        guard let viewerExit, let tile = landingTile else {
            viewerExit?.setTileHidden(false)
            dismiss()
            return
        }
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.2)) {
                exitOpacity = 0
            } completion: {
                viewerExit.closeImmediately()
            }
            return
        }
        let target: ViewerDismissPose = ViewerDismissal.landingPose(
            tile: tile, pageOrigin: pageFrame.origin, page: pageSize, photo: currentPhotoRect)
        let speed: Double = ViewerDismissal.springVelocity(velocity, from: dismissPose.offset, to: target.offset)
        withAnimation(.interpolatingSpring(duration: 0.38, bounce: 0, initialVelocity: speed)) {
            dismissPose = target
        } completion: {
            viewerExit.closeImmediately()
        }
    }

    /// Back to the full stage: a spring from the finger's speed, or at once with Reduce Motion.
    func settle(velocity: CGVector) {
        guard dismissPose != .rest else { return }
        let speed: Double = ViewerDismissal.springVelocity(velocity, from: dismissPose.offset, to: .zero)
        withAnimation(reduceMotion ? nil : .interpolatingSpring(duration: 0.32, bounce: 0, initialVelocity: speed)) {
            dismissPose = .rest
        } completion: {
            if dismissPose == .rest { viewerExit?.setTileHidden(false) }
        }
    }

    func step(_ delta: Int) {
        guard let next = ViewerNavigation.target(in: shownIds, from: current, delta: delta) else { return }
        // Reduce Motion: the next photo replaces the current one instead of sliding in.
        withAnimation(reduceMotion ? nil : .default) { current = next }
    }

    func toggleFavorite(_ item: MediaItem) {
        favoriteToggles += 1
        let undoManager = undoManager
        Task { await session.perform(.favorite([item], value: !item.isFavorite), undoManager: undoManager) }
    }

    /// The files a rating or flag goes to: the photo shown, or every copy of a stacked tile (as in the grid).
    var cullingIds: [FileID] {
        if let current, let members = stacks[current], members.count > 1 { return members.filter { !removed.contains($0) } }
        return currentFileId.map { [$0] } ?? []
    }

    func toggleInfo() {
        withAnimation(reduceMotion ? nil : .default) { showingInfo.toggle() }
    }

    /// What VoiceOver offers on a page: swipe up/down for the next or previous photo, and the main actions in the
    /// actions rotor (share stays a button in the toolbar: a share sheet cannot be opened without one).
    var accessibilityActions: ViewerPage.AccessibilityActions {
        ViewerPage.AccessibilityActions(
            step: { delta in
                step(delta)
                accessibilityPage = current
            },
            toggleFavorite: { if let item = currentItem { toggleFavorite(item) } },
            showInfo: { toggleInfo() },
            delete: { if currentItem?.permissions.canDelete == true { confirmDelete = true } },
            zoom: { kind in zoom(kind) })
    }
}
