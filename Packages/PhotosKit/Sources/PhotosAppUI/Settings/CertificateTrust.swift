// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosNetworking
import SwiftUI

extension View {
    /// The dialog that shows a certificate the app does not trust and asks whether to trust it, at login.
    ///
    /// A certificate that changed for an existing account goes through `certificateReview` instead.
    ///
    /// - Parameter changed: the account was logged in with another certificate before.
    func certificateTrustAlert(
        _ problem: Binding<CertificateProblem?>, changed: Bool = false, trust: @escaping @MainActor (CertificateProblem) -> Void
    ) -> some View {
        alert(item: problem) { (problem: CertificateProblem) in
            let summary: String = TrustStore.summary(of: problem.certificate)
            let message: Text =
                changed
                ? Text(
                    "\(problem.host) now presents a different certificate, which is not trusted. Only trust it if you know that the certificate of your server was replaced.\n\n\(summary)",
                    bundle: .module)
                : Text(
                    "The certificate of \(problem.host) is not trusted by this device. Only trust it if you know it belongs to your server.\n\n\(summary)",
                    bundle: .module)
            return Alert(
                title: changed
                    ? Text("The server's certificate changed", bundle: .module) : Text("Untrusted certificate", bundle: .module),
                message: message,
                primaryButton: .destructive(Text("Trust and continue", bundle: .module)) { trust(problem) },
                secondaryButton: .cancel())
        }
    }
}

extension View {
    /// Review of a certificate that changed for an account (grid banner, Settings › Server): the old and the new certificate
    /// side by side, and what can be done about it (`CertificateReviewSheet`). "Log in again" opens the login sheet.
    func certificateReview(_ problem: Binding<CertificateProblem?>, trust: @escaping @MainActor (CertificateProblem) -> Void) -> some View {
        modifier(CertificateReviewPresenter(problem: problem, trust: trust))
    }
}

private struct CertificateReviewPresenter: ViewModifier {
    @Binding var problem: CertificateProblem?
    let trust: @MainActor (CertificateProblem) -> Void
    @State private var relogin = false
    @State private var wantsRelogin = false

    func body(content: Content) -> some View {
        content
            .sheet(
                item: $problem,
                onDismiss: {
                    // One sheet at a time: the login opens once the review has closed.
                    if wantsRelogin {
                        wantsRelogin = false
                        relogin = true
                    }
                }
            ) { (reviewed: CertificateProblem) in
                CertificateReviewSheet(
                    problem: reviewed,
                    trust: {
                        problem = nil
                        trust(reviewed)
                    },
                    relogin: {
                        wantsRelogin = true
                        problem = nil
                    })
            }
            .sheet(isPresented: $relogin) { AddAccountSheet() }
    }
}

/// "The server's certificate changed" (SPEC §8). Never a two-tap trust: nothing has been sent to the server with the new
/// certificate, and nothing is until the user decides here.
///
/// - The server had a certificate the user trusted (self-signed, renewed): old and new fingerprints, and the new one can be
///   trusted after the user confirms that they checked it.
/// - The system trusted the server: a certificate it doesn't trust is what someone intercepting the connection would show,
///   so it can't be accepted here. Logging in again shows it as at a first login.
struct CertificateReviewSheet: View {
    let problem: CertificateProblem
    let trust: @MainActor () -> Void
    let relogin: @MainActor () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var checked = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label {
                        Text(
                            "\(problem.host) presents a different certificate than before. This happens when the server's certificate is replaced, but it is also what someone intercepting your connection would show. Until you decide, nothing is sent to the server.",
                            bundle: .module)
                    } icon: {
                        Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.red)
                    }
                }
                Section(String(localized: "Previous certificate", bundle: .module)) {
                    if let previous = problem.previous {
                        CertificateDetails(certificate: previous)
                    } else {
                        Text("Your device trusted the previous certificate of this server.", bundle: .module)
                            .foregroundStyle(.secondary)
                    }
                }
                Section(String(localized: "New certificate", bundle: .module)) {
                    CertificateDetails(certificate: problem.certificate)
                }
                if problem.canTrustInApp {
                    Section {
                        Toggle(isOn: $checked) {
                            Text(
                                "I compared the new fingerprint with the one my server's administrator gave me, and they match.",
                                bundle: .module)
                        }
                        Button(String(localized: "Trust the new certificate", bundle: .module), role: .destructive) { trust() }
                            .disabled(!checked)
                    } footer: {
                        Text(
                            "If you trust a certificate that isn't your server's, whoever presents it can read your password and your photos.",
                            bundle: .module)
                    }
                } else {
                    Section {
                        Button(String(localized: "Log in again…", bundle: .module)) { relogin() }
                    } footer: {
                        Text(
                            "Your device trusted this server's certificate before, and it doesn't trust the new one. The app doesn't accept such a certificate here. If your server really uses a new certificate that your device doesn't trust, log in again to review it, ideally on a network you trust.",
                            bundle: .module)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(String(localized: "The server's certificate changed", bundle: .module))
            #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Not now", bundle: .module)) { dismiss() }
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 480, minHeight: 520)
        #endif
    }
}

/// Subject and SHA-256 fingerprint of a certificate, selectable so it can be compared.
struct CertificateDetails: View {
    let certificate: Data

    var body: some View {
        if let subject = TrustStore.subject(of: certificate) {
            LabeledContent(String(localized: "Issued to", bundle: .module), value: subject)
        }
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "SHA-256").font(.caption).foregroundStyle(.secondary)
            Text(verbatim: TrustStore.fingerprint(of: certificate))
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}
