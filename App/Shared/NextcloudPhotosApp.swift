// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreSpotlight
import PhotosAppUI
import PhotosCore
import PhotosDomain
import SwiftUI

@main
struct NextcloudPhotosApp: App {
    @State private var app = AppHost.model
    #if os(iOS)
        @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #elseif os(macOS)
        @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    #endif

    init() {
        #if os(macOS)
            // Windows are not merged into tabs: without this, View gets "Show Tab Bar" and "Show All Tabs" for a feature
            // the app does not support (each window has its own sidebar and toolbar).
            NSWindow.allowsAutomaticWindowTabbing = false
        #endif
        AppLock.shared.observeApplication()
        // Siri's phrases with an album or a person follow the albums and people Spotlight has (SPEC §7.23).
        SessionModel.collectionsIndexed = { PhotosShortcuts.updateAppShortcutParameters() }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                #if os(macOS)
                    .frame(minWidth: 760, minHeight: 480)
                #endif
                .onOpenURL { url in
                    // nextcloudphotos://[<user>@<server>/]<route> from widgets, notifications and other apps, and web links of
                    // an account's server (SPEC §4.8). The link can arrive before the window is active again: lock first if
                    // the app was away long enough, so it waits for the unlock (`MainView.openRequested`).
                    AppLock.shared.refresh()
                    app.open(url)
                }
                // A Spotlight result: its identifier is the link of the album, person or place (`SpotlightIndexer`).
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    AppLock.shared.refresh()
                    if let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String, let url = URL(string: identifier)
                    {
                        app.open(url)
                    }
                }
                // A link is shown in a window that is already open, not in a new window per link.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        #if os(iOS)
            // Short refresh window: sync and a bit of backup (SPEC §7.18.6).
            .backgroundTask(.appRefresh(BackgroundTasks.refresh)) {
                await BackgroundTasks.runRefresh()
            }
        #endif
        #if os(macOS)
            .defaultSize(width: 1200, height: 800)
            .windowToolbarStyle(.unified)
        #endif
        // The menu bar on the Mac; on iPadOS the same commands are the keyboard shortcuts (hold ⌘ to see them).
        // No InspectorCommands: Image ▸ Get Info (⌘I) shows the inspector, a second "Show Inspector" item would duplicate it.
        .commands {
            #if os(macOS)
                SidebarCommands()
            #endif
            PhotosCommands()
        }

        // An album in a window of its own (File ▸ Open in New Window, ⌥-click, the album's context menu). It takes no
        // links: those go to the main window.
        WindowGroup(id: AlbumWindowValue.sceneId, for: AlbumWindowValue.self) { $value in
            AlbumWindowView(value: $value)
                .environment(app)
        }
        .handlesExternalEvents(matching: [])
        #if os(macOS)
            .defaultSize(width: 1000, height: 700)
            .windowToolbarStyle(.unified)
        #endif

        #if os(visionOS)
            // A panorama around the viewer, opened from the viewer's "Immersive" button.
            ImmersiveSpace(id: PanoramaImmersion.spaceID, for: PanoramaImmersion.Request.self) { $request in
                if let request { PanoramaSpace(request: request) }
            }
        #endif

        #if os(macOS)
            Settings {
                MacSettingsView()
                    .environment(app)
            }
        #endif
    }
}
