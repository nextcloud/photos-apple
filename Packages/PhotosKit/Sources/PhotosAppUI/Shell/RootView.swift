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
    /// `PHOTOS_DEBUG_WELCOME=transition`: the welcome plays at launch although no login happened (screenshots).
    @State private var debugWelcome = WelcomeDebug.playsTransition

    public init() {}

    public var body: some View {
        // Before the first screen is built: the Library's first items, off the main thread (`LibraryLaunchPrefetch`).
        let _ = LibraryLaunchPrefetch.shared.start(app.session)
        Group {
            if app.needsLogin || WelcomeDebug.showsLogin {
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
                // A normal launch: the app comes up with a quick fade (SPEC §17.6.3).
                .modifier(LaunchReveal())
                // After the first login: the short welcome into the Library, over it (SPEC §17.6.3).
                .overlay {
                    if app.welcomesFirstLogin || debugWelcome {
                        FirstLaunchWelcome(name: session.account.displayName) {
                            debugWelcome = false
                            app.finishWelcome()
                        }
                        .transition(.identity)
                    }
                }
                #if os(iOS)
                    // After the first login: backup is offered before anything else is asked (round-3 item 33), once the
                    // welcome has played.
                    .fullScreenCover(
                        isPresented: Binding(
                            get: { app.offersBackup && !app.welcomesFirstLogin && !debugWelcome },
                            set: { if !$0 { app.finishBackupOffer() } })
                    ) {
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
