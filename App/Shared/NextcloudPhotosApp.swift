// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosAppUI
import PhotosCore
import SwiftUI

@main
struct NextcloudPhotosApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
        }
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
