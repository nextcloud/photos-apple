// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosStore
import SwiftUI

/// Placeholder tiles in the grid's own geometry while nothing is known yet (first load, first sync).
struct GridSkeleton: View {
    let zoomStep: Int
    var showsHeader = true
    var caption: String?
    @State private var dimmed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let geometry: GridGeometry = GridColumns.geometry(width: Double(proxy.size.width), step: zoomStep)
            let side: CGFloat = CGFloat(geometry.side)
            let spacing: CGFloat = CGFloat(geometry.spacing)
            let rows: Int = max(1, Int((proxy.size.height / (side + spacing)).rounded(.up)))
            VStack(alignment: .leading, spacing: spacing) {
                if showsHeader {
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 5).frame(width: 150, height: 20)
                        RoundedRectangle(cornerRadius: 4).frame(width: 90, height: 11)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                }
                ForEach(0..<rows, id: \.self) { _ in
                    HStack(spacing: spacing) {
                        ForEach(0..<geometry.columns, id: \.self) { _ in
                            Rectangle().frame(width: side, height: side)
                        }
                    }
                }
            }
            .foregroundStyle(.quaternary)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .clipped()
        }
        .opacity(dimmed ? 0.45 : 1)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dimmed)
        .onAppear { dimmed = true }
        .overlay(alignment: .bottom) {
            if let caption {
                // The skeleton itself shows that something is on its way: no spinner beside the count.
                HStack(spacing: 8) {
                    Text(caption)
                }
                .font(.footnote)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: .capsule)
                .padding(.bottom, 12)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption ?? String(localized: "Loading…", bundle: .module))
    }
}

/// Shows a freshly created public link.
struct LinkShareSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Anyone with this link can see the selected photos.", bundle: .module).multilineTextAlignment(.center)
                Text(url.absoluteString).font(.footnote).textSelection(.enabled)
                if let qr = QRCode.image(for: url.absoluteString) {
                    Image(decorative: qr, scale: 1).interpolation(.none).resizable().frame(width: 180, height: 180)
                }
                HStack {
                    Button(String(localized: "Copy link", bundle: .module)) { Clipboard.copyLink(url.absoluteString) }
                    ShareLink(item: url)
                }
            }
            .padding()
            .navigationTitle(String(localized: "Link created", bundle: .module))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done", bundle: .module)) { dismiss() }
                }
            }
        }
        .frame(minWidth: 380, minHeight: 420)
    }
}

/// Shown when the account's login is no longer valid.
struct SignedOutView: View {
    @Environment(AppModel.self) private var app
    @Environment(SessionModel.self) private var session
    @State private var relogin = false

    var body: some View {
        ContentUnavailableView {
            Label(String(localized: "Signed out", bundle: .module), systemImage: "person.crop.circle.badge.exclamationmark")
        } description: {
            Self.reason(session)
        } actions: {
            Button(String(localized: "Log in again", bundle: .module)) { relogin = true }
                .buttonStyle(.borderedProminent)
        }
        .sheet(isPresented: $relogin) { AddAccountSheet() }
    }

    /// Why the account is signed out: the server no longer accepts the login, or the keychain has none (it could not
    /// be stored or read) — the latter is not the server's doing and must not be reported as such.
    static func reason(_ session: SessionModel) -> Text {
        let host = session.account.hostDisplayName
        if session.isLoginMissing {
            return Text(
                "Your login for \(host) is missing from the keychain. Please log in again.", bundle: .module,
                comment: """
                    Signed-out screen and Settings when the app password of the account is not in the system keychain (it could \
                    not be saved or read). The placeholder is the server's host name.
                    """)
        }
        return Text("Your login for \(host) is no longer valid. Please log in again.", bundle: .module)
    }
}
