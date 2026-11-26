// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosStore
import SwiftUI

/// Zoom In / Zoom Out / Zoom to Fit in the actions menu of assistive technologies (photos only).
private struct ZoomAccessibilityActions: ViewModifier {
    let isPhoto: Bool
    let zoom: (ViewerZoomCommand.Kind) -> Void

    func body(content: Content) -> some View {
        if isPhoto {
            content
                .accessibilityAction(named: Text("Zoom In", bundle: .module)) { zoom(.zoomIn) }
                .accessibilityAction(named: Text("Zoom Out", bundle: .module)) { zoom(.zoomOut) }
                .accessibilityAction(named: Text("Zoom to Fit", bundle: .module)) { zoom(.fit) }
        } else {
            content
        }
    }
}

/// Favourite, Info and Delete in the actions menu of assistive technologies.
private struct ViewerPageActions: ViewModifier {
    let offered: Bool
    let favoriteTitle: String
    let actions: ViewerPage.AccessibilityActions

    func body(content: Content) -> some View {
        if offered {
            content
                .accessibilityAction(named: Text(favoriteTitle)) { actions.toggleFavorite() }
                .accessibilityAction(named: Text("Info", bundle: .module)) { actions.showInfo() }
                .accessibilityAction(named: Text("Delete", bundle: .module)) { actions.delete() }
        } else {
            content
        }
    }
}

/// One page: zoomable photo, Live Photo or video.
struct ViewerPage: View {
    /// The viewer's actions, offered to VoiceOver on the page.
    struct AccessibilityActions {
        var step: (Int) -> Void = { _ in }
        var toggleFavorite: () -> Void = {}
        var showInfo: () -> Void = {}
        var delete: () -> Void = {}
        var zoom: (ViewerZoomCommand.Kind) -> Void = { _ in }
    }

    /// What the page tells the viewer. Taps are reported by photo pages only: a video page leaves every touch to
    /// the system player, whose controls must not sit under a gesture of the viewer.
    @MainActor
    struct Events {
        var tapped: () -> Void = {}
        var scaleChanged: (CGFloat) -> Void = { _ in }
        var verticalDrag: (ViewerSwipe.Phase) -> Void = { _ in }
    }

    let fileId: FileID
    let isCurrent: Bool
    var playbackToggle = 0
    /// "3 of 120".
    var position = ""
    var actions = AccessibilityActions()
    var zoomCommand: ViewerZoomCommand?
    var events = Events()
    /// Favourite, Info and Delete for assistive technologies; not in Guest Mode (SPEC §16.8.3).
    var offersActions = true
    @Environment(SessionModel.self) private var session
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var item: MediaItem?
    /// The library was asked for the photo; with no `item`, the library does not have it (any more).
    @State private var isLoaded = false
    /// Names of the recognised people, loaded for the photo shown while VoiceOver runs.
    @State private var people: [String] = []

    var body: some View {
        Group {
            if let item {
                if item.kind == .video {
                    // The player's own controls stay reachable inside the page.
                    VideoPage(item: item, isCurrent: isCurrent, playbackToggle: playbackToggle, verticalDrag: events.verticalDrag)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(description(of: item))
                } else {
                    ZoomablePhoto(item: item, isCurrent: isCurrent, command: zoomCommand, events: photoEvents)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(description(of: item))
                        .accessibilityValue(position)
                        .accessibilityAddTraits(.isImage)
                        // The zoom gestures of VoiceOver and other assistive technologies.
                        .accessibilityZoomAction { action in
                            switch action.direction {
                            case .zoomIn: actions.zoom(.zoomIn)
                            case .zoomOut: actions.zoom(.zoomOut)
                            @unknown default: break
                            }
                        }
                        // Swipe up or down with VoiceOver: next or previous photo.
                        .accessibilityAdjustableAction { direction in
                            switch direction {
                            case .increment: actions.step(1)
                            case .decrement: actions.step(-1)
                            @unknown default: break
                            }
                        }
                }
            } else if isLoaded {
                // Removed by a sync or a delete made elsewhere: say so instead of loading for ever.
                ContentUnavailableView(
                    String(localized: "This item is no longer available", bundle: .module), systemImage: "photo",
                    description: Text("It was deleted or moved on the server.", bundle: .module)
                )
                // On the stage's colour (black or white).
                .foregroundStyle(.primary)
            } else {
                // Read from the local index in a few milliseconds: nothing to show for that moment.
                Color.clear
            }
        }
        .modifier(ViewerPageActions(offered: offersActions, favoriteTitle: favoriteActionTitle, actions: actions))
        .modifier(ZoomAccessibilityActions(isPhoto: item?.kind == .image, zoom: actions.zoom))
        .task(id: fileId) {
            // Observed, so the VoiceOver favourite action and description follow a toggle.
            guard let library = session.services?.library else { return }
            do {
                for try await value in library.observeItem(fileId) {
                    item = value
                    isLoaded = true
                }
            } catch {}
        }
        .task(id: PeopleRequest(fileId: fileId, wanted: isCurrent && voiceOver)) {
            guard isCurrent, voiceOver, item?.kind == .image, let path = item?.path, session.features.has(.recognize),
                let services = session.services
            else { return }
            let faces = (try? await services.api.faceDetections(userPath: path)) ?? []
            people = faces.compactMap(\.title).filter { !$0.isEmpty }
        }
    }

    var photoEvents: ZoomSurfaceEvents {
        let isCurrent: Bool = isCurrent
        let events: Events = events
        return ZoomSurfaceEvents(
            // A page that is paged away goes back to the fitted size; that is not the scale of the photo shown.
            scaleChanged: { scale in if isCurrent { events.scaleChanged(scale) } },
            tapped: events.tapped,
            verticalDrag: { phase in if isCurrent { events.verticalDrag(phase) } })
    }

    struct PeopleRequest: Hashable {
        var fileId: FileID
        var wanted: Bool
    }

    var favoriteActionTitle: String {
        MediaViewer.favoriteTitle(remove: item?.isFavorite ?? false)
    }

    /// "Photo, 22 November 2026 at 14:03, Lisbon, with Anna and Ben, Favorite, A dog on the beach".
    func description(of item: MediaItem) -> String {
        AccessibilityText.media(
            isVideo: item.kind == .video, isLivePhoto: item.isLivePhoto, date: item.timestamp, duration: item.duration,
            place: item.place, people: people, isFavorite: item.isFavorite,
            // The server's caption, else the description written on this device (SPEC §16.2).
            caption: item.caption ?? session.services?.descriptions.text(of: item.fileId))
    }
}
