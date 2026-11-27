// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Photos
import PhotosBackup
import PhotosCore
import PhotosModel
import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

/// Backup setup, status and options (SPEC §7.18).
struct BackupScreen: View {
    @Environment(SessionModel.self) private var session

    var body: some View {
        let backup = session.backup
        Group {
            if backup.isDisabledByOrganization {
                ContentUnavailableView(
                    ManagedWording.backupDisabledTitle, systemImage: "icloud.slash", description: Text(ManagedWording.backupDisabled))
            } else if !backup.isAvailable {
                ContentUnavailableView(
                    BackupWording.notAvailable, systemImage: "icloud.slash")
            } else if backup.settings.isEnabled || backup.settings.filesAppMode == .keepFiles {
                BackupStatusView()
            } else {
                BackupSetupView()
            }
        }
        .navigationTitle(String(localized: "Backup", bundle: .module))
    }
}

/// First-run flow: explanation, photo access, what is already on the server, the Files app question (SPEC §7.18.1).
struct BackupSetupView: View {
    var body: some View {
        BackupSetupSteps()
    }
}

/// Status, counts, options and details once backup is set up.
struct BackupStatusView: View {
    @Environment(SessionModel.self) private var session
    @State private var entries: [BackupLedgerEntry] = []
    /// The device's photos that are not on the server yet; nil until counted.
    @State private var notBackedUp: [NotBackedUpAsset]?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Free up, opened from the account menu's summary (SPEC §22.1).
    @State private var showsFreeUp = false

    var body: some View {
        let backup = session.backup
        let status = backup.status
        Form {
            Section {
                HStack(spacing: 14) {
                    // The title says what the icon shows.
                    statusIcon(status).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusTitle(status)).font(.headline).rollingNumber(BackupStatusSymbol.progressValue(status.phase))
                        if let blocker = activeBlocker(status) {
                            Text(blockerAdvice(blocker)).font(.subheadline).foregroundStyle(.secondary)
                        } else if case .incomplete = status.phase, let reason = status.lastFailure {
                            // Why the most recent one failed; the details list has each item's reason.
                            Text(reason).font(.subheadline).foregroundStyle(.secondary)
                        }
                        if let lastRun = status.lastRun {
                            Text("Last checked \(lastRun.formatted(.relative(presentation: .named)))", bundle: .module)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.updatesFrequently)
                }
                if case .uploading(let done, let total, _) = status.phase {
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                        .accessibilityLabel(Text("Backup progress", bundle: .module))
                }
                // The counters roll to their new values as the backup goes (SPEC §17.3).
                LabeledContent {
                    Text(status.uploaded.formatted()).rollingNumber(status.uploaded)
                } label: {
                    Text("Uploaded", bundle: .module)
                }
                LabeledContent {
                    Text(status.matched.formatted()).rollingNumber(status.matched)
                } label: {
                    Text("Already on your Nextcloud", bundle: .module)
                }
                LabeledContent {
                    Text(status.pending.formatted()).rollingNumber(status.pending)
                } label: {
                    Text("Waiting", bundle: .module)
                }
                if status.failed > 0 { BackupFailedRow(failed: status.failed, isRunning: isRunning(status.phase)) }
                if status.skipped > 0 { BackupSkippedRow(skipped: status.skipped) }
                if backup.hasLimitedAccess { BackupLimitedAccessRow() }
                HStack {
                    Button(String(localized: "Back up now", bundle: .module)) {
                        // The user asks: items that failed are tried again now instead of after their waiting time. A
                        // large backup goes on with system progress when the user leaves the app (iOS).
                        Task { await backup.startBackup(retryFailed: true) }
                    }
                    if isRunning(status.phase) {
                        Button(String(localized: "Pause", bundle: .module)) { backup.cancel() }
                    }
                }
                // Two buttons in one row of a form: without this a tap on either ran both, and "Back up now" during a
                // pass paused it (found in round 11).
                .buttonStyle(.borderless)
            } footer: {
                if backup.settings.filesAppMode == .keepFiles {
                    Text(BackupWording.filesAppNote)
                } else if backup.isForOtherAccount, let account = backup.account {
                    // Backup belongs to one account and keeps running while another one is shown.
                    Text(
                        "Backup goes to the account \(account.displayName) on \(account.hostDisplayName), not to the account you are looking at.",
                        bundle: .module)
                }
            }

            // Everything is on the server: the offer to free up space on this device (SPEC §22.1).
            FreeUpOfferSection()

            BackupDeviceSection(notBackedUp: notBackedUp)

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
                        .accessibilityElement(children: .combine)
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
        .task(id: status.lastRun) {
            entries = await backup.entries()
            notBackedUp = await backup.notBackedUp()
        }
        .task { if status.lastRun == nil { await backup.runNow() } }
        .task { if backup.freeUpEstimate == nil { await backup.refreshFreeUpEstimate() } }
        .navigationDestination(isPresented: $showsFreeUp) { FreeUpSpaceView() }
        .onChange(of: backup.freeUpRequested, initial: true) { _, requested in
            guard requested else { return }
            backup.freeUpRequested = false
            if backup.canFreeUp { showsFreeUp = true }
        }
        // Back from Settings: the access may be another one now.
        .onChange(of: scenePhase) { _, phase in if phase == .active { backup.refreshAuthorization() } }
    }

