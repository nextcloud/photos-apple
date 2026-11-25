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

/// The backup step after the first login on iPhone and iPad (round-3 item 33), before the notification question.
struct BackupOfferSheet: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        NavigationStack {
            BackupSetupSteps(isOffer: true) { app.finishBackupOffer() }
        }
        .interactiveDismissDisabled()
    }
}

/// Setting up backup (SPEC §7.18.1): what it does, access to the photos, how many are already on the server and how many
/// will be uploaded, the Files app question when the Files app is there, then "Back up". Used after the first login and
/// on the Backup screen (on the Mac: the Backup tab of Settings).
struct BackupSetupSteps: View {
    /// After the first login: a "Not now" button, and the title asks.
    var isOffer = false
    /// Called when the user decided (backup turned on, or "Not now").
    var onDone: () -> Void = {}

    @Environment(SessionModel.self) private var session
    @Environment(\.openURL) private var openURL
    @State private var deviceCount: Int?
    @State private var counts: BackupAssetCounts?
    @State private var relevance: FilesAppRelevance = .none
    @State private var filesChoice: BackupSettings.FilesAppMode = .notUsed
    @State private var starting = false
    /// The artwork grows with the text size.
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize = 56.0

    var hasAccess: Bool {
        let authorization = session.backup.authorization
        return authorization == .authorized || authorization == .limited
    }

