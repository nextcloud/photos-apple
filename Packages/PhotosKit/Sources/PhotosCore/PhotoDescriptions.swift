// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import OSLog
import PhotosMedia
import PhotosStore
import Synchronization

#if os(iOS)
    import BackgroundTasks
    import UIKit
#endif

/// When photos are described on this device (`PhotoDescriptionIndexer`, SPEC §16.2). On by default: the descriptions are
/// made on this device only, from previews it already has, and nothing is uploaded; Settings › Search turns them off,
/// which deletes them.
///
/// Like "Show Similar" (`SimilarIndexing`): a `BGProcessingTask` that requires external power on iPhone and iPad, an
/// `NSBackgroundActivityScheduler` activity of background quality on the Mac, and while the Library is on screen a slow
/// trickle — which on battery-powered devices only runs while they charge, because the language model is the heaviest
/// part of the app's on-device work. Vision Pro only has the trickle.
public enum PhotoDescriptions {
    /// `UserDefaults` key of the switch in Settings (default on).
    public static let enabledKey = "photoDescriptions"
    static let taskIdentifier = "com.nextcloud.photos.describe"
    static let logger = Logger(subsystem: "com.nextcloud.photos", category: "descriptions")

    public static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Whether a foreground batch may run: what `SimilarIndexing` asks, and on a device that says it has a battery,
    /// that it is charging.
    public static func allowsForegroundWork(_ conditions: SimilarIndexing.Conditions) -> Bool {
        guard conditions.allowsForegroundWork else { return false }
        guard let level = conditions.batteryLevel, level >= 0 else { return true }
        return conditions.isCharging
    }

    /// Turns the feature on or off for an account: off deletes every description.
    @MainActor public static func apply(enabled: Bool, services: AccountServices?) {
        services?.descriptions.isEnabled = enabled
        schedule()
        guard !enabled, let services else { return }
        try? PhotoDescriptionStore(database: services.database).deleteAll()
        services.descriptions.invalidate()
    }

    /// Describes the cached previews of `services` in small batches while the Library is on screen and the device
    /// allows it; returns when the task is cancelled.
    @MainActor public static func trickle(_ services: AccountServices) async {
        guard isEnabled(), !isTrickling else { return }
        isTrickling = true
        defer { isTrickling = false }
        let indexer = PhotoDescriptionIndexer(database: services.database, cache: services.images.cache, lookup: services.descriptions)
        // After the screen and "Show Similar"'s first batch have settled.
        try? await Task.sleep(for: .seconds(12))
        while !Task.isCancelled {
            if isEnabled(), allowsForegroundWork(SimilarIndexing.Conditions.current) {
                let work = Task.detached(priority: .background) {
                    try await indexer.run(batchSize: 8, pause: .seconds(1)) {
                        let info = ProcessInfo.processInfo
                        return !info.isLowPowerModeEnabled && info.thermalState.rawValue <= ProcessInfo.ThermalState.fair.rawValue
                    }
                }
                let done = await withTaskCancellationHandler {
                    (try? await work.value) ?? 0
                } onCancel: {
                    work.cancel()
                }
                // Nothing cached is left: look again later, when more previews may have been loaded.
                if done == 0 { try? await Task.sleep(for: .seconds(240)) }
            } else {
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    @MainActor static var isTrickling = false

    /// Describes the cached previews of the active account until `shouldContinue` says stop (background task).
    @MainActor static func run(model: AppModel?, shouldContinue: @escaping @Sendable () -> Bool) async -> Int {
        guard isEnabled(), let services = model?.session?.services else { return 0 }
        let indexer = PhotoDescriptionIndexer(database: services.database, cache: services.images.cache, lookup: services.descriptions)
        let work = Task.detached(priority: .background) { try await indexer.run(shouldContinue: shouldContinue) }
        return await withTaskCancellationHandler {
            (try? await work.value) ?? 0
        } onCancel: {
            work.cancel()
        }
    }

    /// Debug builds: `PHOTOS_DEBUG_DESCRIBE_NOW=1` describes the cached previews once, shortly after launch (UI checks).
    @MainActor static func runNowIfAskedForDebugging(model: @escaping @MainActor () -> AppModel?) {
        #if DEBUG
            guard ProcessInfo.processInfo.environment["PHOTOS_DEBUG_DESCRIBE_NOW"] == "1" else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                let described = await run(model: model(), shouldContinue: { true })
                logger.info("debug descriptions: \(described) photos")
            }
        #endif
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
                    let described = await work.value
                    logger.info("background descriptions: \(described) photos")
                    task.setTaskCompleted(success: !stop.load(ordering: .relaxed))
                    await MainActor.run { schedule() }
                }
            }
            schedule()
            runNowIfAskedForDebugging(model: model)
        }

        /// Asks for the next run (or cancels it when the feature is off).
        @MainActor public static func schedule() {
            guard isEnabled() else {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
                return
            }
            let request = BGProcessingTaskRequest(identifier: taskIdentifier)
            request.requiresExternalPower = true
            request.requiresNetworkConnectivity = false
            BGTaskScheduler.shared.submitLoggingErrors(request, logger: logger)
        }
    #elseif os(macOS)
        @MainActor static var activity: NSBackgroundActivityScheduler?
        @MainActor static var macModel: (@MainActor () -> AppModel?)?

        @MainActor public static func register(model: @escaping @MainActor () -> AppModel?) {
            macModel = model
            schedule()
            runNowIfAskedForDebugging(model: model)
        }

        /// Starts or stops the repeating activity to match the switch.
        @MainActor public static func schedule() {
            guard isEnabled() else {
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
                    let described = await run(model: macModel?(), shouldContinue: { !deferral.shouldDefer })
                    logger.info("background descriptions: \(described) photos")
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
