// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import SwiftUI

/// A public link as every sharing screen shows it: the address (selectable), Copy and the system share button, and
/// optionally a QR code. Copying goes through `Clipboard.copy`, the app's one way onto the pasteboard.
///
/// The one place for showing and copying links, so that rules for links (a warning for plain http, how the pasteboard
/// is used) apply to all of them.
struct SharedLinkView: View {
    let url: URL
    var showsQRCode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(url.absoluteString)
                .font(.footnote)
                .textSelection(.enabled)
                .lineLimit(3)
            if SharedLinkView.isUnencrypted(url) {
                Label {
                    Text("This link uses http: the photos are sent unencrypted.", bundle: .module)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.footnote)
                .foregroundStyle(.orange)
            }
            HStack(spacing: 12) {
                Button {
                    Clipboard.copy(url.absoluteString)
                } label: {
                    Label(String(localized: "Copy link", bundle: .module), systemImage: "doc.on.doc")
                }
                ShareLink(item: url)
            }
            .buttonStyle(.bordered)
            if showsQRCode, let qr = QRCode.image(for: url.absoluteString) {
                Image(decorative: qr, scale: 1).interpolation(.none).resizable().frame(width: 140, height: 140)
                    .accessibilityHidden(true)
            }
        }
    }

    /// Links over plain http travel unencrypted.
    static func isUnencrypted(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "http"
    }
}
