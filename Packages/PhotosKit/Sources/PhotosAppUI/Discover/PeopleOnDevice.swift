// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosStore
import SwiftUI

/// Below the people found on this device (SPEC §22.3): how far the device has looked, and that it happens on the device.
/// While it is on screen the device keeps looking, and the people are loaded again when more were found.
struct DevicePeopleNote: View {
    /// No people yet: say what will happen instead of showing an empty page.
    let isEmpty: Bool
    /// More photos were looked at: the People screen loads again.
    let reload: () -> Void
    @Environment(SessionModel.self) private var session
    @State private var progress: (scanned: Int, total: Int)?

    var body: some View {
        VStack(spacing: 10) {
            if isEmpty {
                ContentUnavailableView {
                    Label(
                        String(localized: "No people yet", bundle: .module, comment: "People on this device: none found so far."),
                        systemImage: "person.2")
                } description: {
                    Text(
                        "People appear here as this device looks at your photos.", bundle: .module,
                        comment: "People on this device: empty state while faces are still being looked for.")
                }
            }
            if let progress, progress.scanned < progress.total {
                ProgressView(value: Double(progress.scanned), total: Double(max(1, progress.total))) {
                    Text(
                        "Looking for people: \(progress.scanned.formatted()) of \(progress.total.formatted()) photos", bundle: .module,
                        comment: "People on this device: how many photos were looked at for faces so far.")
                }
                .font(.footnote)
                .frame(maxWidth: 420)
            }
            Text(
                "People are found on this device with Apple's Vision, from the previews it has. Nothing is sent anywhere for it.",
                bundle: .module, comment: "People on this device: footnote below the people, when the server has no Recognize."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding()
        // Looks for more people while the screen is open.
        .task { await DevicePeopleIndexing.trickle(session) }
        .task {
            var last = -1
            while !Task.isCancelled {
                if let services = session.services, let value = try? DeviceFaceStore(database: services.database).progress() {
                    progress = (value.scanned, value.total)
                    if last >= 0, value.scanned != last { reload() }
                    last = value.scanned
                }
                try? await Task.sleep(for: .seconds(6))
            }
        }
    }
}