    func isRunning(_ phase: BackupStatus.Phase) -> Bool {
        switch phase {
        case .scanning, .reconciling, .uploading: true
        default: false
        }
    }

    /// What stopped the whole backup, while the status still is that failure.
    func activeBlocker(_ status: BackupStatus) -> BackupStatus.Blocker? {
        guard case .failed = status.phase else { return nil }
        return status.blocker
    }

    func blockerSymbol(_ blocker: BackupStatus.Blocker) -> String {
        switch blocker {
        case .insufficientStorage: "externaldrive.badge.exclamationmark"
        case .unauthorized: "person.crop.circle.badge.exclamationmark"
        case .forbidden: "lock.fill"
        case .serverTrust: "lock.trianglebadge.exclamationmark"
        case .deviceStorageFull: "internaldrive"
        }
    }

    func blockerTitle(_ blocker: BackupStatus.Blocker) -> String {
        switch blocker {
        case .insufficientStorage: String(localized: "Your Nextcloud storage is full", bundle: .module)
        case .unauthorized: String(localized: "Log in again to continue the backup", bundle: .module)
        case .forbidden: String(localized: "The server does not allow the upload", bundle: .module)
        case .serverTrust: String(localized: "The connection to your Nextcloud is not trusted", bundle: .module)
        case .deviceStorageFull: BackupWording.deviceFull
        }
    }

    func blockerAdvice(_ blocker: BackupStatus.Blocker) -> String {
        switch blocker {
        case .insufficientStorage:
            String(localized: "Free up space on your Nextcloud or get more storage, then back up again.", bundle: .module)
        case .unauthorized: String(localized: "Your login on this server is no longer valid.", bundle: .module)
        case .forbidden:
            String(localized: "Check that you are allowed to add files to the backup folder, or choose another folder.", bundle: .module)
        case .serverTrust:
            String(
                localized: "The server's certificate changed or is not trusted, or the server asks for a client certificate.",
                bundle: .module)
        case .deviceStorageFull:
            String(
                localized:
                    "A photo or video has to be copied before it is uploaded, and there is no room for that. Free up space, then back up again.",
                bundle: .module)
        }
    }

    @ViewBuilder func statusIcon(_ status: BackupStatus) -> some View {
        if let blocker = activeBlocker(status) {
            Image(systemName: blockerSymbol(blocker)).foregroundStyle(.red).font(.title)
        } else {
            statusIcon(status.phase)
        }
    }

    func statusTitle(_ status: BackupStatus) -> String {
        if let blocker = activeBlocker(status) { return blockerTitle(blocker) }
        return statusTitle(status.phase)
    }

    /// One symbol for every phase, so a change is a symbol replacement: the backup icon breathes while it runs and turns
    /// into the check mark when it is through (SPEC §17.3; a cross-fade and no breathing with Reduce Motion).
    func statusIcon(_ phase: BackupStatus.Phase) -> some View {
        Image(systemName: BackupStatusSymbol.name(phase))
            .foregroundStyle(BackupStatusSymbol.color(phase))
            .font(.title)
            .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
            .symbolEffect(.breathe.pulse.byLayer, options: .repeat(.continuous), isActive: isRunning(phase) && !reduceMotion)
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth, value: BackupStatusSymbol.name(phase))
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
        case .incomplete(let failed): BackupWording.couldNotBeUploaded(failed)
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
        case .skipped: entry.lastError ?? String(localized: "Not backed up", bundle: .module)
        default: String(localized: "Waiting", bundle: .module)
        }
    }
}

/// Items whose upload failed: how many, and a way to try them again now instead of after their waiting time.
struct BackupFailedRow: View {
    @Environment(SessionModel.self) private var session
    let failed: Int
    let isRunning: Bool

    var body: some View {
        LabeledContent {
            Button(String(localized: "Try again", bundle: .module)) {
                let backup: BackupModel = session.backup
                Task { await backup.runNow(retryFailed: true) }
            }
            .disabled(isRunning)
        } label: {
            Label {
                Text(BackupWording.couldNotBeUploaded(failed))
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
    }
}

/// Originals that are only in iCloud while "Download originals from iCloud" is off.
struct BackupSkippedRow: View {
    let skipped: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(String(localized: "Only in iCloud, not backed up", bundle: .module), value: skipped.formatted())
            Text("Turn on “Download originals from iCloud” to back them up.", bundle: .module)
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Shown as long as the app may only see selected photos: the backup is not one of the whole library.
struct BackupLimitedAccessRow: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("Only selected photos are backed up", bundle: .module).font(.headline)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Text(
                "Nextcloud Photos can only see the photos you selected. Allow access to all photos to back up your whole library.",
                bundle: .module
            )
            .font(.subheadline).foregroundStyle(.secondary)
            Button(BackupWording.openSettings) {
                if let url = BackupWording.photoAccessSettings { openURL(url) }
            }
        }
    }
}

