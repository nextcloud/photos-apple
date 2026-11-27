// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosModel
import SwiftUI

/// Opens Settings where it is not a tab or window of its own (iPhone, iPad, Vision Pro: a sheet; SPEC §19.2).
struct ShowSettingsAction {
    let action: @MainActor () -> Void

    @MainActor func callAsFunction() { action() }
}

extension EnvironmentValues {
    /// Set by the main window; nil where Settings cannot be opened from (album windows, previews).
    @Entry var showSettings: ShowSettingsAction? = nil
}

/// The account button (SPEC §19.2): the account's initials in a circle, with a menu of the account's name and server,
/// switching and adding accounts, Upload (iPhone, iPad, Vision Pro) and Settings. In the top bars of the Library and
/// Collections; on the Mac it can stand in the sidebar or toolbar, where Settings is the Settings window (⌘,).
struct AccountMenuButton: View {
    @Environment(AppModel.self) private var app
    @Environment(SessionModel.self) private var session
    @Environment(\.showSettings) private var showSettings
    @State private var addingAccount = false
    @State private var upload: UploadStart?

    /// Where the button goes in a top bar: at its trailing end, after the screen's own buttons.
    static var placement: ToolbarItemPlacement {
        #if os(macOS)
            .primaryAction
        #else
            .topBarTrailing
        #endif
    }

    var body: some View {
        let account: Account = session.account
        Menu {
            Section {
                ForEach(app.accounts) { (other: Account) in
                    accountButton(other, isCurrent: other.id == account.id)
                }
                if app.canAddAccount {
                    Button {
                        addingAccount = true
                    } label: {
                        Label(String(localized: "Add account…", bundle: .module), systemImage: "person.crop.circle.badge.plus")
                    }
                }
            } header: {
                // A name and a server: nothing to translate.
                Text(verbatim: "\(account.displayName) – \(account.hostDisplayName)")
            }
            // "All backed up" or "12 not backed up" (SPEC §21.1).
            BackupSummaryMenuSection()
            #if !os(macOS)
                // The Mac uploads from File ▸ Upload Photos… and by dropping files on the window.
                Section {
                    Menu {
                        UploadMenuItems { (start: UploadStart) in upload = start }
                    } label: {
                        Label(UploadStart.menuTitle, systemImage: UploadStart.systemImage)
                    }
                }
            #endif
            Section {
                settingsButton
            }
        } label: {
            // The avatar itself, not a label with it as icon: a toolbar shows such a label's title.
            AccountAvatar(name: account.displayName)
                .overlay(alignment: .bottomTrailing) { BackupSummaryBadge() }
        }
        .accessibilityLabel(AccountMenuWording.accessibilityLabel(name: account.displayName, server: account.hostDisplayName))
        .accessibilityHint(AccountMenuWording.accessibilityHint)
        .accessibilityIdentifier("account-menu")
        .help(AccountMenuWording.accessibilityLabel(name: account.displayName, server: account.hostDisplayName))
        .uploadPresenter($upload)
        .sheet(isPresented: $addingAccount) { AddAccountSheet() }
    }

    @ViewBuilder func accountButton(_ account: Account, isCurrent: Bool) -> some View {
        // A name and a server: nothing to translate.
        let title: String = app.accounts.count > 1 ? "\(account.displayName) – \(account.hostDisplayName)" : account.displayName
        Button {
            if !isCurrent { app.switchTo(account.id) }
        } label: {
            if isCurrent {
                Label(title, systemImage: "checkmark")
            } else {
                Text(verbatim: title)
            }
        }
        .disabled(isCurrent && app.accounts.count == 1)
    }

    @ViewBuilder var settingsButton: some View {
        #if os(macOS)
            SettingsLink {
                Label(AccountMenuWording.settingsTitle, systemImage: "gearshape")
            }
        #else
            Button {
                showSettings?()
            } label: {
                Label(AccountMenuWording.settingsTitle, systemImage: "gearshape")
            }
            .disabled(showSettings == nil)
        #endif
    }
}

/// The account's initials in a circle of the accent colour, the way Apple's apps show an account without a picture.
/// White on the accent (6.1:1, SPEC §20.3), like the sidebar's `AccountBadge`; the pale tint it had was too faint. Hidden
/// from VoiceOver: the button around it says whose account it is. It keeps its size in the toolbar, where the system
/// shows bar buttons enlarged (Large Content Viewer) instead.
struct AccountAvatar: View {
    let name: String
    var size: CGFloat = 28

    var body: some View {
        let initials: String = AccountInitials.initials(of: name)
        ZStack {
            Circle().fill(Design.accent)
            if initials.isEmpty {
                Image(systemName: "person.fill").font(.system(size: size * 0.5)).foregroundStyle(.white)
            } else {
                Text(verbatim: initials)
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

enum AccountMenuWording {
    static func accessibilityLabel(name: String, server: String) -> String {
        String(
            localized: "Account \(name) on \(server)", bundle: .module,
            comment:
                "VoiceOver label of the account switcher in the sidebar. The first %@ is the user's name, the second the server's host name."
        )
    }

    static var accessibilityHint: String {
        String(
            localized: "Settings, upload, switch or add an account", bundle: .module,
            comment: "VoiceOver hint of the account button in the Library's top bar.")
    }

    static var settingsTitle: String {
        PlatformWording.title(
            mac: LocalizedStringResource("Settings…", bundle: .module, comment: "Account menu: opens the Settings window (Mac)."),
            other: LocalizedStringResource("Settings", bundle: .module))
    }
}

#if !os(macOS)
    /// Settings as a sheet over the window, from the account button, a link or the command palette (iPhone, iPad, Vision
    /// Pro; SPEC §19.2). The Mac has its Settings window.
    struct SettingsSheet: View {
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            NavigationStack {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(String(localized: "Done", bundle: .module)) { dismiss() }
                                .accessibilityIdentifier("settings-done")
                        }
                    }
            }
        }
    }
#endif
