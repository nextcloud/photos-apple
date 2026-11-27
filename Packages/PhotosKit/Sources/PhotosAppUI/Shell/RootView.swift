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
    @State private var lock = AppLock.shared

    public init() {}

    /// iPhone and iPad after the first login: the backup step of the first run (`AppModel.offersBackup`).
    var showsFirstRunBackup: Bool {
        #if os(iOS)
            app.offersBackup
        #else
            false
        #endif
    }

    /// "Backup is on" in the welcome when the first run turned it on.
    var firstRunDoneLine: String? {
        FirstRunState.shared.backupTurnedOn || app.backup.settings.isEnabled ? FirstLaunchWelcome.backupOnLine : nil
    }

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
                // The first run's backup step covers the Library, which loads behind it (SPEC §22.2).
                .accessibilityHidden(showsFirstRunBackup)
                .overlay {
                    if showsFirstRunBackup {
                        FirstRunBackupStep().environment(session)
                            .transition(.opacity)
                    }
                }
                // The first run's last step: the short welcome into the Library, over it (SPEC §17.6.3, §22.2), after the
                // backup step.
                .overlay {
                    if (app.welcomesFirstLogin && !showsFirstRunBackup) || debugWelcome {
                        FirstLaunchWelcome(name: session.account.displayName, doneLine: firstRunDoneLine) {
                            debugWelcome = false
                            FirstRunState.shared.backupTurnedOn = false
                            app.finishWelcome()
                        }
                        .transition(.identity)
                    }
                }
            } else {
                DelayedSpinner()
            }
        }
        .tint(Design.accent)
        // Handoff of an account that is not logged in here (SPEC §22.2); also on the login screen.
        .handoffPrompts(isLocked: lock.requiresUnlock)
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
