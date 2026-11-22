// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import AuthenticationServices
import PhotosCore
import PhotosNetworking
import SwiftUI

/// Login with Login Flow v2 (SPEC §5.1).
public struct LoginView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var phase: Phase = .idle
    @State private var error: String?
    @State private var untrusted: UntrustedCertificate?
    @State private var loginTask: Task<Void, Never>?
    @State private var pasteLink = ""
    var isAddingAccount = false

    public init(isAddingAccount: Bool = false) {
        self.isAddingAccount = isAddingAccount
    }

    enum Phase: Equatable {
        case idle
        case checking
        case waitingForBrowser
        case finishing
    }

    struct UntrustedCertificate: Identifiable {
        var id: String { host }
        var host: String
        var certificate: Data
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                header
                VStack(alignment: .leading, spacing: 12) {
                    Text("Server address", bundle: .module)
                        .font(.headline)
                    TextField(text: $address, prompt: Text(verbatim: "cloud.example.com")) {
                        Text("Server address", bundle: .module)
                    }
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    #if os(iOS) || os(visionOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                    #endif
                    .onSubmit(startLogin)
                    .disabled(phase != .idle)

                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }

                    Button(action: startLogin) {
                        HStack {
                            if phase != .idle { ProgressView().controlSize(.small) }
                            Text(phaseTitle)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || phase != .idle)

                    if phase == .waitingForBrowser {
                        Button(String(localized: "Cancel", bundle: .module), role: .cancel) { cancel() }
                            .frame(maxWidth: .infinity)
                    }
                }
                suggestions
                qrLogin
            }
            .padding(24)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .alert(item: $untrusted) { untrusted in
            Alert(
                title: Text("Untrusted certificate", bundle: .module),
                message: Text(
                    "The certificate of \(untrusted.host) is not trusted by this device. Only trust it if you know it belongs to your server.\n\n\(TrustStore.summary(of: untrusted.certificate))",
                    bundle: .module),
                primaryButton: .destructive(Text("Trust and continue", bundle: .module)) {
                    try? app.http.trustStore.trust(certificate: untrusted.certificate, for: untrusted.host)
                    startLogin()
                },
                secondaryButton: .cancel())
        }
    }

    var phaseTitle: String {
        switch phase {
        case .idle: String(localized: "Log in", bundle: .module)
        case .checking: String(localized: "Connecting…", bundle: .module)
        case .waitingForBrowser: String(localized: "Waiting for login in the browser…", bundle: .module)
        case .finishing: String(localized: "Finishing…", bundle: .module)
        }
    }

    var header: some View {
        VStack(spacing: 12) {
            PhotosAppIcon()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text("Nextcloud Photos", bundle: .module)
                .font(.largeTitle.bold())
            Text("All your photos and videos, on your own Nextcloud.", bundle: .module)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 24)
    }

    @ViewBuilder var suggestions: some View {
        let shared = SharedNextcloudAccounts.load().filter { entry in !app.accounts.contains { $0.serverURL.absoluteString == entry.url } }
        if !shared.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Use an account from another Nextcloud app", bundle: .module)
                    .font(.headline)
                ForEach(shared, id: \.self) { entry in
                    Button {
                        address = entry.url
                        startLogin()
                    } label: {
                        Label("\(entry.name ?? entry.user) – \(entry.url)", systemImage: "person.crop.circle")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var qrLogin: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text("Paste a login link (nc://login/…) from Settings › Security › Devices & sessions on the web.", bundle: .module)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                TextField(text: $pasteLink, prompt: Text(verbatim: "nc://login/…")) { Text("Login link", bundle: .module) }
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                Button(String(localized: "Log in with link", bundle: .module)) { loginWithLink() }
                    .disabled(pasteLink.isEmpty || phase != .idle)
            }
            .padding(.top, 8)
        } label: {
            Text("Log in with a QR code or link", bundle: .module)
        }
    }

    func cancel() {
        loginTask?.cancel()
        loginTask = nil
        phase = .idle
    }

    func startLogin() {
        guard phase == .idle, let serverURL = LoginService.normalizeServerAddress(address) else {
            if phase == .idle { error = String(localized: "Please enter a valid server address.", bundle: .module) }
            return
        }
        error = nil
        phase = .checking
        loginTask = Task {
            defer { phase = .idle }
            let service = app.loginService()
            do {
                _ = try await service.status(serverURL: serverURL)
                let flow = try await service.startFlow(serverURL: serverURL)
                phase = .waitingForBrowser
                let browser = Task { @MainActor in
                    _ = try? await webAuthenticationSession.authenticate(
                        using: flow.loginURL, callbackURLScheme: "nc", preferredBrowserSession: .ephemeral)
                }
                defer { browser.cancel() }
                let credentials = try await service.waitForGrant(flow)
                browser.cancel()
                phase = .finishing
                try await app.addAccount(credentials)
                if isAddingAccount { dismiss() }
            } catch is CancellationError {
            } catch let networkError as NetworkError {
                if case .untrustedCertificate(let host, let certificate?) = networkError {
                    untrusted = UntrustedCertificate(host: host, certificate: certificate)
                } else {
                    error = networkError.localizedDescription
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func loginWithLink() {
        let service = app.loginService()
        phase = .finishing
        error = nil
        Task {
            defer { phase = .idle }
            do {
                if let credentials = LoginService.parseLoginURL(pasteLink) {
                    try await app.addAccount(credentials)
                } else if let onetime = LoginService.parseOnetimeLoginURL(pasteLink) {
                    try await app.addAccount(try await service.exchangeOnetimeToken(onetime))
                } else {
                    error = String(localized: "This is not a valid login link.", bundle: .module)
                    return
                }
                if isAddingAccount { dismiss() }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
