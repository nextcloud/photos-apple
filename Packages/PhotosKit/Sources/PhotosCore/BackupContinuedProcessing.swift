// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import OSLog
import PhotosBackup

#if os(iOS)
    import BackgroundTasks
    import UIKit
#endif

/// When a backup the user starts runs as a continued processing task (round-3 item 35): the first one, or one with a lot
/// to do. A few files go faster than the system's progress panel would appear and disappear.
public enum ContinuedBackupPolicy {
    public static let minimumWaiting = 50

    public static func shouldUse(isFirstPass: Bool, waiting: Int) -> Bool {
        isFirstPass || waiting >= minimumWaiting
    }

    /// The share of the pass that is done, for the system's progress (0…1), always growing within a pass: looking for
    /// photos up to 2 %, checking the server up to 10 %, uploading the rest. Nil when the phase says nothing about it.
    public static func fraction(_ phase: BackupStatus.Phase) -> Double? {
        switch phase {
        case .scanning: 0.01
        case .reconciling(let checked, let total): 0.02 + 0.08 * Double(checked) / Double(max(total, 1))
        case .uploading(let done, let total, _): 0.1 + 0.9 * Double(done) / Double(max(total, 1))
        case .upToDate, .incomplete: 1
        case .idle, .notAuthorized, .paused, .failed: nil
        }
    }

    /// The line under the title of the system's progress panel.
    public static func subtitle(_ phase: BackupStatus.Phase) -> String {
        switch phase {
        case .reconciling(let checked, let total):
            String(
                localized: "Checking your Nextcloud… \(checked) of \(total)", bundle: .module,
                comment: "Subtitle of the system's backup progress panel while the app compares the device's photos with the server.")
        case .uploading(let done, let total, _):
            String(
                localized: "Uploading \(min(done + 1, total)) of \(total)", bundle: .module,
                comment: "Subtitle of the system's backup progress panel: the number of the file being uploaded, of all files.")
        default:
            String(
                localized: "Looking for new photos…", bundle: .module,
                comment: "Subtitle of the system's backup progress panel before the uploads start.")
        }
    }

    static var title: String {
        String(
            localized: "Backing up photos to Nextcloud", bundle: .module,
            comment: "Title of the system's progress panel (Live Activity) while a backup the user started runs in the background.")
    }
}

#if os(iOS)
    /// A `BGContinuedProcessingTask`, which BackgroundTasks does not declare Sendable.
    ///
    /// `@unchecked Sendable`: the task is handed from the scheduler's queue to the main actor once and only used there
    /// (progress, title, completion); BackgroundTasks allows these calls from any thread.
    struct ContinuedTaskHandle: @unchecked Sendable {
        let task: BGContinuedProcessingTask
    }

    /// Runs user-started backups as continued processing tasks (iOS 26+): they go on with system progress when the user
    /// leaves the app, and the user can stop them from that progress. Other background work (refresh and processing
    /// tasks, the short time after leaving the app) must not interrupt such a pass (`BackupModel.isInContinuedTask`).
    @MainActor final class ContinuedBackup {
        static let shared = ContinuedBackup()

        /// A request that was submitted and waits for the system to start it.
        private struct Waiting {
            var backup: BackupModel
            var retryFailed: Bool
            var continuation: CheckedContinuation<BackupOutcome?, Never>
        }

        private var waiting: Waiting?
        private var registered = false
        private let logger = Logger(subsystem: "com.nextcloud.photos", category: "backup")

        /// The identifier: the app's bundle identifier first, as the system requires, and below the wildcard
        /// `$(PRODUCT_BUNDLE_IDENTIFIER).backup.*` of `BGTaskSchedulerPermittedIdentifiers`.
        static var identifier: String? { Bundle.main.bundleIdentifier.map { $0 + ".backup.continued" } }

        /// Runs a pass in a continued processing task and returns how it ended. Nil when the system did not take the task
        /// (not supported, busy, the app is not in front): then the caller runs the pass itself.
        func run(_ backup: BackupModel, retryFailed: Bool) async -> BackupOutcome? {
            guard waiting == nil, !backup.isInContinuedTask, UIApplication.shared.applicationState == .active,
                let identifier = Self.identifier, register(identifier)
            else { return nil }
            let request = BGContinuedProcessingTaskRequest(
                identifier: identifier, title: ContinuedBackupPolicy.title, subtitle: ContinuedBackupPolicy.subtitle(.scanning))
            // Now or not at all: the user is waiting, a queued task would start some time later.
            request.strategy = .fail
            return await withCheckedContinuation { continuation in
                waiting = Waiting(backup: backup, retryFailed: retryFailed, continuation: continuation)
                Task {
                    do {
                        try await BGTaskScheduler.shared.submitTaskRequest(request)
                    } catch {
                        self.logger.notice("backup: no continued processing task: \(error.localizedDescription, privacy: .public)")
                        self.giveUp()
                        return
                    }
                    // Started at once or soon after; if the system keeps it waiting, the app does the work itself.
                    try? await Task.sleep(for: .seconds(10))
                    if self.waiting != nil {
                        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
                        self.giveUp()
                    }
                }
            }
        }

        /// Registers the launch handler once. Continued processing tasks may be registered after launch.
        private func register(_ identifier: String) -> Bool {
            guard !registered else { return true }
            registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
                guard let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                let handle = ContinuedTaskHandle(task: task)
                Task { @MainActor in ContinuedBackup.shared.launched(handle) }
            }
            if !registered { logger.error("backup: the continued processing task identifier is not permitted") }
            return registered
        }

        private func giveUp() {
            guard let waiting else { return }
            self.waiting = nil
            waiting.continuation.resume(returning: nil)
        }

        /// The system started the task: the pass runs, its progress goes to the system's panel, and the user's "Stop"
        /// there interrupts it (it goes on the next time the app is in front).
        private func launched(_ handle: ContinuedTaskHandle) {
            guard let job = waiting else {
                // Given up before the system started it.
                handle.task.setTaskCompleted(success: false)
                return
            }
            waiting = nil
            let backup = job.backup
            backup.isInContinuedTask = true
            logger.notice("backup: the pass runs in a continued processing task")
            handle.task.progress.totalUnitCount = 1000
            handle.task.expirationHandler = {
                Task { @MainActor in await backup.interrupt() }
            }
            let reporter = Task { @MainActor in
                var subtitle = ""
                while !Task.isCancelled {
                    let phase = backup.status.phase
                    if let fraction = ContinuedBackupPolicy.fraction(phase) {
                        let progress = handle.task.progress
                        progress.completedUnitCount = max(progress.completedUnitCount, Int64(fraction * 1000))
                    }
                    let text = ContinuedBackupPolicy.subtitle(phase)
                    if text != subtitle {
                        subtitle = text
                        handle.task.updateTitle(ContinuedBackupPolicy.title, subtitle: text)
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            Task { @MainActor in
                let outcome = await backup.runNow(retryFailed: job.retryFailed)
                reporter.cancel()
                backup.isInContinuedTask = false
                let progress = handle.task.progress
                if outcome.isComplete { progress.completedUnitCount = progress.totalUnitCount }
                handle.task.setTaskCompleted(success: outcome.isComplete)
                self.logger.notice("backup: the continued processing task ended")
                job.continuation.resume(returning: outcome)
            }
        }
    }
#endif
