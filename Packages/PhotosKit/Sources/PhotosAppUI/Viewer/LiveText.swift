// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import SwiftUI

// Swift 5 module without concurrency annotations: `ImageAnalysis` is not marked Sendable. It is made by the analyzer and
// then only used on the main actor.
@preconcurrency import VisionKit

/// When the photo shown is analysed for Live Text and Visual Look Up (SPEC VW-4).
///
/// Only the photo on screen, once its preview is there; not while the app is locked or its window is in the background
/// (the privacy cover is up, the app switcher shows it). Paging away cancels the analysis and takes its result away.
enum LiveTextPolicy {
    static func analyzes(isCurrent: Bool, hasImage: Bool, sceneIsActive: Bool, requiresUnlock: Bool) -> Bool {
        isCurrent && hasImage && sceneIsActive && !requiresUnlock
    }

    /// Paging quickly through photos does not analyse each one on the way.
    static let delay: Duration = .milliseconds(350)

    /// How far the Live Text button stays inside the part of the photo that is on screen: the photo can reach under the
    /// bars (iPhone) or out of the page. In the photo's own coordinates, all zero when it is wholly visible.
    static func buttonInsets(photo: CGRect, visible: CGRect) -> (top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) {
        guard photo.intersects(visible) else { return (0, 0, 0, 0) }
        return (
            max(0, visible.minY - photo.minY), max(0, visible.minX - photo.minX), max(0, photo.maxY - visible.maxY),
            max(0, photo.maxX - visible.maxX)
        )
    }
}

/// Runs the analysis of the photo a zoom view shows and hands the result to the platform's Live Text view: the
/// interaction on the image view (iPhone, iPad, Vision Pro) or the overlay above the photo (Mac).
@MainActor
final class LiveTextAnalysis {
    /// One analyser for the app, as Apple recommends; it is thread-safe.
    private static let analyzer = ImageAnalyzer()

    private var task: Task<Void, Never>?
    private var analysed: CGImage?
    /// Takes the result; nil takes the last one away.
    var apply: (ImageAnalysis?) -> Void = { _ in }

    /// The photo the view shows now, and whether it may be analysed (`LiveTextPolicy`).
    func update(image: CGImage?, enabled: Bool) {
        guard enabled, let image, ImageAnalyzer.isSupported else {
            stop()
            return
        }
        // The same picture (an update of the page that changed something else): its analysis stands. A sharper preview
        // of the same photo is analysed again; until then the earlier result stays.
        guard image !== analysed else { return }
        analysed = image
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(for: LiveTextPolicy.delay)
            guard !Task.isCancelled else { return }
            let configuration = ImageAnalyzer.Configuration([.text, .machineReadableCode, .visualLookUp])
            let analysis: ImageAnalysis? = try? await Self.analyzer.analyze(image, orientation: .up, configuration: configuration)
            guard !Task.isCancelled, let self, let analysis else { return }
            self.apply(analysis)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        if analysed != nil {
            analysed = nil
            apply(nil)
        }
    }

    // deinit is nonisolated; the task holds `self` weakly and ends by itself.
}

#if canImport(UIKit)
    import UIKit

    /// Live Text, data detectors, Visual Look Up and lifting the subject on the photo's image view.
    @MainActor
    final class LiveTextInteraction {
        private let interaction = ImageAnalysisInteraction()
        private let analysis = LiveTextAnalysis()
        private weak var view: UIView?

        init(on view: UIView) {
            self.view = view
            view.isUserInteractionEnabled = true
            interaction.preferredInteractionTypes = .automatic
            view.addInteraction(interaction)
            analysis.apply = { [weak self] result in
                guard let self else { return }
                self.interaction.analysis = result
                self.interaction.preferredInteractionTypes = result == nil ? [] : .automatic
            }
        }

        func update(image: CGImage?, enabled: Bool) {
            analysis.update(image: image, enabled: enabled)
        }

        /// A tap or press at `point` (in the image view) belongs to Live Text: text, a link, a code or the Live Text button
        /// is there, or text is selected (the tap ends the selection). The viewer then leaves it alone.
        func claims(_ point: CGPoint) -> Bool {
            guard interaction.analysis != nil else { return false }
            return interaction.hasActiveTextSelection || interaction.hasInteractiveItem(at: point)
                || interaction.hasSupplementaryInterface(at: point)
        }

        /// The Live Text button stays inside the visible part of the photo and is hidden while it is zoomed in (it would be
        /// scaled with the photo).
        func layout(visible: CGRect, zoomed: Bool) {
            guard let view else { return }
            interaction.isSupplementaryInterfaceHidden = zoomed
            guard !zoomed else { return }
            let insets = LiveTextPolicy.buttonInsets(photo: view.bounds, visible: view.convert(visible, from: view.superview))
            interaction.supplementaryInterfaceContentInsets = UIEdgeInsets(
                top: insets.top, left: insets.left, bottom: insets.bottom, right: insets.right)
        }
    }
#elseif canImport(AppKit)
    import AppKit

    /// Live Text, data detectors, Visual Look Up and lifting the subject over the photo (Mac).
    @MainActor
    final class LiveTextOverlay: NSObject, ImageAnalysisOverlayViewDelegate {
        private let overlay = ImageAnalysisOverlayView()
        private let analysis = LiveTextAnalysis()

        /// - Parameter photo: the view that draws the photo and has its shape; the overlay covers it and is zoomed with it.
        init(over photo: NSView) {
            super.init()
            overlay.delegate = self
            overlay.preferredInteractionTypes = .automatic
            overlay.frame = photo.bounds
            overlay.autoresizingMask = [.width, .height]
            photo.addSubview(overlay)
            analysis.apply = { [weak self] result in
                guard let self else { return }
                self.overlay.analysis = result
                self.overlay.preferredInteractionTypes = result == nil ? [] : .automatic
            }
        }

        func update(image: CGImage?, enabled: Bool) {
            analysis.update(image: image, enabled: enabled)
        }

        /// A drag or click at `point` (in the photo view's coordinates) belongs to Live Text.
        func claims(_ point: CGPoint) -> Bool {
            guard overlay.analysis != nil else { return false }
            return overlay.hasActiveTextSelection || overlay.hasInteractiveItem(at: overlay.convert(point, from: overlay.superview))
        }

        /// The Live Text button is hidden while the photo is zoomed in (it would be scaled with the photo).
        func setZoomed(_ zoomed: Bool) {
            if overlay.isSupplementaryInterfaceHidden != zoomed { overlay.isSupplementaryInterfaceHidden = zoomed }
        }

        /// The photo fills the overlay exactly.
        func contentsRect(for overlayView: ImageAnalysisOverlayView) -> CGRect {
            CGRect(x: 0, y: 0, width: 1, height: 1)
        }
    }
#endif
