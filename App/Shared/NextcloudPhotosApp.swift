// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

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
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                #if os(macOS)
                    .frame(minWidth: 760, minHeight: 480)
                #endif
                .onOpenURL { url in
                    // nextcloudphotos://<destination>, …/album/<name>, …/photo/<fileId> from widgets, notifications and other apps.
                    if let link = DeepLink(url: url) { app.requestedDestination = link.request }
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

        #if os(macOS)
            Settings {
                MacSettingsView()
                    .environment(app)
            }
        #endif
    }
}
