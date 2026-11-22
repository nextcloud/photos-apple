// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Photos
import PhotosBackup
import PhotosCore
import PhotosModel
import SwiftUI

/// Backup setup, status and options (SPEC §7.18).
struct BackupScreen: View {
    @Environment(SessionModel.self) private var session

    var body: some View {
        let backup = session.backup
        Group {
            if !backup.isAvailable {
                ContentUnavailableView(
                    String(localized: "Backup is not available on this device", bundle: .module), systemImage: "icloud.slash")
            } else if backup.settings.isEnabled || backup.settings.filesAppMode == .keepFiles {
                BackupStatusView()
            } else {
                BackupSetupView()
            }
        }
        .navigationTitle(String(localized: "Backup", bundle: .module))
    }
}

/// First-run flow: explanation, photo access, the Files app question (SPEC §7.18.1).
struct BackupSetupView: View {
    @Environment(SessionModel.self) private var session
    @State private var askingFiles = false

    var body: some View {
        let backup = session.backup
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "icloud.and.arrow.up").font(.system(size: 56)).foregroundStyle(.tint)
                Text("Back up your photos to Nextcloud", bundle: .module).font(.title.bold()).multilineTextAlignment(.center)
                Text(
                    "Nextcloud Photos uploads the photos and videos of this device to \(session.account.hostDisplayName). Originals keep their quality; photos already on your Nextcloud are not uploaded again. Deleting a photo on this device never deletes it on the server.",
                    bundle: .module
                )
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                if backup.authorization == .denied || backup.authorization == .restricted {
                    Label(String(localized: "Allow access to your photos in Settings to use backup.", bundle: .module), systemImage: "lock")
                        .foregroundStyle(.orange)
                }
                Button {
                    Task {
                        if backup.authorization == .notDetermined { await backup.requestAuthorization() }
                        if backup.authorization == .authorized || backup.authorization == .limited { askingFiles = true }
                    }
                } label: {
                    Text("Turn on backup", bundle: .module).frame(maxWidth: 320)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(32)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .confirmationDialog(
            String(localized: "Do you already back up photos with the Nextcloud Files app?", bundle: .module), isPresented: $askingFiles,
            titleVisibility: .visible
        ) {
            Button(String(localized: "No", bundle: .module)) { Task { await backup.enable(mode: .notUsed) } }
            Button(String(localized: "Yes, switch to Nextcloud Photos", bundle: .module)) {
                Task { await backup.enable(mode: .switchedFromFiles) }
            }
            Button(String(localized: "Yes, keep using Files", bundle: .module)) { Task { await backup.enable(mode: .keepFiles) } }
        } message: {
            Text(
                "Photos that Files already uploaded are recognised and not uploaded again. If you switch, turn off auto upload in the Files app afterwards.",
                bundle: .module)
        }
    }
}

/// Status, counts, options and details once backup is set up.
struct BackupStatusView: View {
    @Environment(SessionModel.self) private var session
    @State private var entries: [BackupLedgerEntry] = []

