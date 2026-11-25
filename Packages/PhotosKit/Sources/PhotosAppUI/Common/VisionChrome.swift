// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import SwiftUI

// MARK: - Vision Pro chrome (SPEC §17.7)

// On Vision Pro controls belong beside the window as glass ornaments, not over the photo; what stays in the window floats
// a little in front of it. Elsewhere these helpers change nothing.

/// How far the viewer's own controls float in front of the photo on Vision Pro, in points.
enum VisionDepth {
    static let viewerChrome: CGFloat = 24
}

extension View {
    /// Vision Pro: the viewer's controls in the window (previous/next, the copies of a stack) float in front of the photo,
    /// so the eyes and hands find them on their own layer. Nothing elsewhere.
    func viewerChromeDepth() -> some View {
        #if os(visionOS)
            offset(z: VisionDepth.viewerChrome)
        #else
            self
        #endif
    }

    /// The slideshow's playback controls: over the photo at the bottom of the screen on iPhone, iPad and Mac; a glass
    /// ornament under the window on Vision Pro, where nothing covers the photo.
    func slideshowControls<Controls: View>(isShown: Bool, @ViewBuilder _ controls: () -> Controls) -> some View {
        #if os(visionOS)
            ornament(visibility: isShown ? .visible : .hidden, attachmentAnchor: .scene(.bottom), contentAlignment: .top) {
                controls()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassBackgroundEffect(in: .capsule)
            }
        #else
            overlay(alignment: .bottom) {
                if isShown { controls() }
            }
        #endif
    }
}

extension GridTile {
    /// Corner radius of a grid tile's hover lift on Vision Pro: lifted, the tile becomes a small rounded card, as the
    /// system's own grids do.
    static let visionHoverCornerRadius: CGFloat = 6
}
