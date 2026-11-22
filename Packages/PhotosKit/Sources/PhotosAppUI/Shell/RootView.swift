// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosModel
import SwiftUI

/// Root of every window: login when there is no account, else the main navigation.
public struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    public var body: some View {
        Group {
            if app.needsLogin {
                LoginView()
            } else if let session = app.session {
                MainView()
                    .environment(session)
                    .id(session.account.id)
            } else {
                ProgressView()
            }
        }
        .tint(Design.accent)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { app.session?.didBecomeActive() }
        }
    }
}
