// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Observation
import PhotosBackup
import PhotosModel

#if os(iOS)
    import UIKit
#endif

/// How much the Nextcloud Files app matters for setting up backup (SPEC §7.18.1 step 2).
public enum FilesAppRelevance: Sendable, Equatable {
    /// Not installed, or nothing of it can be seen: the question is not asked.
    case none
    /// Installed (or it left settings behind), but it uploaded nothing for this account that can be seen.
    case installed
    /// It uploaded photos of this device to this account: the answer "Yes" is chosen in advance.
    case usedForThisAccount
}

/// Whether the screen stays on for the backup (round-3 item 35).
public enum ScreenAwakePolicy {
    /// Only with the option on, while a pass runs, and while the app is in front.
    public static func keepsAwake(option: Bool, isRunning: Bool, isActive: Bool) -> Bool {
        option && isRunning && isActive
    }
}

/// The backup step after the first login (round-3 item 33).
public enum BackupOffer {
    static let offeredKey = "backup.offeredAfterLogin"

    /// Offered once, on iPhone and iPad (the Mac sets up backup in its Settings window; SPEC §7.18), while backup is not
    /// set up.
    @MainActor static func shouldOffer(backup: BackupModel, defaults: UserDefaults) -> Bool {
        #if os(iOS)
            shouldOffer(
                isAvailable: backup.isAvailable,
                isSetUp: backup.settings.isEnabled || backup.settings.filesAppMode == .keepFiles,
                alreadyOffered: defaults.bool(forKey: offeredKey))
        #else
            false
        #endif
    }

    static func shouldOffer(isAvailable: Bool, isSetUp: Bool, alreadyOffered: Bool) -> Bool {
        isAvailable && !isSetUp && !alreadyOffered
    }
}

extension BackupModel {
    // MARK: Files app

    /// Whether to ask about the Files app, and what to choose in advance.
    public var filesAppRelevance: FilesAppRelevance {
        if let account, FilesAppLedger.hasData, !FilesAppLedger.uploadedAssets(accountId: account.id).isEmpty {
            return .usedForThisAccount
        }
        if FilesAppLedger.hasData { return .installed }
        #if os(iOS)
            if Self.filesAppIsInstalled() { return .installed }
        #endif
        return .none
    }

    #if os(iOS)
        /// Whether the Nextcloud Files app is installed (its scheme is listed in LSApplicationQueriesSchemes). iOS 27
        /// deprecates `canOpenURL` in favour of opening the link and handling a failure, but here nothing is opened: only
        /// this check, which has no replacement, is exempt from the deprecation warning.
        @diagnose(DeprecatedDeclaration, as: ignored)
        private static func filesAppIsInstalled() -> Bool {
            guard let url = URL(string: "nextcloud://") else { return false }
            return UIApplication.shared.canOpenURL(url)
        }
    #endif

    // MARK: Counts and lists

    /// How many photos and videos the backup options select on this device (a quick PhotoKit count). Nil without access.
    public func deviceItemCount() async -> Int? {
        guard authorization == .authorized || authorization == .limited else { return nil }
        let settings = settings
        return await Task.detached(priority: .userInitiated) { PhotoLibrarySource.count(settings) }.value
    }

    /// The ledger's per-asset counts: on the server, still to upload.
    public func assetCounts() async -> BackupAssetCounts? {
        try? await prepareEngine()?.assetCounts()
    }

    /// Photos and videos of this device that are not on the server yet, newest first (round-3 item 37).
    public func notBackedUp() async -> [NotBackedUpAsset] {
        guard authorization == .authorized || authorization == .limited, let engine = prepareEngine(),
            let ledger = try? await engine.ledgerByAsset()
        else { return [] }
        let settings = settings
        return await Task.detached(priority: .userInitiated) { BackupDeviceState.notBackedUp(settings: settings, ledger: ledger) }.value
    }

    // MARK: User-started backup (round-3 item 35)

    /// A backup the user started ("Back up", "Back up now"). On iPhone and iPad a first or large one runs as a continued
    /// processing task: it shows the system's progress and goes on when the user leaves the app. Where that is not
    /// possible it runs like any other pass.
    @discardableResult
    public func startBackup(retryFailed: Bool = false) async -> BackupOutcome {
        #if os(iOS)
            if ContinuedBackupPolicy.shouldUse(isFirstPass: status.lastRun == nil, waiting: status.pending + status.failed),
                settings.isEnabled, let outcome = await ContinuedBackup.shared.run(self, retryFailed: retryFailed)
            {
                return outcome
            }
        #endif
        return await runNow(retryFailed: retryFailed)
    }

    // MARK: Keep the screen on (round-3 item 35)

    #if os(iOS)
        /// Turns the idle timer off while the option is on, a pass runs and the app is in front; on again otherwise
        /// (only when it was the backup that turned it off).
        ///
        /// - Parameter isActive: the app's state when it is about to change (it still reads "active" while it resigns).
        func updateIdleTimer(isActive: Bool? = nil) {
            let application = UIApplication.shared
            let keep = ScreenAwakePolicy.keepsAwake(
                option: keepScreenOn, isRunning: status.isRunning, isActive: isActive ?? (application.applicationState == .active))
            if keep, !application.isIdleTimerDisabled {
                application.isIdleTimerDisabled = true
                holdsIdleTimer = true
            } else if !keep, holdsIdleTimer {
                application.isIdleTimerDisabled = false
                holdsIdleTimer = false
            }
        }

        /// Follows the option, the pass and the app's state. Called once; the model lives as long as the app, so the
        /// observers are never removed.
        func observeIdleTimer() {
            let changes = [(UIApplication.didBecomeActiveNotification, true), (UIApplication.willResignActiveNotification, false)]
            for (name, isActive) in changes {
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateIdleTimer(isActive: isActive) }
                }
            }
            trackIdleTimer()
        }

        private func trackIdleTimer() {
            withObservationTracking {
                _ = keepScreenOn
                _ = status.isRunning
            } onChange: { [weak self] in
                Task { @MainActor in
                    self?.updateIdleTimer()
                    self?.trackIdleTimer()
                }
            }
            updateIdleTimer()
        }
    #endif
}
