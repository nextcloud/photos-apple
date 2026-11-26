// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import OSLog
import PhotosDomain
import PhotosMedia
import Synchronization

#if os(iOS)
    import BackgroundTasks
#endif

/// When smart offline, the thumbnails of the whole library and the preparation for the next launch fill the caches in
/// the background (SPEC §15.8.1, §18.3).
///
/// - iPhone and iPad: a `BGProcessingTask` that needs external power and a network; the system starts it while the device
///   charges and is not in use (usually at night on Wi-Fi), and takes the time back when the user picks it up. It runs
///   smart offline, then the library's thumbnails, then the preparation. The preparation also runs after the sync of the
///   app's background refresh (`prepareForNextOpen`, called by the app's refresh task).
/// - Mac: a half-hourly `NSBackgroundActivityScheduler` activity of background quality, deferred while the Mac is busy,
///   hot or in Low Power Mode; it runs the same three.
/// - Vision Pro: only while the app is open (`SessionModel.afterSync`).
///
/// Every pass checks the network itself (no downloads on cellular, hotspots or Low Data Mode) and Low Power Mode.
public enum SmartOfflineScheduling {
    static let taskIdentifier = "com.nextcloud.photos.offline"
    static let logger = Logger(subsystem: "com.nextcloud.photos", category: "smart-offline")

    /// What a background run did.
    public struct Outcome: Sendable, Equatable {
        public var smartOffline = SmartOfflineManager.Outcome()
        public var thumbnails = LibraryThumbnailFiller.Outcome()
        public var preparation = BackgroundPreparation.Outcome()
    }

    /// Something is to be done in the background: smart offline or the library's thumbnails are on. (The preparation
    /// alone is done by the refresh task on iPhone and iPad.)
    static var hasBackgroundWork: Bool {
        SmartOfflineSettings.budget() != .off || LibraryThumbnailSettings.isEnabled()
    }

    @MainActor
    static func run(model: AppModel?, shouldContinue: @escaping @Sendable () -> Bool) async -> Outcome {
        var outcome = Outcome()
        guard let manager = model?.session?.smartOffline else { return outcome }
        let smartOfflineOn = SmartOfflineSettings.budget() != .off
        let thumbnailsOn = LibraryThumbnailSettings.isEnabled()
        let work = Task.detached(priority: .background) { () -> (SmartOfflineManager.Outcome, LibraryThumbnailFiller.Outcome) in
            let smart = smartOfflineOn ? await manager.run(limit: nil, conversions: nil, shouldContinue: shouldContinue) : .init()
            guard !Task.isCancelled, shouldContinue(), thumbnailsOn else { return (smart, .init()) }
            return (smart, await manager.thumbnails.run(shouldContinue: shouldContinue))
        }
        (outcome.smartOffline, outcome.thumbnails) = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        guard !Task.isCancelled, shouldContinue() else { return outcome }
        outcome.preparation = await BackgroundPreparation.run(model: model, shouldContinue: shouldContinue)
        return outcome
    }

    /// Prepares the next launch (SPEC §18.3.2): the app's background refresh calls this after its sync.
    @MainActor public static func prepareForNextOpen(model: AppModel?) async {
        _ = await BackgroundPreparation.run(model: model, shouldContinue: { !Task.isCancelled })
    }

    /// Debug builds: `PHOTOS_DEBUG_FILL_NOW=1` runs the background work once, shortly after launch, without waiting for the
    /// system (checks on the Mac and in the simulator).
    @MainActor static func runNowIfAskedForDebugging(model: @escaping @MainActor () -> AppModel?) {
        #if DEBUG
            guard ProcessInfo.processInfo.environment["PHOTOS_DEBUG_FILL_NOW"] == "1" else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(8))
                log(await run(model: model(), shouldContinue: { true }))
            }
        #endif
    }

    static func log(_ outcome: Outcome) {
        logger.info(
            "background pass: smart offline \(outcome.smartOffline.downloaded) downloaded, \(outcome.smartOffline.converted) converted, \(outcome.smartOffline.remaining) remaining; thumbnails \(outcome.thumbnails.downloaded) downloaded, \(outcome.thumbnails.remaining) remaining; prepared \(outcome.preparation.downloaded)"
        )
    }

    #if os(iOS)
        /// Registers the background task; call once while the app finishes launching.
        @MainActor public static func register(model: @escaping @MainActor () -> AppModel?) {
            LibraryThumbnailSettings.registerDefault()
            runNowIfAskedForDebugging(model: model)
            BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
                let stop = Atomic<Bool>(false)
                let work = Task { @MainActor in await run(model: model(), shouldContinue: { !stop.load(ordering: .relaxed) }) }
                task.expirationHandler = {
                    stop.store(true, ordering: .relaxed)
                    work.cancel()
                }
                Task {
                    log(await work.value)
                    task.setTaskCompleted(success: !stop.load(ordering: .relaxed))
                    await MainActor.run { schedule() }
                }
            }
            schedule()
        }

        /// Asks for the next run (or cancels it when neither smart offline nor the library's thumbnails are on).
        @MainActor public static func schedule() {
            guard hasBackgroundWork else {
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
            LibraryThumbnailSettings.registerDefault()
            runNowIfAskedForDebugging(model: model)
            macModel = model
            schedule()
        }

        /// Starts the repeating activity. It always runs: besides smart offline and the library's thumbnails (each only
        /// when on), it prepares the next time a window is opened (SPEC §18.3.2).
        @MainActor public static func schedule() {
            guard activity == nil else { return }
            let scheduler = NSBackgroundActivityScheduler(identifier: taskIdentifier)
            scheduler.repeats = true
            scheduler.interval = 1800
            scheduler.tolerance = 900
            scheduler.qualityOfService = .background
            let deferral = ContentLabeling.DeferralCheck(scheduler: scheduler)
            scheduler.schedule { completion in
                if deferral.shouldDefer {
                    completion(.deferred)
                    return
                }
                Task { @MainActor in
                    log(await run(model: macModel?(), shouldContinue: { !deferral.shouldDefer }))
                    completion(deferral.shouldDefer ? .deferred : .finished)
                }
            }
            activity = scheduler
        }
    #else
        @MainActor public static func register(model: @escaping @MainActor () -> AppModel?) {
            LibraryThumbnailSettings.registerDefault()
            runNowIfAskedForDebugging(model: model)
        }
        @MainActor public static func schedule() {}
    #endif
}
