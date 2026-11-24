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
    @AppStorage(SimilarIndexing.enabledKey) private var similarPhotos = true
    @State private var similarProgress: (indexed: Int, total: Int)?

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
        similarSection
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

    /// "Show Similar" and the key photos of the zoom levels (SPEC §15.5): on by default, on this device only.
    var similarSection: some View {
        Section {
            Toggle(String(localized: "Find similar photos", bundle: .module), isOn: $similarPhotos)
            if similarPhotos, let similarProgress {
                LabeledContent(
                    String(localized: "Photos compared", bundle: .module, comment: "Settings: photos indexed for Show Similar."),
                    value: String(
                        localized: "\(similarProgress.indexed.formatted()) of \(similarProgress.total.formatted())", bundle: .module,
                        comment: "Progress of the on-device indexing for Show Similar: photos indexed of all photos"))
            }
        } footer: {
            Text(
                "Compares the previews this device already has, to show similar photos and pick the best shot of a series and the photo that stands for a year or month. Runs while the device is charging or idle; nothing leaves the device. Turning this off deletes what was worked out.",
                bundle: .module)
        }
        .onChange(of: similarPhotos) { _, enabled in
            SimilarIndexing.schedule()
            if !enabled, let services = session.services {
                try? SimilarityStore(database: services.database).deleteAll()
                Task { await services.similarity.reset() }
            }
            loadSimilarProgress()
        }
        .task { loadSimilarProgress() }
    }

    func loadSimilarProgress() {
        guard let services = session.services else { return }
        similarProgress = try? SimilarityStore(database: services.database).progress()
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
