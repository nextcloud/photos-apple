// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosStore
import SwiftUI

/// Settings › Search (on-device recognition, SPEC SR-7) and Shared albums (activity notifications, SH-9).
struct SearchAndActivitySettings: View {
    @Environment(SessionModel.self) private var session
    @AppStorage(ContentLabeling.enabledKey) private var contentLabeling = false
    @AppStorage(SharedAlbumNotifications.enabledKey) private var sharedAlbumNotifications = true
    @State private var progress: (labeled: Int, total: Int)?

    var body: some View {
        if ContentLabeling.isAvailable {
            Section {
                Toggle(String(localized: "Recognize what's in photos", bundle: .module), isOn: $contentLabeling)
                if contentLabeling, let progress {
                    LabeledContent(
                        String(localized: "Photos looked at", bundle: .module),
                        value: String(
                            localized: "\(progress.labeled.formatted()) of \(progress.total.formatted())", bundle: .module,
                            comment: "Progress of the on-device recognition: photos looked at of all photos"))
                }
            } header: {
                Text("Search", bundle: .module)
            } footer: {
                Text(Self.privacyNote)
            }
            .onChange(of: contentLabeling) { _, enabled in
                ContentLabeling.schedule()
                // Off means gone: what was recognised is deleted, not only hidden.
                if !enabled, let services = session.services { try? LabelStore(database: services.database).deleteVisionLabels() }
                loadProgress()
            }
            .task { loadProgress() }
        }
        Section {
            Toggle(String(localized: "New photos in shared albums", bundle: .module), isOn: $sharedAlbumNotifications)
        } header: {
            Text("Shared albums", bundle: .module)
        } footer: {
            Text(
                "Checked when the app refreshes in the background, so a notification can come hours later. Instant notifications would need your Nextcloud server to send them.",
                bundle: .module)
        }
    }

    func loadProgress() {
        guard let services = session.services else { return }
        progress = try? LabelStore(database: services.database).visionProgress()
    }

    /// What happens to the photos, in the platform's words.
    static var privacyNote: String {
        #if os(macOS)
            String(
                localized:
                    "Your Mac recognizes things like “dog” or “beach” in the previews it has already downloaded, while it is idle, so that search finds them. The labels stay on this Mac and are never uploaded. They are English words. Turning this off deletes them.",
                bundle: .module, comment: "Settings › Search, Mac")
        #else
            String(
                localized:
                    "Things like “dog” or “beach” are recognized in the previews that are already downloaded, only while charging and not in use, so that search finds them. The labels stay in this app and are never uploaded. They are English words. Turning this off deletes them.",
                bundle: .module, comment: "Settings › Search, iPhone and iPad")
        #endif
    }
}
