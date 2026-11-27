// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreImage
import CoreImage.CIFilterBuiltins
import CryptoKit
import DeviceDiscoveryUI
import Network
import PhotosCore
import PhotosModel
import PhotosNetworking
import SwiftUI

/// Login on the TV (SPEC §15.3): the server address is the only thing typed (with the Siri Remote, dictation or the iPhone's
/// keyboard); the password is entered on the user's phone. The TV starts a Login Flow v2 and shows its link as a QR code;
/// the phone's camera opens it, the user logs in there and grants access, and the TV, which polls the flow, gets its own
/// app password. No password is ever typed on the TV.
///
/// "Set Up with iPhone" (SPEC §22.2) skips even the address: Apple's device picker finds the user's iPhone or iPad, the app
/// there sends the account's server, the TV starts the same Login Flow, and the phone opens its page in the browser to
/// grant access (`TVSetup`). The QR code stays as the way for a phone without the app.
struct TVLoginView: View {
    /// An account whose app password stopped working: the user logs in to it again.
    var signedOutAccount: Account?
    @Environment(AppModel.self) private var app
    @State private var address = ""
    @State private var phase = Phase.address
    @State private var error: String?
    @State private var loginTask: Task<Void, Never>?
    @State private var unencryptedHost: String?
    @State private var untrusted: Untrusted?
    @State private var trustedHosts: Set<String> = []
    @FocusState private var addressFocused: Bool
    /// Apple's device picker is open.
    @State private var pickingDevice = false
    /// The phone that sets this TV up, while it does.
    @State private var phone: TVSetupTVFlow?
    @State private var phoneTask: Task<Void, Never>?
    @Environment(\.devicePickerSupports) private var devicePickerSupports
    #if DEBUG
        @State private var browsingBonjour = false
    #endif

    enum Phase: Equatable {
        case address
        case connecting
        /// The QR code of the flow's login link, shown until the phone grants access.
        case waiting(link: URL, code: CGImage, host: String)
        /// "Set Up with iPhone": waiting for the user to choose the account on the phone.
        case phoneChoosing
        case finishing
    }

    struct Untrusted: Identifiable {
        var host: String
        var certificate: Data
        var id: String { host }
        /// SHA-256 of the certificate, in the form browsers show it.
        var fingerprint: String {
            SHA256.hash(data: certificate).map { String(format: "%02X", $0) }.joined(separator: ":")
        }
    }

