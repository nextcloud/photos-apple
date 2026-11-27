// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import OSLog
import Photos

#if canImport(UIKit)
    import UIKit
#endif

#if DEBUG
    extension AppModel {
        /// `PHOTOS_DEBUG_BACKUP=<folder>` (UI tours, SPEC §21.1): once an account is on screen, backup is turned on for it
        /// into `folder`. `PHOTOS_DEBUG_BACKUP_HOLD=1`: no pass starts by itself until one is asked for ("Back Up Now").
        /// `PHOTOS_DEBUG_BACKUP_RESET=1`: the ledger is emptied first, so that the device's photos are "not backed up" again
        /// in a container an earlier run backed up from. `PHOTOS_DEBUG_BACKUP_SAMPLES=<n>`: n new photos are added to the
        /// device's library first, taken now, so that they are on no server (the simulator's own sample photos may be
        /// there already, and are then shown once, as the server's).
        func debugEnableBackup(folder: String) async {
            let environment = ProcessInfo.processInfo.environment
            backup.debugHold = environment["PHOTOS_DEBUG_BACKUP_HOLD"] != nil
            // The debug login, or the account an earlier run left, has to be there first.
            for _ in 0..<600 where session == nil || session?.services == nil {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let session, !session.account.isSignedOut else {
                Logger(subsystem: "com.nextcloud.photos", category: "backup").error("debug backup: no account to back up to")
                return
            }
            if environment["PHOTOS_DEBUG_BACKUP_RESET"] != nil { await backup.debugResetLedger() }
            if let samples = environment["PHOTOS_DEBUG_BACKUP_SAMPLES"].flatMap(Int.init), samples > 0 {
                await backup.requestAuthorization()
                await Self.debugAddSamplePhotos(samples)
            }
            if backup.settings.isEnabled, backup.settings.accountId == session.account.id, backup.settings.folder == folder {
                backup.deviceLayer.refresh()
                return
            }
            backup.update { $0.folder = folder }
            await backup.requestAuthorization()
            await backup.enable(mode: .notUsed)
        }
    }

    extension AppModel {
        /// Adds `count` plain photos of different colours to the device's library (debug builds, UI tours). Nonisolated:
        /// PhotoKit runs the change block on a queue of its own, not on the main actor.
        nonisolated static func debugAddSamplePhotos(_ count: Int) async {
            #if canImport(UIKit) && !os(tvOS) && !os(watchOS)
                do {
                    try await PHPhotoLibrary.shared().performChanges {
                        for index in 0..<count {
                            let hue = CGFloat.random(in: 0...1)
                            let image = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 900)).image { context in
                                UIColor(hue: hue, saturation: 0.6, brightness: 0.9, alpha: 1).setFill()
                                context.fill(CGRect(x: 0, y: 0, width: 1200, height: 900))
                                UIColor(hue: hue, saturation: 0.8, brightness: 0.5, alpha: 1).setFill()
                                context.fill(CGRect(x: 100 + 150 * index, y: 300, width: 300, height: 300))
                            }
                            PHAssetChangeRequest.creationRequestForAsset(from: image)
                        }
                    }
                } catch {
                    Logger(subsystem: "com.nextcloud.photos", category: "backup").error(
                        "debug backup: sample photos not added: \(error.localizedDescription, privacy: .public)")
                }
            #endif
        }
    }

    extension BackupModel {
        /// Forgets what the backup uploaded (debug builds, UI tours).
        func debugResetLedger() async {
            try? await prepareEngine()?.reset()
            deviceLayer.refresh()
        }
    }
#endif
