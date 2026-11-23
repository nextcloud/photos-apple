// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import SwiftUI

extension View {
    /// Shows the viewer for `start` the way the platform does it — the one way every screen opens the viewer.
    ///
    /// iPhone and iPad: a full-screen cover with a navigation stack of its own. The viewer's Close button, title and
    /// bottom bar are toolbar items; without a stack they have nowhere to show up and the viewer is a dead end.
    /// Mac and Vision Pro: pushed in the window's stack ("Back" returns to the grid), so this has to be used inside one.
    func mediaViewer(_ start: Binding<ViewerStart?>) -> some View {
        modifier(MediaViewerPresenter(start: start))
    }
}

private struct MediaViewerPresenter: ViewModifier {
    @Binding var start: ViewerStart?
    @Environment(SessionModel.self) private var session

    func body(content: Content) -> some View {
        #if os(iOS)
            content.fullScreenCover(item: $start) { (start: ViewerStart) in
                NavigationStack {
                    MediaViewer(ids: start.ids, startId: start.startId)
                }
                .environment(session)
                // The viewer paints its own black backdrop and fades it while it is dragged down to close.
                .presentationBackground(.clear)
            }
        #else
            content.navigationDestination(item: $start) { (start: ViewerStart) in
                MediaViewer(ids: start.ids, startId: start.startId)
            }
        #endif
    }
}
