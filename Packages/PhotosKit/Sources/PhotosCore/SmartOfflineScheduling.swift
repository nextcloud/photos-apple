// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import OSLog
import PhotosDomain
import Synchronization

#if os(iOS)
    import BackgroundTasks
#endif

/// When smart offline fills up in the background (SPEC §15.8.1).
///
/// - iPhone and iPad: a `BGProcessingTask` that needs external power and a network; the system starts it while the device
///   charges and is not in use (usually at night on Wi-Fi), and takes the time back when the user picks it up.
/// - Mac: an hourly `NSBackgroundActivityScheduler` activity of background quality, deferred while the Mac is busy, hot or
///   in Low Power Mode.
/// - Vision Pro: only while the app is open (`SessionModel.afterSync`).
///
/// Every pass checks the network itself (no downloads on cellular, hotspots or Low Data Mode) and Low Power Mode.
public enum SmartOfflineScheduling {
    static let taskIdentifier = "com.nextcloud.photos.offline"
    static let logger = Logger(subsystem: "com.nextcloud.photos", category: "smart-offline")

    @MainActor
    static func run(model: AppModel?, shouldContinue: @escaping @Sendable () -> Bool) async -> SmartOfflineManager.Outcome {
        guard SmartOfflineSettings.budget() != .off, let manager = model?.session?.smartOffline else {
            return SmartOfflineManager.Outcome()
        }
        let work = Task.detached(priority: .background) { await manager.run(limit: nil, shouldContinue: shouldContinue) }
        return await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }

    #if os(iOS)
        /// Registers the background task; call once while the app finishes launching.
        @MainActor public static func register(model: @escaping @MainActor () -> AppModel?) {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
                let stop = Atomic<Bool>(false)
                let work = Task { @MainActor in await run(model: model(), shouldContinue: { !stop.load(ordering: .relaxed) }) }
                task.expirationHandler = {
                    stop.store(true, ordering: .relaxed)
                    work.cancel()
                }
                Task {
                    let outcome = await work.value
                    logger.info("background pass: \(outcome.downloaded) downloaded, \(outcome.remaining) remaining")
                    task.setTaskCompleted(success: !stop.load(ordering: .relaxed))
                    await MainActor.run { schedule() }
                }
            }
            schedule()
        }

        /// Asks for the next run (or cancels it when smart offline is off).
        @MainActor public static func schedule() {
            guard SmartOfflineSettings.budget() != .off else {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
                return
            }
            let request = BGProcessingTaskRequest(identifier: taskIdentifier)
            request.requiresExternalPower = true
            request.requiresNetworkConnectivity = true
            try? BGTaskScheduler.shared.submit(request)
        }
    #elseif os(macOS)
        @MainActor static var activity: NSBackgroundActivityScheduler?
        @MainActor static var macModel: (@MainActor () -> AppModel?)?

        @MainActor public static func register(model: @escaping @MainActor () -> AppModel?) {
            macModel = model
            schedule()
        }

        /// Starts or stops the repeating activity to match the setting.
        @MainActor public static func schedule() {
            guard SmartOfflineSettings.budget() != .off else {
                activity?.invalidate()
                activity = nil
                return
            }
            guard activity == nil else { return }
            let scheduler = NSBackgroundActivityScheduler(identifier: taskIdentifier)
            scheduler.repeats = true
            scheduler.interval = 3600
            scheduler.tolerance = 1800
            scheduler.qualityOfService = .background
            let deferral = ContentLabeling.DeferralCheck(scheduler: scheduler)
            scheduler.schedule { completion in
                if deferral.shouldDefer {
                    completion(.deferred)
                    return
                }
                Task { @MainActor in
                    let outcome = await run(model: macModel?(), shouldContinue: { !deferral.shouldDefer })
                    logger.info("background pass: \(outcome.downloaded) downloaded, \(outcome.remaining) remaining")
                    completion(deferral.shouldDefer ? .deferred : .finished)
                }
            }
            activity = scheduler
        }
    #else
        @MainActor public static func register(model: @escaping @MainActor () -> AppModel?) {}
        @MainActor public static func schedule() {}
    #endif
}