/// Backup options (SPEC §7.18.2).
struct BackupOptions: View {
    @Environment(SessionModel.self) private var session

    var body: some View {
        let backup = session.backup
        let settings = backup.settings
        BackupFolderSection()
        Section {
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
            Toggle(
                String(localized: "Include hidden photos", bundle: .module),
                isOn: Binding(get: { settings.includeHidden }, set: { value in backup.update { $0.includeHidden = value } }))
        } header: {
            Text("Options", bundle: .module)
        } footer: {
            if !settings.includeHidden {
                Text("Photos you have hidden in the Photos app are not backed up.", bundle: .module)
            }
        }
        #if os(iOS)
            AlbumMirrorSection()
        #endif
        Section {
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
            #if os(iOS)
                Toggle(
                    String(
                        localized: "Keep screen on while backing up", bundle: .module,
                        comment: "Backup option (iPhone, iPad): the screen does not lock while a backup runs and the app is open."),
                    isOn: Binding(get: { backup.keepScreenOn }, set: { value in backup.keepScreenOn = value }))
                BackupLiveActivityToggle()
            #endif
        } header: {
            Text("Network and battery", bundle: .module)
        } footer: {
            #if os(iOS)
                Text(
                    "Uploads are fastest while Nextcloud Photos is open. With “Keep screen on” the screen stays on only while a backup runs and the app is in front.",
                    bundle: .module, comment: "Footer of the backup options \"Network and battery\" (iPhone, iPad).")
            #endif
        }
    }
}

/// Backup texts that name the device: "this Mac" and its Photos library on macOS, "this device" elsewhere.
enum BackupWording {
    static var notAvailable: String {
        #if os(macOS)
            String(localized: "Backup is not available on this Mac", bundle: .module)
        #else
            String(localized: "Backup is not available on this device", bundle: .module)
        #endif
    }

    static func explanation(host: String) -> String {
        #if os(macOS)
            String(
                localized:
                    "Nextcloud Photos uploads the photos and videos in the Photos library of this Mac to \(host). Originals keep their quality; photos already on your Nextcloud are not uploaded again. Deleting a photo on this Mac never deletes it on the server.",
                bundle: .module)
        #else
            String(
                localized:
                    "Nextcloud Photos uploads the photos and videos of this device to \(host). Originals keep their quality; photos already on your Nextcloud are not uploaded again. Deleting a photo on this device never deletes it on the server.",
                bundle: .module)
        #endif
    }

    static var deviceFull: String {
        #if os(macOS)
            String(localized: "Not enough free space on this Mac", bundle: .module)
        #else
            String(localized: "Not enough free space on this device", bundle: .module)
        #endif
    }

    static func couldNotBeUploaded(_ count: Int) -> String {
        String(localized: "\(count) items could not be uploaded", bundle: .module)
    }

    static var openSettings: String {
        #if os(macOS)
            String(localized: "Open System Settings", bundle: .module)
        #else
            String(localized: "Allow full access in Settings", bundle: .module)
        #endif
    }

    /// Where the user changes the app's access to the photo library.
    static var photoAccessSettings: URL? {
        #if os(macOS)
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")
        #elseif canImport(UIKit)
            URL(string: UIApplication.openSettingsURLString)
        #else
            nil
        #endif
    }

    static var filesAppNote: String {
        #if os(macOS)
            String(localized: "The Files app backs up this Mac. This shows which photos are already on your Nextcloud.", bundle: .module)
        #else
            String(localized: "The Files app backs up this device. This shows which photos are already on your Nextcloud.", bundle: .module)
        #endif
    }
}

/// The backup screen's status symbol for each phase (SPEC §17.3).
enum BackupStatusSymbol {
    static func name(_ phase: BackupStatus.Phase) -> String {
        switch phase {
        case .upToDate: "checkmark.icloud.fill"
        case .failed, .notAuthorized, .incomplete: "exclamationmark.icloud.fill"
        case .paused: "pause.circle.fill"
        case .idle: "icloud"
        case .scanning, .reconciling, .uploading: "arrow.triangle.2.circlepath.icloud"
        }
    }

    static func color(_ phase: BackupStatus.Phase) -> Color {
        switch phase {
        case .upToDate: .green
        case .failed, .notAuthorized: .red
        case .incomplete, .paused: .orange
        case .idle: .primary
        case .scanning, .reconciling, .uploading: .accentColor
        }
    }

    /// The number in the status title that rolls ("Uploading 12 of 400").
    static func progressValue(_ phase: BackupStatus.Phase) -> Int {
        switch phase {
        case .uploading(let done, _, _): done
        case .reconciling(let checked, _): checked
        default: 0
        }
    }
}
