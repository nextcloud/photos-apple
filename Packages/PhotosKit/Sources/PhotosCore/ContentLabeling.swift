// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import OSLog
import PhotosMedia
import Synchronization

#if os(iOS)
    import BackgroundTasks
#endif

/// When the on-device labelling of photos (`ContentLabeler`, SPEC SR-7) runs: only after the user turned it on, and only
/// when the system grants time for maintenance work.
///
/// - iPhone and iPad: a `BGProcessingTask` that requires external power; the system starts it while the device is
///   charging and not in use, and takes the time back when the user picks it up.
/// - Mac: an `NSBackgroundActivityScheduler` activity of background quality, which the system defers while the Mac is
///   busy, on battery in Low Power Mode, or hot.
/// - Vision Pro: not offered.
public enum ContentLabeling {
    /// `UserDefaults` key of the switch in Settings (default off).
    public static let enabledKey = "contentLabeling"
    static let taskIdentifier = "com.nextcloud.photos.labels"
    static let logger = Logger(subsystem: "com.nextcloud.photos", category: "labels")

    /// The platform can run it in the background.
    public static var isAvailable: Bool {
        #if os(iOS) || os(macOS)
            true
        #else
            false
        #endif
    }

    public static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        isAvailable && defaults.bool(forKey: enabledKey)
    }

    /// Labels the cached previews of the active account until `shouldContinue` says stop. Returns how many were labelled.
    @MainActor
    static func run(model: AppModel?, shouldContinue: @escaping @Sendable () -> Bool) async -> Int {
        guard isEnabled(), let services = model?.session?.services else { return 0 }
        let labeler = ContentLabeler(database: services.database, cache: services.images.cache)
        let work = Task.detached(priority: .background) { try await labeler.run(shouldContinue: shouldContinue) }
        return await withTaskCancellationHandler {
            (try? await work.value) ?? 0
        } onCancel: {
            work.cancel()
        }
    }

    /// Debug builds: `PHOTOS_DEBUG_LABEL_NOW=1` labels the cached previews once, shortly after launch, without waiting for
    /// the system (UI checks).
    @MainActor static func runNowIfAskedForDebugging(model: @escaping @MainActor () -> AppModel?) {
        #if DEBUG
            guard ProcessInfo.processInfo.environment["PHOTOS_DEBUG_LABEL_NOW"] == "1" else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(8))
                let labelled = await run(model: model(), shouldContinue: { true })
                logger.info("debug labelling: \(labelled) photos")
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
                    let labelled = await work.value
                    logger.info("background labelling: \(labelled) photos")
                    task.setTaskCompleted(success: !stop.load(ordering: .relaxed))
                    // More may come into the cache; ask again for the next charging period.
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
            try? BGTaskScheduler.shared.submit(request)
        }
    #elseif os(macOS)
        /// The scheduler of the Mac app; created by `schedule()` while the feature is on.
        @MainActor static var activity: NSBackgroundActivityScheduler?

        @MainActor public static func register(model: @escaping @MainActor () -> AppModel?) {
            macModel = model
            schedule()
            runNowIfAskedForDebugging(model: model)
        }

        @MainActor static var macModel: (@MainActor () -> AppModel?)?

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
            let deferral = DeferralCheck(scheduler: scheduler)
            scheduler.schedule { completion in
                if deferral.shouldDefer {
                    completion(.deferred)
                    return
                }
                Task { @MainActor in
                    let labelled = await run(model: macModel?(), shouldContinue: { !deferral.shouldDefer })
                    logger.info("background labelling: \(labelled) photos")
                    completion(deferral.shouldDefer ? .deferred : .finished)
                }
            }
            activity = scheduler
        }

        /// Gives the scheduler's `shouldDefer` to a background task.
        ///
        /// `@unchecked Sendable`: `NSBackgroundActivityScheduler` is not marked Sendable, but `shouldDefer` is documented to
        /// be checked periodically from the work being done, on whatever thread that is.
        struct DeferralCheck: @unchecked Sendable {
            let scheduler: NSBackgroundActivityScheduler
            var shouldDefer: Bool { scheduler.shouldDefer || ProcessInfo.processInfo.isLowPowerModeEnabled }
        }
    #else
        @MainActor public static func register(model: @escaping @MainActor () -> AppModel?) {}
        @MainActor public static func schedule() {}
    #endif
}
