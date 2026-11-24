// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import OSLog

#if os(iOS)
    import BackgroundTasks
    import UIKit
#endif

/// Keeps a long import going when the user leaves the app (SPEC §15.7): a continued processing task on iPhone and iPad,
/// with the system's progress panel and its Stop button (like a user-started backup, `ContinuedBackup`); an activity
/// that keeps the Mac from napping or falling asleep while it runs. Elsewhere the work simply runs.
@MainActor public final class ImportBackgroundRunner {
    public static let shared = ImportBackgroundRunner()

    private let logger = Logger(subsystem: "com.nextcloud.photos", category: "import")

    #if os(iOS)
        /// A `BGContinuedProcessingTask`, which BackgroundTasks does not declare Sendable.
        ///
        /// `@unchecked Sendable`: handed from the scheduler's queue to the main actor once and only used there (progress,
        /// title, completion); BackgroundTasks allows these calls from any thread.
        struct Handle: @unchecked Sendable {
            let task: BGContinuedProcessingTask
        }

        private var registered = false
        private var waiting: CheckedContinuation<Handle?, Never>?

        /// Below the wildcard `$(PRODUCT_BUNDLE_IDENTIFIER).backup.*` of `BGTaskSchedulerPermittedIdentifiers` that the
        /// user-started backup uses: an import is an upload the user started, too.
        static var identifier: String? { Bundle.main.bundleIdentifier.map { $0 + ".backup.import" } }
    #endif

    /// Runs `work`. `status` is asked every second for the share done (0…1) and a line for the system's panel; `stop` is
    /// called when the system or the user ends the background time (the work then stops and can be resumed).
    public func run(
        title: String, status: @escaping @MainActor () -> (fraction: Double, subtitle: String), stop: @escaping @MainActor () -> Void,
        work: @escaping @MainActor () async -> Bool
    ) async {
        #if os(macOS)
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: "Importing photos into Nextcloud")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            _ = await work()
        #elseif os(iOS)
            guard let handle = await continuedTask(title: title, subtitle: status().subtitle) else {
                _ = await work()
                return
            }
            logger.notice("import: runs in a continued processing task")
            handle.task.progress.totalUnitCount = 1000
            handle.task.expirationHandler = {
                Task { @MainActor in stop() }
            }
            let reporter = Task { @MainActor in
                var subtitle = ""
                while !Task.isCancelled {
                    let current = status()
                    let progress = handle.task.progress
                    progress.completedUnitCount = max(progress.completedUnitCount, Int64(min(max(current.fraction, 0), 1) * 1000))
                    if current.subtitle != subtitle {
                        subtitle = current.subtitle
                        handle.task.updateTitle(title, subtitle: subtitle)
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            let complete = await work()
            reporter.cancel()
            if complete { handle.task.progress.completedUnitCount = handle.task.progress.totalUnitCount }
            handle.task.setTaskCompleted(success: complete)
        #else
            _ = await work()
        #endif
    }

    #if os(iOS)
        /// Asks the system for a continued processing task now; nil when it does not start one within a few seconds (not
        /// supported, busy, the app is not in front).
        private func continuedTask(title: String, subtitle: String) async -> Handle? {
            guard waiting == nil, UIApplication.shared.applicationState == .active, let identifier = Self.identifier,
                register(identifier)
            else { return nil }
            let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
            request.strategy = .fail
            return await withCheckedContinuation { continuation in
                waiting = continuation
                Task {
                    do {
                        try await BGTaskScheduler.shared.submitTaskRequest(request)
                    } catch {
                        self.logger.notice("import: no continued processing task: \(error.localizedDescription, privacy: .public)")
                        self.resume(nil)
                        return
                    }
                    try? await Task.sleep(for: .seconds(10))
                    if self.waiting != nil {
                        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
                        self.resume(nil)
                    }
                }
            }
        }

        private func resume(_ handle: Handle?) {
            guard let waiting else {
                handle?.task.setTaskCompleted(success: false)
                return
            }
            self.waiting = nil
            waiting.resume(returning: handle)
        }

        private func register(_ identifier: String) -> Bool {
            guard !registered else { return true }
            registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
                guard let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                let handle = Handle(task: task)
                Task { @MainActor in ImportBackgroundRunner.shared.resume(handle) }
            }
            if !registered { logger.error("import: the continued processing task identifier is not permitted") }
            return registered
        }
    #endif
}
