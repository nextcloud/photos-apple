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
    @Environment(\.showInTimeline) private var showInTimeline

    func body(content: Content) -> some View {
        #if os(iOS)
            content.fullScreenCover(item: $start) { (start: ViewerStart) in
                NavigationStack {
                    MediaViewer(
                        ids: start.ids, startId: start.startId, stacks: start.stacks, fromLibrary: start.fromLibrary,
                        currentChanged: zoom?.currentChanged)
                }
                .environment(session)
                .environment(\.showInFolder, showInFolder)
                .environment(\.showInTimeline, showInTimeline)
                // The viewer paints its own backdrop and fades it while it is dragged down to close.
                .presentationBackground(.clear)
                .modifier(ViewerZoomTransition(source: zoom))
                .environment(\.viewerExit, viewerExit)
                .background(PresentedStatusBar())
            }
        #else
            content.navigationDestination(item: $start) { (start: ViewerStart) in
                MediaViewer(ids: start.ids, startId: start.startId, stacks: start.stacks, fromLibrary: start.fromLibrary)
            }
        #endif
    }
}

#if os(iOS)
    extension MediaViewerPresenter {
        /// Lets the viewer land the photo in its tile with a drag and then close at once (SPEC §17.1).
        var viewerExit: ViewerExit {
            let namespace: Namespace.ID? = zoom?.namespace
            let binding: Binding<ViewerStart?> = $start
            return ViewerExit(
                tileFrame: { (page: FileID) -> CGRect? in
                    guard let namespace else { return nil }
                    return ViewerTileTracker.shared.frame(of: page, in: namespace)
                },
                setTileHidden: { (hidden: Bool) in
                    guard let namespace else { return }
                    ViewerTileTracker.shared.setHidden(hidden, in: namespace)
                },
                closeImmediately: {
                    // The photo is already in its tile: no zoom transition from the full screen back into it.
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { binding.wrappedValue = nil }
                    if let namespace {
                        // The tile shows again once the viewer is gone.
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(80))
                            ViewerTileTracker.shared.setHidden(false, in: namespace)
                        }
                    }
                })
        }
    }

    /// Lets the viewer hide the status bar with its controls. A cover with a clear background is presented "over full
    /// screen", which leaves the status bar to the window below unless the presented controller asks for it.
    private struct PresentedStatusBar: UIViewControllerRepresentable {
        final class Controller: UIViewController {
            override func viewWillAppear(_ animated: Bool) {
                super.viewWillAppear(animated)
                var presented: UIViewController? = self
                while let candidate = presented, candidate.presentingViewController == nil || candidate.parent != nil {
                    presented = candidate.parent
                }
                presented?.modalPresentationCapturesStatusBarAppearance = true
                presented?.setNeedsStatusBarAppearanceUpdate()
            }
        }

        func makeUIViewController(context: Context) -> Controller { Controller() }
        func updateUIViewController(_ controller: Controller, context: Context) {}
    }

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
                let tracker: ViewerTileTracker = .shared
                // While the viewer's photo is dragged into the tile, the tile is left empty: the photo lands there.
                (tracker.isHidden(in: namespace) ? Color(uiColor: .systemBackground) : Color.clear)
                    .frame(width: frame.width, height: frame.height)
                    .matchedTransitionSource(id: tile, in: namespace)
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .global)
                    } action: { global in
                        tracker.update(tile: tile, frame: global, in: namespace)
                    }
                    .position(x: frame.midX, y: frame.midY)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        #endif
    }
}

/// What the viewer needs to close into its tile with a drag (iPhone, iPad): where the tile is, hiding it while the
/// photo lands there, and closing without the zoom transition once it has.
struct ViewerExit {
    var tileFrame: @MainActor (FileID) -> CGRect?
    var setTileHidden: @MainActor (Bool) -> Void
    var closeImmediately: @MainActor () -> Void
}

extension EnvironmentValues {
    @Entry var viewerExit: ViewerExit? = nil
}

/// Where the zoom transition's tile is on screen, by the namespace of the grid that shows it. Written by
/// `ViewerZoomSourceMark`, read by the viewer (in another presentation, so not through the environment).
@MainActor
@Observable
final class ViewerTileTracker {
    static let shared = ViewerTileTracker()

    @ObservationIgnored private var frames: [Namespace.ID: (tile: FileID, frame: CGRect)] = [:]
    private var hidden: Set<Namespace.ID> = []

    func update(tile: FileID, frame: CGRect, in namespace: Namespace.ID) {
        frames[namespace] = (tile, frame)
    }

    /// The tile's frame in global coordinates, when the mark is on the tile of `page`.
    func frame(of page: FileID, in namespace: Namespace.ID) -> CGRect? {
        guard let known = frames[namespace], known.tile == page else { return nil }
        return known.frame
    }

    func isHidden(in namespace: Namespace.ID) -> Bool { hidden.contains(namespace) }

    func setHidden(_ isHidden: Bool, in namespace: Namespace.ID) {
        if isHidden { hidden.insert(namespace) } else { hidden.remove(namespace) }
    }
}
