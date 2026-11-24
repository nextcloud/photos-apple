// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import SwiftUI

#if os(macOS)
    import AppKit
#endif

/// The content of a window that shows one album (SPEC §6.2: open an album in a new window). The scene is
/// `WindowGroup(id: AlbumWindowValue.sceneId, for: AlbumWindowValue.self)` in the app; opening the same album twice
/// brings its window to the front. The window shows the album of the account that is active in the app; when another
/// account is active it says so instead of showing photos of the wrong account.
public struct AlbumWindowView: View {
    @Binding var value: AlbumWindowValue?
    @Environment(AppModel.self) private var app

    public init(value: Binding<AlbumWindowValue?>) {
        _value = value
    }

    public var body: some View {
        Group {
            if let value, let session = app.session, !app.needsLogin {
                if session.account.id.rawValue == value.account {
                    AppLockGate {
                        NavigationStack {
                            AlbumRouteScreen(albumId: value.albumId)
                                .navigationDestination(for: AppRoute.self) { route in RouteView(route: route) }
                        }
                        .environment(session)
                    }
                } else {
                    ContentUnavailableView(
                        String(localized: "Album of another account", bundle: .module),
                        systemImage: "person.crop.circle.badge.questionmark",
                        description: Text("Switch back to the account the album belongs to, to see it here.", bundle: .module))
                }
            } else {
                ContentUnavailableView(String(localized: "Album not found", bundle: .module), systemImage: "rectangle.stack.badge.minus")
            }
        }
        .tint(Design.accent)
        #if os(macOS)
            .frame(minWidth: 480, minHeight: 360)
        #endif
    }
}

/// "Open in New Window" for an album: the context menu of its card, and ⌥-click on the Mac.
struct OpenAlbumInWindow: ViewModifier {
    let albumId: String
    @Environment(SessionModel.self) private var session
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows

    var value: AlbumWindowValue { AlbumWindowValue(account: session.account.id.rawValue, albumId: albumId) }

    func body(content: Content) -> some View {
        if supportsMultipleWindows {
            content
                .contextMenu {
                    Button {
                        openWindow(id: AlbumWindowValue.sceneId, value: value)
                    } label: {
                        Label(
                            PlatformWording.title(
                                mac: LocalizedStringResource("Open in New Window", bundle: .module),
                                other: LocalizedStringResource("Open in new window", bundle: .module)),
                            systemImage: "macwindow.badge.plus")
                    }
                }
                #if os(macOS)
                    // ⌥-click (and ⌥-double-click) opens the album in its own window instead of in this one, like a folder
                    // in Finder. The same album twice only brings its window to the front.
                    .highPriorityGesture(TapGesture().modifiers(.option).onEnded { openWindow(id: AlbumWindowValue.sceneId, value: value) })
                #endif
        } else {
            content
        }
    }
}

extension View {
    func opensAlbumInWindow(_ albumId: String) -> some View {
        modifier(OpenAlbumInWindow(albumId: albumId))
    }
}
