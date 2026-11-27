// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import AuthenticationServices
import PhotosCore
import PhotosNetworking
import SwiftUI

#if os(iOS)
    import AVFoundation
    import VisionKit
#endif

/// Login with Login Flow v2 (SPEC §5.1).
public struct LoginView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var address = ""
    @State private var phase: Phase = .idle
    @State private var error: String?
    @State private var untrusted: CertificateProblem?
    @State private var loginTask: Task<Void, Never>?
    @State private var pasteLink = ""
    @State private var unencrypted: UnencryptedLogin?
    /// The QR code scanner is open (iPhone, iPad).
    @State private var scanning = false
    @State private var scanError: String?
    /// The scanner found a login link; it is confirmed once the scanner has closed.
    @State private var scannedLink = false
    /// A login link or QR code waiting for the user to confirm the server and user it names.
    @State private var confirmingLink: LinkLogin?
    /// Hosts whose certificate was trusted in this login. Unless the login ends with an account on them, the trust is taken
    /// back when the login is cancelled or left (`AppModel.forgetUnusedTrust`).
    @State private var trustedHosts: Set<String> = []
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

    /// A login to a plain-http server that waits for the user's confirmation.
    enum UnencryptedLogin: Equatable {
        case address(host: String)
        /// A login link names the user too; confirming the unencrypted connection also confirms the server and user.
        case link(LinkLogin)

        var host: String {
            switch self {
            case .address(let host): host
            case .link(let link): link.host
            }
        }
    }

    /// What a login link or QR code would add: shown before anything is sent, so a planted code can't add an account on
    /// another server unnoticed (SPEC §5.1).
    struct LinkLogin: Equatable, Identifiable {
        var id: String { "\(user)@\(host)" }
        var host: String
        var user: String

        init(_ credentials: LoginService.Credentials) {
            let url = credentials.serverURL
            if let name = url.host(percentEncoded: false) {
                host = url.port.map { "\(name):\($0)" } ?? name
            } else {
                host = url.absoluteString
            }
            user = credentials.loginName
        }
    }

    public var body: some View {
        // Centred in the window; scrolls when the window (or the screen with a keyboard) is smaller than the form.
        GeometryReader { (proxy: GeometryProxy) in
            ScrollView {
                if isAddingAccount {
                    form.frame(maxWidth: .infinity).frame(minHeight: proxy.size.height)
                } else {
                    // The first login (SPEC §17.6.2): the form on a card over the drifting photo wall and the moving blue.
                    form
                        .welcomeCard()
                        .padding(16)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: proxy.size.height)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background {
            if !isAddingAccount { WelcomeBackdrop() }
        }
        // The backdrop is the same in light and dark mode, and so is the text on it.
        .environment(\.colorScheme, isAddingAccount ? colorScheme : .dark)
        .certificateTrustAlert($untrusted) { untrusted in
            try? app.http.trustStore.trust(certificate: untrusted.certificate, for: untrusted.host)
            trustedHosts.insert(untrusted.host.lowercased())
            startLogin()
        }
        .onDisappear { forgetUnusedTrust() }
        .onChange(of: app.managed.serverURL, initial: true) { _, server in
            if let server { address = server.absoluteString }
        }
    }

    /// Takes back the trust in certificates accepted during this login for hosts that did not become an account.
    func forgetUnusedTrust() {
        guard !trustedHosts.isEmpty else { return }
        app.forgetUnusedTrust(trustedHosts)
        trustedHosts = []
    }

    var form: some View {
        VStack(spacing: 28) {
            header
            VStack(alignment: .leading, spacing: 12) {
                Text("Server address", bundle: .module)
                    .font(.headline)
                    // The text field below carries the same label.
                    .accessibilityHidden(true)
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
                .onSubmit { startLogin() }
                // The organisation names the server (SPEC §5.1.9): it is filled in and can't be changed.
                .disabled(phase != .idle || app.managed.serverURL != nil)

                if app.managed.serverURL != nil {
                    Text(ManagedWording.serverManaged).font(.footnote).foregroundStyle(.secondary)
                }

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }

                Button {
                    startLogin()
                } label: {
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
        // A login error appears away from the focus (VoiceOver is still on the button): read it out.
        .onChange(of: error) { _, message in
            if let message { AccessibilityNotification.Announcement(message).post() }
        }
        .alert(
            String(localized: "This connection is not encrypted", bundle: .module),
            isPresented: Binding(get: { unencrypted != nil }, set: { shown in if !shown { unencrypted = nil } }),
            presenting: unencrypted
        ) { pending in
            Button(String(localized: "Log in anyway", bundle: .module), role: .destructive) {
                switch pending {
                case .address: startLogin(allowUnencrypted: true)
                case .link: loginWithLink(confirmed: true)
                }
            }
            Button(String(localized: "Cancel", bundle: .module), role: .cancel) {}
        } message: { pending in
            switch pending {
            case .address:
                Text(
                    "\(pending.host) uses http:// instead of https://. Your password and all your photos would be sent unencrypted, and anyone on the network could read them. Only continue if you trust the network between you and this server.",
                    bundle: .module)
            case .link(let link):
                Text(
                    "This link logs in to \(link.host) as \(link.user). The server uses http:// instead of https://: your password and all your photos would be sent unencrypted, and anyone on the network could read them. Only continue if this is your server and you trust the network between you and it.",
                    bundle: .module)
            }
        }
        .alert(
            String(localized: "Add this account?", bundle: .module),
            isPresented: Binding(get: { confirmingLink != nil }, set: { shown in if !shown { confirmingLink = nil } }),
            presenting: confirmingLink
        ) { _ in
            Button(String(localized: "Log in", bundle: .module)) { loginWithLink(confirmed: true) }
            Button(String(localized: "Cancel", bundle: .module), role: .cancel) {}
        } message: { link in
            Text(
                "Log in to \(link.host) as \(link.user)? Your photos will be shown from this server, and backup will upload to it. Only continue if this is your own Nextcloud.",
                bundle: .module)
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
            // The first run's first step of three (SPEC §22.2); not when adding an account.
            if !isAddingAccount {
                FirstRunProgress(step: 1, count: FirstRun.stepCount(backupAvailable: !app.managed.disablesBackup))
                    .padding(.bottom, 4)
            }
            PhotosAppIcon()
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                .accessibilityHidden(true)
            Group {
                if isAddingAccount {
                    Text("Nextcloud Photos", bundle: .module)
                } else {
                    Text(
                        "Welcome to Nextcloud Photos", bundle: .module,
                        comment: "Headline of the login screen at the first launch, above the server address.")
                }
            }
            .font(.largeTitle.bold())
            .multilineTextAlignment(.center)
            .accessibilityAddTraits(.isHeader)
            Text("All your photos and videos, on your own Nextcloud.", bundle: .module)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder var suggestions: some View {
        let shared = SharedNextcloudAccounts.load().filter { entry in
            !app.accounts.contains { $0.serverURL.absoluteString == entry.url }
                && LoginService.normalizeServerAddress(entry.url).map { app.loginRefusal(serverURL: $0) == nil } ?? false
        }
        if !shared.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Use an account from another Nextcloud app", bundle: .module)
                    .font(.headline)
                ForEach(shared, id: \.self) { entry in
                    Button {
                        address = entry.url
                        startLogin()
                    } label: {
                        Label(Self.sharedAccountTitle(name: entry.name ?? entry.user, url: entry.url), systemImage: "person.crop.circle")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A name and a server address: nothing to translate.
    static func sharedAccountTitle(name: String, url: String) -> String {
        "\(name) – \(url)"
    }

    var qrLogin: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                #if os(iOS)
                    if QRCodeScanner.isSupported {
                        Text(
                            "Scan the QR code shown under Settings › Security › Devices & sessions on the web, or paste the login link (nc://login/…) from there.",
                            bundle: .module
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        Button {
                            startScanning()
                        } label: {
                            Label(String(localized: "Scan QR code", bundle: .module), systemImage: "qrcode.viewfinder")
                        }
                        .buttonStyle(.bordered)
                        .disabled(phase != .idle)
                        if let scanError { Text(scanError).font(.footnote).foregroundStyle(.secondary) }
                    } else {
                        pasteHint
                    }
                #else
                    pasteHint
                #endif
                TextField(text: $pasteLink, prompt: Text(verbatim: "nc://login/…")) { Text("Login link", bundle: .module) }
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    #if os(iOS) || os(visionOS)
                        .textInputAutocapitalization(.never)
                    #endif
                Button(String(localized: "Log in with link", bundle: .module)) { loginWithLink() }
                    .disabled(pasteLink.isEmpty || phase != .idle)
            }
            .padding(.top, 8)
        } label: {
            Text(qrLoginTitle)
        }
        #if os(iOS)
            // The confirmation of the scanned link comes once the scanner is gone: an alert can't be shown while the sheet
            // is still being dismissed.
            .sheet(
                isPresented: $scanning,
                onDismiss: {
                    if scannedLink {
                        scannedLink = false
                        loginWithLink()
                    }
                }
            ) {
                QRCodeScannerSheet { link in
                    pasteLink = link
                    scannedLink = true
                    scanning = false
                }
            }
        #endif
    }

    var pasteHint: some View {
        Text("Paste a login link (nc://login/…) from Settings › Security › Devices & sessions on the web.", bundle: .module)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    /// Only where there is a scanner is a QR code promised (iPhone and iPad with a camera).
    var qrLoginTitle: String {
        #if os(iOS)
            if QRCodeScanner.isSupported { return String(localized: "Log in with a QR code or link", bundle: .module) }
        #endif
        return String(localized: "Log in with a link", bundle: .module)
    }

    #if os(iOS)
        /// Asks for the camera when needed, then opens the scanner; without camera access the link can still be pasted.
        func startScanning() {
            scanError = nil
            Task {
                let granted: Bool = await AVCaptureDevice.requestAccess(for: .video)
                if granted && QRCodeScanner.isAvailable {
                    scanning = true
                } else {
                    scanError = String(
                        localized: "The camera can't be used. Allow camera access in Settings, or paste the login link below.",
                        bundle: .module)
                }
            }
        }
    #endif

    func cancel() {
        loginTask?.cancel()
        loginTask = nil
        phase = .idle
        forgetUnusedTrust()
    }

    func startLogin(allowUnencrypted: Bool = false) {
        guard phase == .idle, let serverURL = LoginService.normalizeServerAddress(address) else {
            if phase == .idle { error = String(localized: "Please enter a valid server address.", bundle: .module) }
            return
        }
        if let refusal = app.loginRefusal(serverURL: serverURL) {
            error = refusal.localizedDescription
            return
        }
        if !allowUnencrypted, LoginService.isUnencrypted(serverURL) {
            error = nil
            unencrypted = .address(host: serverURL.host() ?? serverURL.absoluteString)
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
                        // With the user name the organisation configured proposed on the login page (SPEC §5.1.9).
                        using: app.managed.loginPage(flow.loginURL), callbackURLScheme: "nc", preferredBrowserSession: .ephemeral)
                }
                defer { browser.cancel() }
                var credentials = try await service.waitForGrant(flow)
                browser.cancel()
                // The server may name another address for itself than the one that was typed. The same host typed with
                // https:// stays on https://.
                credentials.serverURL = LoginService.securedServerURL(credentials.serverURL, typed: serverURL)
                if !allowUnencrypted, LoginService.isUnencrypted(credentials.serverURL) {
                    error = String(
                        localized:
                            "This server asks the app to connect without encryption (http://). Log in with its http:// address if you want to allow that.",
                        bundle: .module)
                    // The app password was already granted: it is revoked again, over the address that was typed.
                    await service.revoke(credentials, at: serverURL)
                    return
                }
                phase = .finishing
                // The first run asks nothing but backup: notifications are offered later, as a tip (SPEC §22.2).
                try await app.addAccount(credentials, askForNotifications: isAddingAccount)
                forgetUnusedTrust()
                if isAddingAccount { dismiss() }
            } catch is CancellationError {
            } catch let networkError as NetworkError {
                if case .untrustedCertificate(let host, let certificate?) = networkError {
                    untrusted = CertificateProblem(host: host, certificate: certificate)
                } else {
                    error = networkError.localizedDescription
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// - Parameter confirmed: the user saw which server and user the link names and wants to log in.
    func loginWithLink(confirmed: Bool = false) {
        let parsed = LoginService.parseLoginURL(pasteLink) ?? LoginService.parseOnetimeLoginURL(pasteLink)
        if let parsed, let refusal = app.loginRefusal(serverURL: parsed.serverURL) {
            error = refusal.localizedDescription
            return
        }
        if !confirmed, let parsed {
            error = nil
            if LoginService.isUnencrypted(parsed.serverURL) {
                unencrypted = .link(LinkLogin(parsed))
            } else {
                confirmingLink = LinkLogin(parsed)
            }
            return
        }
        let service = app.loginService()
        phase = .finishing
        error = nil
        Task {
            defer { phase = .idle }
            do {
                if let credentials = LoginService.parseLoginURL(pasteLink) {
                    try await app.addAccount(credentials, askForNotifications: isAddingAccount)
                } else if let onetime = LoginService.parseOnetimeLoginURL(pasteLink) {
                    try await app.addAccount(try await service.exchangeOnetimeToken(onetime), askForNotifications: isAddingAccount)
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

/// The login form as a sheet (adding an account, logging in again), with a Cancel button: on the Mac a sheet has no
/// other way out.
struct AddAccountSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            LoginView(isAddingAccount: true)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Cancel", bundle: .module)) { dismiss() }
                    }
                }
        }
        #if os(macOS)
            .frame(minWidth: 420, minHeight: 560)
        #endif
    }
}

/// Recognises the login links a QR code can carry.
enum LoginQRCode {
    /// The login link in a scanned code, or nil when the code is something else.
    static func loginLink(in payload: String) -> String? {
        let text = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard LoginService.parseLoginURL(text) != nil || LoginService.parseOnetimeLoginURL(text) != nil else { return nil }
        return text
    }
}

#if os(iOS)
    /// The system's live scanner (VisionKit), limited to QR codes.
    struct QRCodeScanner: UIViewControllerRepresentable {
        /// Called with the text of every QR code that comes into view.
        let onCode: @MainActor (String) -> Void

        /// The device can scan at all (it has a camera and the needed hardware).
        static var isSupported: Bool { DataScannerViewController.isSupported }
        /// Scanning is possible right now (camera access granted, not restricted).
        static var isAvailable: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

        func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

        func makeUIViewController(context: Context) -> DataScannerViewController {
            let scanner = DataScannerViewController(
                recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced, recognizesMultipleItems: false,
                isHighFrameRateTrackingEnabled: false, isHighlightingEnabled: true)
            scanner.delegate = context.coordinator
            try? scanner.startScanning()
            return scanner
        }

        func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {}

        static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
            scanner.stopScanning()
        }

        @MainActor final class Coordinator: NSObject, DataScannerViewControllerDelegate {
            let onCode: @MainActor (String) -> Void

            init(onCode: @escaping @MainActor (String) -> Void) {
                self.onCode = onCode
            }

            func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
                for item in addedItems {
                    if case .barcode(let code) = item, let payload = code.payloadStringValue { onCode(payload) }
                }
            }
        }
    }

    /// The scanner with a Cancel button; codes that are not login links are ignored, with a hint.
    struct QRCodeScannerSheet: View {
        let onLink: @MainActor (String) -> Void
        @Environment(\.dismiss) private var dismiss
        @State private var foundOtherCode = false

        var body: some View {
            NavigationStack {
                QRCodeScanner { payload in
                    if let link = LoginQRCode.loginLink(in: payload) { onLink(link) } else { foundOtherCode = true }
                }
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .bottom) {
                    Text(
                        foundOtherCode
                            ? String(localized: "This QR code is not a Nextcloud login code.", bundle: .module)
                            : String(localized: "Point the camera at the QR code.", bundle: .module)
                    )
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: .capsule)
                    .padding(.bottom, 24)
                }
                .navigationTitle(String(localized: "Scan QR code", bundle: .module))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Cancel", bundle: .module)) { dismiss() }
                    }
                }
            }
        }
    }
#endif
