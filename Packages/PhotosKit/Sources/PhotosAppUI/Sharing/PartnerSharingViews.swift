// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosNetworking
import PhotosStore
import SwiftUI

/// Settings › Partner sharing (SPEC SH-8): pick folders others shared with you to show in your library, hide or show
/// them, and share your own photos with a partner.
struct PartnerSharingSection: View {
    @Environment(SessionModel.self) private var session
    @State private var sharingOwnFolder: SharingTarget?

    var body: some View {
        if let partners = session.partners {
            Section {
                if !partners.loaded {
                    ProgressView().frame(maxWidth: .infinity)
                } else if partners.candidates.isEmpty && partners.settings.folders.isEmpty {
                    Text("No one has shared a folder with you yet.", bundle: .module).foregroundStyle(.secondary)
                }
                ForEach(partners.candidates) { share in
                    let included = Binding<Bool>(
                        get: { partners.isIncluded(share) }, set: { on in Task { await partners.setIncluded(share, on) } })
                    Toggle(isOn: included) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(share.ownerDisplayName)
                            Text(PartnerTimelineModel.path(of: share)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                // Partner folders whose share is gone or was moved: they can only be removed.
                ForEach(staleFolders(partners)) { folder in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(folder.ownerDisplayName)
                            Text("\(folder.path) is no longer shared with you", bundle: .module).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(String(localized: "Remove", bundle: .module), role: .destructive) { Task { await partners.remove(folder) } }
                            .buttonStyle(.borderless)
                    }
                }
                if partners.hasPartners {
                    Toggle(
                        String(localized: "Show partner photos in the library", bundle: .module),
                        isOn: Binding(get: { partners.settings.showInTimeline }, set: { partners.setShownInTimeline($0) }))
                }
                Button(String(localized: "Share my photos with a partner…", bundle: .module)) {
                    sharingOwnFolder = SharingTarget(path: session.features.userConfig.photosLocation, isFolder: true)
                }
                if partners.working { ProgressView().controlSize(.small) }
                if let error = partners.error { Text(error).foregroundStyle(.red).font(.footnote) }
            } header: {
                Text("Partner sharing", bundle: .module)
            } footer: {
                Text(
                    "Photos in a folder someone shares with you appear in your library, marked with a badge. To share yours, share your photo folder with your partner; they turn it on in their app. Only this device shows them: nothing changes on the server or in the web app.",
                    bundle: .module)
            }
            .disabled(partners.working)
            .task { await partners.loadCandidates() }
            .sheet(item: $sharingOwnFolder) { target in
                if let services = session.services { FileSharingSheet(target: target, api: services.api.sharing) }
            }
        }
    }

    func staleFolders(_ partners: PartnerTimelineModel) -> [PartnerFolder] {
        guard partners.loaded, partners.error == nil else { return [] }
        let shared = Set(partners.candidates.map { PartnerTimelineModel.path(of: $0) })
        return partners.settings.folders.filter { !shared.contains($0.path) }
    }
}

/// The timeline's switch between "with partner photos" and "only mine"; shown when partner folders are set up.
struct PartnerFilterButton: View {
    @Environment(SessionModel.self) private var session

    var body: some View {
        if let partners = session.partners, partners.hasPartners {
            let shown = partners.settings.showInTimeline
            let title: String =
                shown
                ? PlatformWording.title(
                    mac: LocalizedStringResource("Hide Partner Photos", bundle: .module),
                    other: LocalizedStringResource("Hide partner photos", bundle: .module))
                : PlatformWording.title(
                    mac: LocalizedStringResource("Show Partner Photos", bundle: .module),
                    other: LocalizedStringResource("Show partner photos", bundle: .module))
            Button {
                partners.setShownInTimeline(!shown)
            } label: {
                Label(title, systemImage: shown ? "person.2.fill" : "person.2.slash")
            }
            .help(title)
        }
    }
}
