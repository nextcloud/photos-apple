// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import AuthenticationServices
import PhotosCore
import PhotosModel
import SwiftUI

/// An Apple TV asked this iPhone or iPad to set it up (SPEC §22.2, `TVSetup`): which account, then the server's page in
/// the browser to grant the TV its own access, then "Apple TV is set up". Shown over the app, behind the app lock.
struct TVSetupSheet: View {
    let request: TVSetupRequest
    @Environment(AppModel.self) private var app
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @Environment(\.dismiss) private var dismiss
    @State private var flow: TVSetupPhoneFlow
    @State private var accountId: AccountID?
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize = 64.0

    init(request: TVSetupRequest) {
        self.request = request
        _flow = State(initialValue: TVSetupPhoneFlow(request: request))
    }

    var account: Account? {
        let id = accountId ?? app.activeAccount?.id
        return app.accounts.first { $0.id == id } ?? app.accounts.first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "appletv.fill")
                        .font(.system(size: iconSize))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text("Set Up Apple TV", bundle: .module, comment: "Title of the sheet when an Apple TV asks the phone to set it up.")
                        .font(.title.bold())
                        .accessibilityAddTraits(.isHeader)
                    content
                }
                .multilineTextAlignment(.center)
                .padding(28)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !isFinished {
                        Button(String(localized: "Cancel", bundle: .module)) {
                            flow.cancel()
                            dismiss()
                        }
                    }
                }
            }
        }
        .interactiveDismissDisabled(!isFinished)
        // The TV's login page in the browser; closed again when the TV says it is signed in.
        .task(id: flow.step) {
            guard case .grantInBrowser(let page) = flow.step else { return }
            do {
                _ = try await webAuthenticationSession.authenticate(
                    using: page, callbackURLScheme: "nc", preferredBrowserSession: .shared)
            } catch {
                // Closed by the user (not by the TV's "done", which cancels this task).
                if !Task.isCancelled, case .grantInBrowser = flow.step { flow.cancel() }
            }
        }
        .onChange(of: flow.step) { _, step in
            if case .done = step { AccessibilityNotification.Announcement(TVSetupSheet.doneTitle).post() }
        }
        #if DEBUG
            // Simulator runs of the whole set-up: `PHOTOS_DEBUG_TV_SETUP_AUTO=1` continues with the account shown.
            .task {
                if ProcessInfo.processInfo.environment["PHOTOS_DEBUG_TV_SETUP_AUTO"] == "1", let account { flow.choose(account) }
            }
        #endif
    }

    var isFinished: Bool {
        switch flow.step {
        case .done, .failed: true
        default: false
        }
    }

    @ViewBuilder var content: some View {
        switch flow.step {
        case .choosing:
            choosing
        case .waitingForTV:
            progress(Text("Apple TV is connecting to your Nextcloud…", bundle: .module, comment: "TV set-up on the phone, after Continue."))
        case .grantInBrowser:
            progress(
                Text(
                    "Log in if asked, then allow access for Apple TV.", bundle: .module,
                    comment: "TV set-up on the phone while the server's page is open in the browser."))
        case .done(let name):
            Label(Self.doneTitle, systemImage: "checkmark.circle.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.green)
            Text(
                "Apple TV shows the photos of \(name) now. You can remove its access any time in your Nextcloud's security settings.",
                bundle: .module, comment: "TV set-up done. Placeholder: the account's login name."
            )
            .foregroundStyle(.secondary)
            Button(String(localized: "Done", bundle: .module)) { dismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Button(String(localized: "Close", bundle: .module, comment: "Closes the TV set-up sheet after it failed.")) { dismiss() }
                .controlSize(.large)
        }
    }

    @ViewBuilder var choosing: some View {
        Text(
            "“\(request.device)” wants to show your photos and memories. Choose the account for it.", bundle: .module,
            comment: "TV set-up on the phone. Placeholder: the Apple TV's name.")
        if app.accounts.count > 1 {
            Picker(
                String(localized: "Account", bundle: .module),
                selection: Binding(get: { account?.id }, set: { accountId = $0 })
            ) {
                ForEach(app.accounts) { account in
                    // A name and a server: nothing to translate.
                    Text(verbatim: "\(account.displayName) – \(account.hostDisplayName)").tag(Optional(account.id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } else if let account {
            Label {
                Text(verbatim: "\(account.displayName) – \(account.hostDisplayName)")
            } icon: {
                AccountBadge(name: account.displayName, size: 28)
            }
            .font(.headline)
        }
        Text(
            "Apple TV gets its own access to your Nextcloud, which you allow on your server's page in the browser. No password is sent to Apple TV.",
            bundle: .module, comment: "TV set-up on the phone: how it works."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        Button {
            if let account { flow.choose(account) }
        } label: {
            Text("Continue", bundle: .module, comment: "TV set-up on the phone: sends the chosen account to the TV.")
                .frame(maxWidth: 300)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(account == nil)
        .accessibilityIdentifier("tv-setup-continue")
    }

    func progress(_ text: Text) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            text.foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    static var doneTitle: String {
        String(localized: "Apple TV is set up", bundle: .module, comment: "TV set-up on the phone: finished.")
    }
}

extension View {
    /// Shows the TV set-up when an Apple TV asks (iPhone and iPad; `TVSetupListener`).
    func tvSetupSheet() -> some View {
        modifier(TVSetupSheetHost())
    }
}

private struct TVSetupSheetHost: ViewModifier {
    @State private var listener = TVSetupListener.shared

    func body(content: Content) -> some View {
        content
            .sheet(
                item: Binding(get: { listener.request }, set: { if $0 == nil { listener.finish() } })
            ) { request in
                TVSetupSheet(request: request)
            }
            #if DEBUG
                // Screenshots and UI tours: `PHOTOS_DEBUG_TV_SETUP_SHEET=<name>` shows the sheet as if that TV asked.
                .task {
                    if let device = ProcessInfo.processInfo.environment["PHOTOS_DEBUG_TV_SETUP_SHEET"], listener.request == nil {
                        listener.showForDebugging(device: device)
                    }
                }
            #endif
    }
}