    var body: some View {
        let backup = session.backup
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "icloud.and.arrow.up").font(.system(size: iconSize)).foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(isOffer ? BackupWording.offerTitle : BackupWording.setupTitle)
                    .font(.title.bold()).multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(BackupWording.explanation(host: session.account.hostDisplayName))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                if backup.authorization == .denied || backup.authorization == .restricted {
                    VStack(spacing: 8) {
                        Label(
                            String(localized: "Allow access to your photos in Settings to use backup.", bundle: .module),
                            systemImage: "lock"
                        )
                        .foregroundStyle(.orange)
                        Button(BackupWording.openSettings) { if let url = BackupWording.photoAccessSettings { openURL(url) } }
                    }
                } else if hasAccess {
                    BackupFirstCheckSummary(
                        deviceCount: deviceCount, counts: counts, isChecking: backup.isPreviewing, phase: backup.status.phase)
                    if backup.hasLimitedAccess {
                        Text(
                            "Nextcloud Photos can only see the photos you selected. Allow access to all photos to back up your whole library.",
                            bundle: .module
                        )
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    if relevance != .none { filesQuestion }
                }
                VStack(spacing: 10) {
                    Button {
                        primaryAction()
                    } label: {
                        Text(primaryTitle).frame(maxWidth: 320)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(starting || backup.authorization == .denied || backup.authorization == .restricted)
                    if isOffer {
                        Button(BackupWording.notNow) { decline() }
                            .controlSize(.large)
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        // The offer after the first login is a step of the welcome: on a living wash (SPEC §17.6.1).
        .background {
            if isOffer { LivingGradient(palette: .wash).ignoresSafeArea() }
        }
        .task(id: hasAccess) {
            guard hasAccess else { return }
            await firstCheck()
        }
        .onChange(of: relevance) { _, value in
            filesChoice = value == .usedForThisAccount ? .switchedFromFiles : .notUsed
        }
    }

    var primaryTitle: String {
        if !hasAccess { return BackupWording.backUpPhotos }
        return filesChoice == .keepFiles
            ? String(
                localized: "Show backup status", bundle: .module,
                comment: "Button of the backup set-up when the Files app keeps doing the backup: shows which photos are on the server.")
            : String(
                localized: "Start backup", bundle: .module,
                comment: "Main button of the backup set-up, after the app counted what is already on the server.")
    }

    /// The Files app question, only when the Files app is there (SPEC §7.18.1 step 2).
    @ViewBuilder var filesQuestion: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Do you already back up photos with the Nextcloud Files app?", bundle: .module).font(.headline)
            ForEach(Self.filesChoices, id: \.mode) { choice in
                Button {
                    filesChoice = choice.mode
                } label: {
                    HStack {
                        Image(systemName: filesChoice == choice.mode ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(filesChoice == choice.mode ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            .accessibilityHidden(true)
                        Text(choice.title)
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(filesChoice == choice.mode ? .isSelected : [])
            }
            Text(
                "Photos that Files already uploaded are recognised and not uploaded again. If you switch, turn off auto upload in the Files app afterwards.",
                bundle: .module
            )
            .font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: 420, alignment: .leading)
    }

    static var filesChoices: [(mode: BackupSettings.FilesAppMode, title: String)] {
        [
            (.notUsed, String(localized: "No", bundle: .module)),
            (.switchedFromFiles, String(localized: "Yes, switch to Nextcloud Photos", bundle: .module)),
            (.keepFiles, String(localized: "Yes, keep using Files", bundle: .module)),
        ]
    }

    func primaryAction() {
        let backup = session.backup
        Task {
            if backup.authorization == .notDetermined {
                await backup.requestAuthorization()
                return
            }
            guard hasAccess else { return }
            starting = true
            onDone()
            await backup.enable(mode: filesChoice)
        }
    }

    func decline() {
        let backup = session.backup
        Task { await backup.cancelPreview() }
        onDone()
    }

    /// Counts the device's photos at once, then checks the server and shows the numbers as they come.
    func firstCheck() async {
        let backup = session.backup
        relevance = backup.filesAppRelevance
        deviceCount = await backup.deviceItemCount()
        guard !backup.settings.isEnabled else { return }
        async let check: Void = backup.preview(includeFilesApp: relevance != .none)
        // Also follows a check that an earlier appearance of this step started.
        repeat {
            counts = await backup.assetCounts()
            try? await Task.sleep(for: .seconds(1))
        } while backup.isPreviewing && !Task.isCancelled
        await check
        counts = await backup.assetCounts()
    }
}

/// "X photos and videos are already on your Nextcloud, Y will be uploaded", and the progress of the check.
struct BackupFirstCheckSummary: View {
    let deviceCount: Int?
    let counts: BackupAssetCounts?
    let isChecking: Bool
    let phase: BackupStatus.Phase

    var body: some View {
        VStack(spacing: 10) {
            if let deviceCount {
                Text(BackupWording.onThisDevice(deviceCount)).font(.headline)
            }
            if isChecking {
                VStack(spacing: 6) {
                    if case .reconciling(let checked, let total) = phase {
                        ProgressView(value: Double(checked), total: Double(max(total, 1)))
                            .frame(maxWidth: 320)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(
                        "Checking which are already on your Nextcloud…", bundle: .module,
                        comment: "Shown while the backup set-up compares the device's photos with the server.")
                    if let counts, counts.onServer > 0 {
                        Text(
                            "\(counts.onServer) found so far", bundle: .module,
                            comment:
                                "Backup set-up, while it checks: how many of the device's photos and videos were found on the server so far."
                        )
                    }
                }
                .font(.callout).foregroundStyle(.secondary)
            } else if let counts, counts.onServer + counts.toUpload > 0 {
                VStack(spacing: 4) {
                    Text(
                        "\(counts.onServer) already on your Nextcloud", bundle: .module,
                        comment: "Backup set-up, after the check: how many of the device's photos and videos are already on the server.")
                    Text(
                        "\(counts.toUpload) to upload", bundle: .module,
                        comment: "Backup set-up, after the check: how many of the device's photos and videos will be uploaded."
                    )
                    .bold()
                }
            }
        }
        .multilineTextAlignment(.center)
        .padding()
        .frame(maxWidth: 420)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// The words for this device and the backup offer.
extension BackupWording {
    static var notNow: String {
        String(localized: "Not now", bundle: .module, comment: "Button that skips the backup offer after the first login.")
    }

    /// The first button of the set-up: asks for access to the photos, then shows what is already on the server.
    static var backUpPhotos: String {
        String(localized: "Turn on backup", bundle: .module)
    }

    static var setupTitle: String {
        String(localized: "Back up your photos to Nextcloud", bundle: .module)
    }

    static var offerTitle: String {
        #if os(macOS)
            // The Mac sets up backup in its Settings window only; there is no offer after the login.
            setupTitle
        #else
            if UIDevice.current.userInterfaceIdiom == .pad {
                String(
                    localized: "Back up the photos of this iPad?", bundle: .module,
                    comment: "Title of the backup offer after the first login (iPad).")
            } else {
                String(
                    localized: "Back up the photos of this iPhone?", bundle: .module,
                    comment: "Title of the backup offer after the first login (iPhone).")
            }
        #endif
    }

    static func onThisDevice(_ count: Int) -> String {
        #if os(macOS)
            String(
                localized: "\(count) photos and videos in the Photos library of this Mac", bundle: .module,
                comment: "Backup set-up (macOS): how many photos and videos the backup would cover.")
        #else
            if UIDevice.current.userInterfaceIdiom == .pad {
                String(
                    localized: "\(count) photos and videos on this iPad", bundle: .module,
                    comment: "Backup set-up (iPad): how many photos and videos the backup would cover.")
            } else {
                String(
                    localized: "\(count) photos and videos on this iPhone", bundle: .module,
                    comment: "Backup set-up (iPhone): how many photos and videos the backup would cover.")
            }
        #endif
    }
}
