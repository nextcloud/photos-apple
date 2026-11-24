// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import OSLog
import PhotosMedia
import Synchronization

#if os(iOS)
    import BackgroundTasks
    import UIKit
#endif

/// When the photos are indexed for "Show Similar" and the key photos of the zoom levels (`SimilarityIndexer`, SPEC §15.5).
/// On by default: the analysis runs on this device only, on previews it already has, and nothing is uploaded.
///
/// - In the background: on iPhone and iPad a `BGProcessingTask` that requires external power; on the Mac an
///   `NSBackgroundActivityScheduler` activity of background quality, which the system defers while the Mac is busy, hot
///   or in Low Power Mode.
/// - While the Library is on screen, a slow trickle of small batches at background priority picks up the previews the
///   user just scrolled past — but only while the device is not in Low Power Mode, not warm and, on battery, more than a
///   third charged (`Conditions`). Vision Pro only has this trickle.
public enum SimilarIndexing {
    /// `UserDefaults` key of the switch in Settings (default on).
    public static let enabledKey = "similarPhotos"
    static let taskIdentifier = "com.nextcloud.photos.similar"
    static let logger = Logger(subsystem: "com.nextcloud.photos", category: "similar")

    public static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    /// What the device is doing, as far as indexing in the foreground cares.
    public struct Conditions: Sendable, Equatable {
        public var isLowPowerMode: Bool
        public var thermalState: ProcessInfo.ThermalState
        /// 0…1; nil where the platform does not say (Mac, Vision Pro, simulator).
        public var batteryLevel: Float?
        public var isCharging: Bool

        public init(isLowPowerMode: Bool, thermalState: ProcessInfo.ThermalState, batteryLevel: Float?, isCharging: Bool) {
            self.isLowPowerMode = isLowPowerMode
            self.thermalState = thermalState
            self.batteryLevel = batteryLevel
            self.isCharging = isCharging
        }

        /// Whether a foreground batch may run now.
        public var allowsForegroundWork: Bool {
            guard !isLowPowerMode, thermalState == .nominal || thermalState == .fair else { return false }
            if isCharging { return true }
            guard let batteryLevel, batteryLevel >= 0 else { return true }
            return batteryLevel >= 0.35
        }

        @MainActor public static var current: Conditions {
            let info = ProcessInfo.processInfo
            #if os(iOS)
                let device = UIDevice.current
                if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }
                let level: Float? = device.batteryState == .unknown ? nil : device.batteryLevel
                let charging = device.batteryState == .charging || device.batteryState == .full
                return Conditions(
                    isLowPowerMode: info.isLowPowerModeEnabled, thermalState: info.thermalState, batteryLevel: level, isCharging: charging)
            #else
                return Conditions(
                    isLowPowerMode: info.isLowPowerModeEnabled, thermalState: info.thermalState, batteryLevel: nil, isCharging: false)
            #endif
        }
    }

    /// Indexes the cached previews of `services` in small batches while `isWanted` (the Library is on screen) and the
    /// device allows it; returns when everything cached is indexed or the task is cancelled.
    @MainActor public static func trickle(_ services: AccountServices) async {
        // One trickle at a time, however many Library screens are open (iPad sidebar, Mac windows).
        guard isEnabled(), !isTrickling else { return }
        isTrickling = true
        defer { isTrickling = false }
        try? await services.similarity.refresh()
        let indexer = SimilarityIndexer(database: services.database, cache: services.images.cache, index: services.similarity)
        // Starts after the screen has settled; then a batch whenever the conditions allow, with pauses between.
        try? await Task.sleep(for: .seconds(3))
        while !Task.isCancelled {
            let allowed = Conditions.current.allowsForegroundWork && isEnabled()
            if allowed {
                let work = Task.detached(priority: .background) {
                    try await indexer.run(batchSize: 16, pause: .milliseconds(400)) {
                        // Re-checked between photos from the indexing thread: only the cheap process-wide flags.
                        let info = ProcessInfo.processInfo
                        return !info.isLowPowerModeEnabled && info.thermalState.rawValue <= ProcessInfo.ThermalState.fair.rawValue
                    }
                }
                let done = await withTaskCancellationHandler {
                    (try? await work.value) ?? 0
                } onCancel: {
                    work.cancel()
                }
                if done == 0 {
                    // Nothing cached is left: look again later, when more previews may have been loaded.
                    try? await Task.sleep(for: .seconds(180))
                }
            } else {
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    @MainActor static var isTrickling = false

    /// Indexes the cached previews of the active account until `shouldContinue` says stop (background task).
    @MainActor
    static func run(model: AppModel?, shouldContinue: @escaping @Sendable () -> Bool) async -> Int {
        guard isEnabled(), let services = model?.session?.services else { return 0 }
        let indexer = SimilarityIndexer(database: services.database, cache: services.images.cache, index: services.similarity)
        let work = Task.detached(priority: .background) { try await indexer.run(shouldContinue: shouldContinue) }
        return await withTaskCancellationHandler {
            (try? await work.value) ?? 0
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
                    let indexed = await work.value
                    logger.info("background indexing: \(indexed) photos")
                    task.setTaskCompleted(success: !stop.load(ordering: .relaxed))
                    await MainActor.run { schedule() }
                }
            }
            schedule()
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
            Task { try? await BGTaskScheduler.shared.submitTaskRequest(request) }
        }
    #elseif os(macOS)
        @MainActor static var activity: NSBackgroundActivityScheduler?
        @MainActor static var macModel: (@MainActor () -> AppModel?)?

        @MainActor public static func register(model: @escaping @MainActor () -> AppModel?) {
            macModel = model
            schedule()
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
                    let indexed = await run(model: macModel?(), shouldContinue: { !deferral.shouldDefer })
                    logger.info("background indexing: \(indexed) photos")
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