    var body: some View {
        Group {
            if case .waiting(let link, let code, let host) = phase {
                // The code gets the whole screen: it is what the user looks at now.
                qrCode(link: link, code: code, host: host)
                    .frame(maxWidth: 1500)
            } else if phase == .phoneChoosing {
                phoneChoosing
                    .frame(maxWidth: 1400)
            } else {
                HStack(alignment: .center, spacing: 80) {
                    intro
                        .frame(maxWidth: 640, alignment: .leading)
                    Group {
                        if phase == .finishing {
                            progress(Text("Signing in…", comment: "TV login: the phone granted access, the TV finishes the login."))
                        } else {
                            addressForm
                        }
                    }
                    .frame(maxWidth: 820)
                }
            }
        }
        .padding(80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TVBackdrop())
        .onAppear {
            if address.isEmpty {
                address = signedOutAccount?.serverURL.absoluteString ?? app.managed.serverURL?.absoluteString ?? ""
            }
            #if DEBUG
                // Screenshots of the QR code step: PHOTOS_DEBUG_TV_SERVER=<address> starts the flow at once.
                if let server = ProcessInfo.processInfo.environment["PHOTOS_DEBUG_TV_SERVER"], phase == .address {
                    address = server
                    start(allowUnencrypted: true)
                }
            #endif
        }
        .onDisappear {
            loginTask?.cancel()
            endPhone(nil)
            forgetUnusedTrust()
        }
        // Apple's picker of the user's iPhones and iPads (SPEC §22.2); in the simulators it finds none.
        .fullScreenCover(isPresented: $pickingDevice) {
            DevicePicker(
                .applicationService(name: TVSetup.serviceName),
                onSelect: { endpoint in
                    pickingDevice = false
                    startWithPhone(endpoint)
                },
                label: {
                    Text(
                        "Set up Nextcloud Photos with your iPhone or iPad", comment: "TV: title of the system's device picker.")
                },
                fallback: {
                    Text("No iPhone or iPad can be found.", comment: "TV: the device picker cannot be shown.")
                },
                parameters: { .applicationService })
        }
        #if DEBUG
            // Simulators: `PHOTOS_DEBUG_TV_SETUP=bonjour` finds the iPhone simulator's app over Bonjour instead.
            .sheet(isPresented: $browsingBonjour) {
                TVDebugPhoneBrowser { endpoint in
                    browsingBonjour = false
                    startWithPhone(endpoint)
                }
            }
        #endif
        .alert(
            Text("Connect without encryption?", comment: "TV login: title of the question before using an http:// server."),
            isPresented: Binding(get: { unencryptedHost != nil }, set: { if !$0 { unencryptedHost = nil } })
        ) {
            Button(role: .cancel) {
            } label: {
                Text("Cancel", comment: "TV login: button")
            }
            Button {
                start(allowUnencrypted: true)
            } label: {
                Text("Connect", comment: "TV login: button that connects to an http:// server after the warning.")
            }
        } message: {
            Text(
                "\(unencryptedHost ?? "") does not use an encrypted connection. Others on the network could see your photos and your app password.",
                comment: "TV login: warning before using an http:// server; the placeholder is the server's host name.")
        }
        .alert(
            Text(
                "Trust this certificate?",
                comment: "TV login: title of the question about a server certificate the system does not trust."),
            isPresented: Binding(get: { untrusted != nil }, set: { if !$0 { untrusted = nil } }), presenting: untrusted
        ) { untrusted in
            Button(role: .cancel) {
            } label: {
                Text("Cancel", comment: "TV login: button")
            }
            Button {
                try? app.http.trustStore.trust(certificate: untrusted.certificate, for: untrusted.host)
                trustedHosts.insert(untrusted.host.lowercased())
                start(allowUnencrypted: false)
            } label: {
                Text("Trust", comment: "TV login: button that trusts the server's certificate.")
            }
        } message: { untrusted in
            Text(
                "The certificate of \(untrusted.host) is not trusted by Apple TV. Only trust it if its fingerprint matches the one of your server:\n\(untrusted.fingerprint)",
                comment: "TV login: explanation of an untrusted certificate; placeholders: host name, SHA-256 fingerprint.")
        }
    }

    var intro: some View {
        VStack(alignment: .leading, spacing: 28) {
            Image(systemName: "photo.stack.fill")
                .font(.system(size: 96))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Nextcloud Photos", comment: "TV login: app name as the title of the login screen.")
                .font(.largeTitle.bold())
            if let signedOutAccount {
                Text(
                    "Log in to \(signedOutAccount.displayName) again: the app's access was withdrawn.",
                    comment: "TV login: the account's app password stopped working; the placeholder is the user's name."
                )
                .font(.headline)
            } else {
                Text(
                    "Your memories and albums on the big screen. Log in with your phone: no password is typed on the TV.",
                    comment: "TV login: introduction next to the login form."
                )
                .font(.headline)
                .foregroundStyle(.secondary)
            }
        }
    }

    /// Apple's picker can be shown (it needs the app's `NSApplicationServices`), or the debug Bonjour fallback is on.
    var offersPhoneSetup: Bool {
        if TVSetup.usesDebugBonjour { return true }
        return devicePickerSupports(.applicationService(name: TVSetup.serviceName), parameters: { .applicationService })
    }

