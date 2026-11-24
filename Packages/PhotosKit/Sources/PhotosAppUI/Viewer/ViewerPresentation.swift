// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosModel
import SwiftUI

/// The tile the viewer zooms out of and back into (iPhone, iPad; SPEC §7.2). The grid marks the tile as the
/// transition's source (`matchedTransitionSource`) and follows the photo shown, so closing the viewer after paging zooms
/// into the tile of the photo shown last.
struct ViewerZoomSource {
    var namespace: Namespace.ID
    /// The tile shown now: the one tapped, then the one of the photo the viewer shows.
    var tile: FileID
    /// Told the tile of the photo shown whenever the viewer pages.
    var currentChanged: @MainActor (FileID) -> Void
}

extension View {
    /// Shows the viewer for `start` the way the platform does it — the one way every screen opens the viewer.
    ///
    /// iPhone and iPad: a full-screen cover with a navigation stack of its own. The viewer's Close button, title and
    /// bottom bar are toolbar items; without a stack they have nowhere to show up and the viewer is a dead end. With a
    /// `zoom` source it zooms out of the tile and back into it.
    /// Mac and Vision Pro: pushed in the window's stack ("Back" returns to the grid), so this has to be used inside one.
    /// The Mac has no zoom transition for a pushed view; the viewer replaces the grid as before.
    func mediaViewer(_ start: Binding<ViewerStart?>, zoom: ViewerZoomSource? = nil) -> some View {
        modifier(MediaViewerPresenter(start: start, zoom: zoom))
    }
}

private struct MediaViewerPresenter: ViewModifier {
    @Binding var start: ViewerStart?
    var zoom: ViewerZoomSource?
    @Environment(SessionModel.self) private var session
    /// Passed on explicitly: the cover is a presentation of its own.
    @Environment(\.showInFolder) private var showInFolder

    func body(content: Content) -> some View {
        #if os(iOS)
            content.fullScreenCover(item: $start) { (start: ViewerStart) in
                NavigationStack {
                    MediaViewer(ids: start.ids, startId: start.startId, stacks: start.stacks, currentChanged: zoom?.currentChanged)
                }
                .environment(session)
                .environment(\.showInFolder, showInFolder)
                // The viewer paints its own black backdrop and fades it while it is dragged down to close.
                .presentationBackground(.clear)
                .modifier(ViewerZoomTransition(source: zoom))
            }
        #else
            content.navigationDestination(item: $start) { (start: ViewerStart) in
                MediaViewer(ids: start.ids, startId: start.startId, stacks: start.stacks)
            }
        #endif
    }
}

#if os(iOS)
    /// Zooms the viewer out of its tile. The system's own interactive dismissal of a zoom transition is turned off: the
    /// viewer has its swipe down to close (the page follows the finger), and the photo's pinch zooms the photo.
    private struct ViewerZoomTransition: ViewModifier {
        let source: ViewerZoomSource?

        func body(content: Content) -> some View {
            if let source {
                content
                    .navigationTransition(.zoom(sourceID: source.tile, in: source.namespace))
                    .interactiveDismissDisabled()
            } else {
                content
            }
        }
    }
#endif

/// Marks where the tile of `tile` is as the zoom transition's source: an empty view over the platform grid, which is
/// not made of SwiftUI views (iPhone, iPad).
struct ViewerZoomSourceMark: View {
    let tile: FileID?
    let frame: CGRect?
    let namespace: Namespace.ID

    var body: some View {
        #if os(iOS)
            if let tile, let frame {
                Color.clear
                    .frame(width: frame.width, height: frame.height)
                    .matchedTransitionSource(id: tile, in: namespace)
                    .position(x: frame.midX, y: frame.midY)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        #endif
    }
}
