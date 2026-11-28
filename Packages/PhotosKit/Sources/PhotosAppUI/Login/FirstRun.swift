// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Observation
import Photos
import PhotosBackup
import PhotosCore
import PhotosModel
import SwiftUI

// The first run in three steps (SPEC §22.2): sign in → turn backup on (with the system's photo access question) → done,
// the welcome into the Library. Nothing else is asked on the way: notifications, Advanced features, Clean up, imports, the
// Mac's menu bar extra come later as small tips at the moment they help (`AppTips`). The Mac has no backup step (it sets
// backup up in Settings, a tip points there): sign in → done.

/// The steps of the first run, and how they went.
public enum FirstRun {
    /// The steps of the first run on this device: three where backup is offered after the login (iPhone, iPad), two elsewhere.
    @MainActor static func stepCount(backupAvailable: Bool) -> Int {
        #if os(iOS)
            backupAvailable ? 3 : 2
        #else
            2
        #endif
    }

    /// What the backup step decides after the photo access question: turn backup on at once, ask about the Files app first,
    /// or show how to allow access.
    enum AfterAccess: Equatable {
        case turnOn
        case askAboutFilesApp
        case explainDenied
    }

    static func afterAccess(_ authorization: PHAuthorizationStatus, filesApp: FilesAppRelevance) -> AfterAccess {
        switch authorization {
        case .authorized, .limited: filesApp == .none ? .turnOn : .askAboutFilesApp
        default: .explainDenied
        }
    }
}

/// How the first run's backup step ended, for the done step (the welcome says "Backup is on").
@MainActor
@Observable
final class FirstRunState {
    static let shared = FirstRunState()
    var backupTurnedOn = false
}

/// "1 · 2 · 3" above the first run's steps, so the user sees how far it is (SPEC §22.2).
struct FirstRunProgress: View {
    let step: Int
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(1...max(count, 1), id: \.self) { index in
                Capsule()
                    .fill(index <= step ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary.opacity(0.35)))
                    .frame(width: index == step ? 22 : 8, height: 8)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text("Step \(step) of \(count)", bundle: .module, comment: "VoiceOver: where the first run is, e.g. Step 2 of 3."))
    }
}

/// Step 2 on iPhone and iPad: back up this device's photos. "Turn on backup" asks for access to the photos and turns
/// backup on in the same tap; only when the Nextcloud Files app is there does the set-up's question about it come first
/// (`BackupSetupSteps`). "Not now" goes straight to the Library.
struct FirstRunBackupStep: View {
    @Environment(AppModel.self) private var app
    @Environment(SessionModel.self) private var session
    @Environment(\.openURL) private var openURL
    @State private var asksAboutFilesApp = false
    @State private var working = false
    /// The artwork grows with the text size.
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize = 56.0

    var body: some View {
        Group {
            if asksAboutFilesApp {
                NavigationStack {
                    // "Start backup" or "Not now": the welcome says "Backup is on" once the set-up has turned it on.
                    BackupSetupSteps(isOffer: true) { finish() }
                }
            } else {
                ask
            }
        }
        .background { LivingGradient(palette: .wash).ignoresSafeArea() }
    }

    var denied: Bool {
        session.backup.authorization == .denied || session.backup.authorization == .restricted
    }

    var ask: some View {
        ScrollView {
            VStack(spacing: 20) {
                FirstRunProgress(step: 2, count: FirstRun.stepCount(backupAvailable: true))
                    .padding(.bottom, 8)
                Image(systemName: "icloud.and.arrow.up").font(.system(size: iconSize)).foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(BackupWording.offerTitle)
                    .font(.title.bold()).multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(BackupWording.explanation(host: session.account.hostDisplayName))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                if denied {
                    VStack(spacing: 8) {
                        Label(
                            String(localized: "Allow access to your photos in Settings to use backup.", bundle: .module),
                            systemImage: "lock"
                        )
                        .foregroundStyle(.orange)
                        Button(BackupWording.openSettings) { if let url = BackupWording.photoAccessSettings { openURL(url) } }
                    }
                }
                VStack(spacing: 10) {
                    Button {
                        turnOn()
                    } label: {
                        HStack {
                            if working { ProgressView().controlSize(.small) }
                            Text(BackupWording.backUpPhotos)
                        }
                        .frame(maxWidth: 320)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(working || denied)
                    .accessibilityIdentifier("first-run-backup")
                    Button(BackupWording.notNow) { finish() }
                        .controlSize(.large)
                        .accessibilityIdentifier("first-run-not-now")
                }
                .padding(.top, 8)
            }
            .padding(32)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        // Coming back from Settings with access allowed.
        .onAppear { session.backup.refreshAuthorization() }
    }

    /// The step fades into the welcome.
    func finish() {
        withAnimation(.easeInOut(duration: 0.3)) { app.finishBackupOffer() }
    }

    /// One tap: the system's question about the photos, then backup is on and the welcome leads into the Library.
    func turnOn() {
        let backup = session.backup
        working = true
        Task {
            defer { working = false }
            if backup.authorization == .notDetermined { await backup.requestAuthorization() }
            switch FirstRun.afterAccess(backup.authorization, filesApp: backup.filesAppRelevance) {
            case .turnOn:
                FirstRunState.shared.backupTurnedOn = true
                finish()
                #if DEBUG
                    // UI tests: `PHOTOS_DEBUG_FIRST_RUN_BACKUP_FOLDER=<folder>` backs up into a folder of their own.
                    if let folder = ProcessInfo.processInfo.environment["PHOTOS_DEBUG_FIRST_RUN_BACKUP_FOLDER"] {
                        backup.update { $0.folder = folder }
                    }
                #endif
                await backup.enable(mode: .notUsed)
            case .askAboutFilesApp:
                asksAboutFilesApp = true
            case .explainDenied:
                break
            }
        }
    }
}

extension FirstLaunchWelcome {
    /// The done step's line under the greeting.
    static var backupOnLine: String {
        String(
            localized: "Backup is on. Your photos are on their way to your Nextcloud.", bundle: .module,
            comment: "Under “Welcome, <name>” at the end of the first run, when backup was turned on.")
    }
}
