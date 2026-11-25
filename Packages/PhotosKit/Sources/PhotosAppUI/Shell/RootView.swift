// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosModel
import SwiftUI

/// Root of every window: login when there is no account, else the main navigation.
public struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    /// The window's place (`NavigationSnapshot`, used by `MainView`). Kept here, where it outlives the account it belongs to.
    @SceneStorage("navigation") private var storedNavigation = ""
    /// Guest Mode shows one album or memory instead of the app (SPEC §16.8.3).
    @State private var guest = GuestMode.shared

    public init() {}

    public var body: some View {
        Group {
            if app.needsLogin {
                LoginView()
            } else if let session = app.session {
                AppLockGate {
                    if guest.isActive {
                        // No SharePlay for a guest: only the content shown to them.
                        GuestModeContent()
                    } else {
                        MainView(storedNavigation: $storedNavigation)
                            // Films shared over SharePlay (SPEC §16.6), behind the app lock.
                            .watchTogether()
                            .environment(session)
                            .id(session.account.id)
                    }
                }
                #if os(iOS)
                    // After the first login: backup is offered before anything else is asked (round-3 item 33).
                    .fullScreenCover(isPresented: Binding(get: { app.offersBackup }, set: { if !$0 { app.finishBackupOffer() } })) {
                        BackupOfferSheet().environment(session).environment(app)
                    }
                #endif
            } else {
                DelayedSpinner()
            }
        }
        .tint(Design.accent)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { app.session?.didBecomeActive() }
            if phase == .background {
                app.session?.services?.didEnterBackground()
                Task { await Diagnostics.persistLog(app: app) }
            }
        }
        // A removed account's album names don't stay in the window's restoration data.
        .onChange(of: app.accounts.map(\.id.rawValue), initial: true) { _, accounts in
            if NavigationSnapshot.isStale(storedNavigation, accounts: accounts) { storedNavigation = "" }
        }
    }
}