    var addressForm: some View {
        VStack(alignment: .leading, spacing: 32) {
            if offersPhoneSetup, signedOutAccount == nil {
                VStack(alignment: .leading, spacing: 16) {
                    Button {
                        choosePhone()
                    } label: {
                        Label {
                            Text("Set Up with iPhone", comment: "TV login: button that sets the TV up from the user's iPhone or iPad.")
                        } icon: {
                            Image(systemName: "iphone")
                        }
                        .frame(minWidth: 520)
                    }
                    .disabled(phase == .connecting)
                    .accessibilityIdentifier("tv-setup-with-iphone")
                    Text(
                        "Open Nextcloud Photos on your iPhone or iPad nearby: it sends your server and you allow access there.",
                        comment: "TV login: under Set Up with iPhone."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Text("Or log in with the server address", comment: "TV login: heading of the address form under Set Up with iPhone.")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            Text("Server address", comment: "TV login: label of the server address field.")
                .font(.title3)
            TextField(
                text: $address,
                prompt: Text("cloud.example.com", comment: "TV login: placeholder of the server address field; an example host name.")
            ) {
                Text("Server address", comment: "TV login: label of the server address field.")
            }
            .textContentType(.URL)
            .keyboardType(.URL)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .focused($addressFocused)
            .onSubmit { start(allowUnencrypted: false) }
            .disabled(phase == .connecting)
            HStack(spacing: 32) {
                Button {
                    start(allowUnencrypted: false)
                } label: {
                    Text("Continue", comment: "TV login: button after the server address.")
                        .frame(minWidth: 260)
                }
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || phase == .connecting)
                if phase == .connecting { ProgressView() }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        }
        .defaultFocus($addressFocused, true)
    }

    func qrCode(link: URL, code: CGImage, host: String) -> some View {
        HStack(alignment: .center, spacing: 80) {
            Image(decorative: code, scale: 1)
                .interpolation(.none)
                .resizable()
                .frame(width: 520, height: 520)
                .padding(24)
                .background(.white, in: .rect(cornerRadius: 24))
                .accessibilityLabel(Text("QR code to log in", comment: "TV login: VoiceOver label of the QR code."))
            VStack(alignment: .leading, spacing: 32) {
                Group {
                    if phone != nil {
                        Text(
                            "Continue on your iPhone",
                            comment: "TV login: title while the phone shows the login page (Set Up with iPhone).")
                    } else {
                        Text("Scan with your phone", comment: "TV login: title next to the QR code.")
                    }
                }
                .font(.title2.bold())
                .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 12) {
                    if phone != nil {
                        step(
                            1,
                            Text(
                                "Your iPhone opened your server's page. (Or scan the code with another phone.)",
                                comment: "TV login: first step when the phone sets the TV up."))
                    } else {
                        step(1, Text("Open the camera on your iPhone or iPad and point it at the code.", comment: "TV login: first step."))
                    }
                    step(
                        2,
                        Text(
                            "Log in to \(host) and allow access.",
                            comment: "TV login: second step; the placeholder is the server's host name."))
                    step(3, Text("Your photos appear here.", comment: "TV login: third step."))
                }
                HStack(spacing: 16) {
                    ProgressView()
                    Text("Waiting for your phone…", comment: "TV login: shown while the TV waits for the login on the phone.")
                        .foregroundStyle(.secondary)
                }
                // The whole link, for a phone without a camera: stock servers have no shorter one.
                Text(link.absoluteString)
                    .font(.system(size: 20, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(4)
                Button {
                    cancel()
                } label: {
                    Text("Use Another Server", comment: "TV login: button that goes back to the server address.")
                }
            }
        }
    }

    func step(_ number: Int, _ text: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(number, format: .number)
                .font(.headline.monospacedDigit())
                .frame(width: 44, height: 44)
                .background(.tint.opacity(0.25), in: .circle)
            text.font(.body).fixedSize(horizontal: false, vertical: true)
        }
    }

    func progress(_ text: Text) -> some View {
        HStack(spacing: 24) {
            ProgressView()
            text.font(.title3)
        }
    }

    func cancel() {
        loginTask?.cancel()
        loginTask = nil
        phase = .address
        endPhone(.cancel)
        forgetUnusedTrust()
    }

    func forgetUnusedTrust() {
        guard !trustedHosts.isEmpty else { return }
        app.forgetUnusedTrust(trustedHosts)
        trustedHosts = []
    }

    func start(allowUnencrypted: Bool) {
        guard phase == .address else { return }
        guard let serverURL = LoginService.normalizeServerAddress(address) else {
            error = String(localized: "Please enter a valid server address.", comment: "TV login: the address cannot be a server address.")
            return
        }
        if let refusal = app.loginRefusal(serverURL: serverURL) {
            error = refusal.localizedDescription
            return
        }
        if !allowUnencrypted, LoginService.isUnencrypted(serverURL) {
            error = nil
            unencryptedHost = serverURL.host() ?? serverURL.absoluteString
            return
        }
        error = nil
        phase = .connecting
        loginTask = Task { await login(serverURL: serverURL, allowUnencrypted: allowUnencrypted) }
    }

    func login(serverURL: URL, allowUnencrypted: Bool) async {
        let service = app.loginService()
        do {
            _ = try await service.status(serverURL: serverURL)
            let flow = try await service.startFlow(serverURL: serverURL)
            let link = app.managed.loginPage(flow.loginURL)
            guard let code = TVQRCode.image(for: link.absoluteString) else { throw NetworkError.invalidResponse("qr") }
            phase = .waiting(link: link, code: code, host: serverURL.host() ?? serverURL.absoluteString)
            // Set Up with iPhone: the phone opens the page in its browser (the code stays for another phone).
            await phone?.send(.login(url: flow.loginURL))
            var credentials = try await service.waitForGrant(flow)
            credentials.serverURL = LoginService.securedServerURL(credentials.serverURL, typed: serverURL)
            if !allowUnencrypted, LoginService.isUnencrypted(credentials.serverURL) {
                await service.revoke(credentials, at: serverURL)
                phase = .address
                error = String(
                    localized:
                        "This server asks the app to connect without encryption (http://). Log in with its http:// address if you want to allow that.",
                    comment: "TV login: the server redirected an https login to http.")
                return
            }
            phase = .finishing
            try await app.addAccount(credentials, askForNotifications: false, offerBackup: false)
            forgetUnusedTrust()
            endPhone(.done(name: app.activeAccount?.displayName ?? credentials.loginName))
        } catch is CancellationError {
        } catch let networkError as NetworkError {
            phase = .address
            endPhone(.failed(reason: networkError.localizedDescription))
            if case .untrustedCertificate(let host, let certificate?) = networkError {
                untrusted = Untrusted(host: host, certificate: certificate)
            } else if case .timedOut = networkError {
                error = String(
                    localized: "The code expired. Continue to get a new one.",
                    comment: "TV login: the 20 minutes of the login flow passed.")
            } else {
                error = networkError.localizedDescription
            }
        } catch {
            phase = .address
            self.error = error.localizedDescription
            endPhone(.failed(reason: error.localizedDescription))
        }
    }

    // MARK: Set Up with iPhone (SPEC §22.2)

    func choosePhone() {
        error = nil
        #if DEBUG
            if TVSetup.usesDebugBonjour {
                browsingBonjour = true
                return
            }
        #endif
        pickingDevice = true
    }

    /// The user picked their phone: say hello, wait for the account chosen there, then log in to its server.
    func startWithPhone(_ endpoint: NWEndpoint) {
        endPhone(.cancel)
        let flow = TVSetupTVFlow(endpoint: endpoint)
        phone = flow
        phase = .phoneChoosing
        phoneTask = Task {
            do {
                let chosen = try await flow.begin(device: UIDevice.current.name)
                address = chosen.serverURL.absoluteString
                phase = .address
                // The same checks as a typed address: the organisation's server, http:// asks first on the TV.
                start(allowUnencrypted: false)
                if phase == .address, unencryptedHost == nil {
                    endPhone(.failed(reason: error ?? TVSetupWording.cancelledOnTV))
                    return
                }
                // The phone may give up (Cancel, its browser closed): the TV goes back to its start.
                let reason = await flow.phoneGaveUp()
                guard !Task.isCancelled, phone === flow else { return }
                loginTask?.cancel()
                loginTask = nil
                phase = .address
                error = Self.message(reason)
                endPhone(nil)
            } catch {
                guard !Task.isCancelled, phone === flow else { return }
                phase = .address
                self.error = Self.message(error as? TVSetupFailure ?? .connectionLost)
                endPhone(nil)
            }
        }
    }

    /// Tells the phone how it ended (if it should hear it) and closes the connection.
    func endPhone(_ last: TVSetup.Message?) {
        guard let flow = phone else { return }
        phone = nil
        phoneTask?.cancel()
        phoneTask = nil
        Task {
            if let last { await flow.send(last) }
            flow.close()
        }
    }

    static func message(_ failure: TVSetupFailure) -> String {
        switch failure {
        case .phone(let reason): reason
        case .cancelled:
            String(localized: "The set-up was cancelled on your iPhone.", comment: "TV login: the phone cancelled Set Up with iPhone.")
        case .connectionLost: TVSetupWording.connectionLost
        }
    }

    /// Waiting for the user on the phone.
    var phoneChoosing: some View {
        HStack(alignment: .center, spacing: 80) {
            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(.system(size: 200))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 32) {
                Text("Continue on your iPhone", comment: "TV login: title while the user chooses the account on the phone.")
                    .font(.title2.bold())
                VStack(alignment: .leading, spacing: 12) {
                    step(1, Text("Choose your account on your iPhone or iPad.", comment: "TV login (Set Up with iPhone): first step."))
                    step(2, Text("Allow access on your server's page.", comment: "TV login (Set Up with iPhone): second step."))
                    step(3, Text("Your photos appear here.", comment: "TV login: third step."))
                }
                HStack(spacing: 16) {
                    ProgressView()
                    Text("Waiting for your iPhone…", comment: "TV login: shown while the TV waits for the phone.")
                        .foregroundStyle(.secondary)
                }
                Button {
                    cancel()
                } label: {
                    Text("Cancel", comment: "TV login: button")
                }
            }
        }
    }
}

#if DEBUG
    /// Simulators only (`PHOTOS_DEBUG_TV_SETUP=bonjour`): the iPhone simulator's app found over Bonjour, as a list.
    struct TVDebugPhoneBrowser: View {
        let onSelect: (NWEndpoint) -> Void
        @State private var results: [NWEndpoint] = []
        @State private var browser: NWBrowser?

        var body: some View {
            VStack(alignment: .leading, spacing: 24) {
                Text(verbatim: "Debug: iPhone simulators (Bonjour)").font(.title3.bold())
                if results.isEmpty { ProgressView() }
                ForEach(results, id: \.debugDescription) { endpoint in
                    Button(endpoint.debugDescription) { onSelect(endpoint) }
                }
            }
            .padding(60)
            .onAppear {
                let browser = NWBrowser(for: .bonjour(type: TVSetup.debugBonjourType, domain: nil), using: .tcp)
                browser.browseResultsChangedHandler = { found, _ in
                    let endpoints = found.map(\.endpoint)
                    Task { @MainActor in results = endpoints }
                }
                browser.start(queue: .main)
                self.browser = browser
            }
            .onDisappear { browser?.cancel() }
        }
    }
#endif

/// QR codes for the login link (Core Image's generator, medium error correction).
enum TVQRCode {
    static func image(for text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

/// The quiet background of full-screen pages without photos.
struct TVBackdrop: View {
    var body: some View {
        LinearGradient(
            colors: [Color.accentColor.opacity(0.35), Color.clear], startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}