    var body: some View {
        let backup = session.backup
        let status = backup.status
        Form {
            Section {
                HStack(spacing: 14) {
                    statusIcon(status.phase)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusTitle(status.phase)).font(.headline)
                        if let lastRun = status.lastRun {
                            Text("Last checked \(lastRun.formatted(.relative(presentation: .named)))", bundle: .module)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if case .uploading(let done, let total, _) = status.phase {
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                }
                LabeledContent(String(localized: "Uploaded", bundle: .module), value: "\(status.uploaded)")
                LabeledContent(String(localized: "Already on your Nextcloud", bundle: .module), value: "\(status.matched)")
                LabeledContent(String(localized: "Waiting", bundle: .module), value: "\(status.pending)")
                if status.failed > 0 { LabeledContent(String(localized: "Failed", bundle: .module), value: "\(status.failed)") }
                HStack {
                    Button(String(localized: "Back up now", bundle: .module)) { Task { await backup.runNow() } }
                    if isRunning(status.phase) {
                        Button(String(localized: "Pause", bundle: .module)) { backup.cancel() }
                    }
                }
            } footer: {
                if backup.settings.filesAppMode == .keepFiles {
                    Text("The Files app backs up this device. This shows which photos are already on your Nextcloud.", bundle: .module)
                }
            }

            if backup.settings.isEnabled {
                BackupOptions()
            }

            Section(String(localized: "Details", bundle: .module)) {
                ForEach(entries, id: \.self) { entry in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(entry.serverPath.map { ($0 as NSString).lastPathComponent } ?? entry.resourceKind).lineLimit(1)
                            Text(detail(entry)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if entry.state == BackupItemState.matched.rawValue {
                            Button(String(localized: "Upload anyway", bundle: .module)) { Task { await backup.forceUpload(entry) } }
                                .buttonStyle(.borderless)
                                .font(.caption)
                        }
                    }
                }
            }

            Section {
                if backup.settings.isEnabled {
                    Button(String(localized: "Turn off backup", bundle: .module), role: .destructive) { backup.disable() }
                } else {
                    Button(String(localized: "Back up with Nextcloud Photos instead", bundle: .module)) {
                        Task { await backup.enable(mode: .switchedFromFiles) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: status.lastRun) { entries = await backup.entries() }
        .task { if status.lastRun == nil { await backup.runNow() } }
    }

    func isRunning(_ phase: BackupStatus.Phase) -> Bool {
        switch phase {
        case .scanning, .reconciling, .uploading: true
        default: false
        }
    }

    @ViewBuilder func statusIcon(_ phase: BackupStatus.Phase) -> some View {
        switch phase {
        case .upToDate: Image(systemName: "checkmark.icloud.fill").foregroundStyle(.green).font(.title)
        case .failed, .notAuthorized: Image(systemName: "exclamationmark.icloud.fill").foregroundStyle(.red).font(.title)
        case .paused: Image(systemName: "pause.circle.fill").foregroundStyle(.orange).font(.title)
        case .idle: Image(systemName: "icloud").font(.title)
        default: ProgressView()
        }
    }

    func statusTitle(_ phase: BackupStatus.Phase) -> String {
        switch phase {
        case .idle: String(localized: "Backup is on", bundle: .module)
        case .notAuthorized: String(localized: "No access to your photos", bundle: .module)
        case .scanning: String(localized: "Looking for new photos…", bundle: .module)
        case .reconciling(let checked, let total): String(localized: "Checking your Nextcloud… \(checked) of \(total)", bundle: .module)
        case .uploading(let done, let total, _): String(localized: "Uploading \(done + 1) of \(total)", bundle: .module)
        case .paused(let reason): reason
        case .upToDate: String(localized: "Up to date", bundle: .module)
        case .failed(let message): message
        }
    }

    func detail(_ entry: BackupLedgerEntry) -> String {
        switch BackupItemState(rawValue: entry.state) {
        case .uploaded: String(localized: "Backed up", bundle: .module)
        case .matched:
            entry.matchedBy == MatchReason.filesLedger.rawValue
                ? String(localized: "Uploaded by Nextcloud Files", bundle: .module)
                : String(localized: "Already on your Nextcloud", bundle: .module)
        case .failed: entry.lastError ?? String(localized: "Failed", bundle: .module)
        default: String(localized: "Waiting", bundle: .module)
        }
    }
}

/// Backup options (SPEC §7.18.2).
struct BackupOptions: View {
    @Environment(SessionModel.self) private var session

    var body: some View {
        let backup = session.backup
        let settings = backup.settings
        Section(String(localized: "Options", bundle: .module)) {
            TextField(
                String(localized: "Folder", bundle: .module),
                text: Binding(
                    get: { settings.folder }, set: { value in backup.update { $0.folder = value.hasPrefix("/") ? value : "/" + value } }))
            Picker(
                String(localized: "Subfolders", bundle: .module),
                selection: Binding(get: { settings.subfolders }, set: { value in backup.update { $0.subfolders = value } })
            ) {
                Text("None", bundle: .module).tag(BackupSettings.Subfolders.none)
                Text("Year", bundle: .module).tag(BackupSettings.Subfolders.year)
                Text("Year / Month", bundle: .module).tag(BackupSettings.Subfolders.yearMonth)
                Text("Year / Month / Day", bundle: .module).tag(BackupSettings.Subfolders.yearMonthDay)
            }
            Picker(
                String(localized: "File names", bundle: .module),
                selection: Binding(
                    get: { settings.naming == .original ? 0 : 1 },
                    set: { value in backup.update { $0.naming = value == 0 ? .original : .filesApp(typePrefix: false, mask: nil) } })
            ) {
                Text("Original (IMG_1234.HEIC)", bundle: .module).tag(0)
                Text("Like Nextcloud Files", bundle: .module).tag(1)
            }
            Picker(
                String(localized: "Format", bundle: .module),
                selection: Binding(get: { settings.format }, set: { value in backup.update { $0.format = value } })
            ) {
                Text("Originals", bundle: .module).tag(BackupSettings.Format.original)
                Text("Most compatible (JPEG)", bundle: .module).tag(BackupSettings.Format.mostCompatible)
            }
            Picker(
                String(localized: "Edited photos", bundle: .module),
                selection: Binding(get: { settings.edits }, set: { value in backup.update { $0.edits = value } })
            ) {
                Text("Original and edited", bundle: .module).tag(BackupSettings.Edits.originalAndEdited)
                Text("Edited only", bundle: .module).tag(BackupSettings.Edits.editedOnly)
                Text("Original only", bundle: .module).tag(BackupSettings.Edits.originalOnly)
            }
            Toggle(
                String(localized: "Live Photos", bundle: .module),
                isOn: Binding(get: { settings.livePhotos }, set: { value in backup.update { $0.livePhotos = value } }))
            Toggle(
                String(localized: "Photos", bundle: .module),
                isOn: Binding(get: { settings.photos }, set: { value in backup.update { $0.photos = value } }))
            Toggle(
                String(localized: "Videos", bundle: .module),
                isOn: Binding(get: { settings.videos }, set: { value in backup.update { $0.videos = value } }))
        }
        Section(String(localized: "Network and battery", bundle: .module)) {
            Toggle(
                String(localized: "Videos only on Wi-Fi", bundle: .module),
                isOn: Binding(get: { settings.wifiOnlyForVideos }, set: { value in backup.update { $0.wifiOnlyForVideos = value } }))
            Toggle(
                String(localized: "Everything only on Wi-Fi", bundle: .module),
                isOn: Binding(get: { settings.wifiOnly }, set: { value in backup.update { $0.wifiOnly = value } }))
            Toggle(
                String(localized: "Upload in Low Data Mode", bundle: .module),
                isOn: Binding(get: { settings.allowLowDataMode }, set: { value in backup.update { $0.allowLowDataMode = value } }))
            Toggle(
                String(localized: "Pause in Low Power Mode", bundle: .module),
                isOn: Binding(get: { settings.pauseInLowPowerMode }, set: { value in backup.update { $0.pauseInLowPowerMode = value } }))
            Toggle(
                String(localized: "Download originals from iCloud", bundle: .module),
                isOn: Binding(get: { settings.downloadFromICloud }, set: { value in backup.update { $0.downloadFromICloud = value } }))
        }
    }
}
