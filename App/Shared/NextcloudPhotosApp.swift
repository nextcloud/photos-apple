// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosAppUI
import PhotosCore
import SwiftUI

@main
struct NextcloudPhotosApp: App {
    @State private var app = AppModel()
    #if os(iOS)
        @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #elseif os(macOS)
        @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                #if os(iOS)
                    .onAppear {
                        AppDelegate.app = app
                        NotificationRouter.shared.app = app
                    }
                #elseif os(macOS)
                    .onAppear {
                        MacAppDelegate.app = app
                        NotificationRouter.shared.app = app
                    }
                #endif
                .onAppear { AppIntentRouter.app = app }
                .onOpenURL { url in
                    // nextcloudphotos://<destination> from widgets and notifications.
                    if url.scheme == "nextcloudphotos", let host = url.host() { app.requestedDestination = host }
                }
        }
        #if os(iOS)
            // Short refresh window: sync and a bit of backup (SPEC §7.18.6).
            .backgroundTask(.appRefresh(BackgroundTasks.refresh)) {
                await BackgroundTasks.runRefresh()
            }
        #endif
        #if os(macOS)
            .defaultSize(width: 1200, height: 800)
            .commands {
                SidebarCommands()
            }
        #endif

        #if os(macOS)
            Settings {
                if let session = app.session {
                    SettingsView()
                        .environment(app)
                        .environment(session)
                        .frame(width: 520, height: 640)
                }
            }
        #endif
    }
}
