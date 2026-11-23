// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosNetworking
import SwiftUI

extension View {
    /// The dialog that shows a certificate the app does not trust and asks whether to trust it: at login, and for an
    /// account whose server changed its certificate (grid banner, Settings › Server).
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
