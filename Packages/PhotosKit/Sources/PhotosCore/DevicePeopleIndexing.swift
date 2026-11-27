// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import OSLog
import PhotosDomain
import PhotosMedia
import PhotosModel
import PhotosStore
import Synchronization

#if os(iOS)
    import BackgroundTasks
    import UIKit
#endif

/// When People on this device looks for faces (SPEC §22.3): on servers without Recognize, on by default, from the
/// previews the device has, nothing uploaded. Settings › Search turns it off, which deletes what was found.
///
/// Like "Show Similar" (`SimilarIndexing`): a `BGProcessingTask` that requires external power on iPhone and iPad, an
/// `NSBackgroundActivityScheduler` activity of background quality on the Mac (deferred while the Mac is busy, hot or in
/// Low Power Mode), and a slow trickle while the Library is on screen (not in Low Power Mode, not warm, on battery
/// only above a third). The 1024 preview of a photo with faces is asked from the server only on a network that is
/// neither expensive nor constrained. Each run groups what it found and brings the shared names in.
public enum DevicePeopleIndexing {
    /// `UserDefaults` key of the switch in Settings (default on).
    public static let enabledKey = "devicePeople"
    static let taskIdentifier = "com.nextcloud.photos.faces"
    static let logger = Logger(subsystem: "com.nextcloud.photos", category: "faces")

    public static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Whether this account's people come from this device: the server has no Recognize and the switch is on.
    @MainActor public static func isActive(for session: SessionModel?) -> Bool {
        guard let session, session.services != nil else { return false }
        return isEnabled() && !session.features.has(.recognize)
    }

    // MARK: Engines

    /// One engine per account, made when first needed.
    @MainActor static var engines: [AccountID: DevicePeopleEngine] = [:]

    @MainActor static func engine(_ services: AccountServices) -> DevicePeopleEngine {
        if let known = engines[services.account.id] { return known }
        let names = LocalDevicePeopleNames(
            file: services.layout.accountDirectory(services.account.id).appending(path: "device-people.json"))
        let made = DevicePeopleEngine(database: services.database, names: names)
        engines[services.account.id] = made
        return made
    }

    @MainActor static func directory(_ services: AccountServices) -> DevicePeopleDirectory {
        let store = DeviceFaceStore(database: services.database)
        return DevicePeopleDirectory(store: store, engine: engine(services)) {
            try? store.mirrorNamedPeople()
        }
    }

    /// Turns the feature on or off: off deletes every face and person found on this device (the shared names stay).
    @MainActor public static func apply(enabled: Bool, services: AccountServices?) {
        schedule()
        guard !enabled, let services else { return }
        try? DeviceFaceStore(database: services.database).deleteAll()
    }

    // MARK: Runs

    /// Looks for faces, then groups them and brings in the shared names. Returns how many photos were looked at.
    static func pass(
        services: AccountServices, engine: DevicePeopleEngine, batchSize: Int, pause: Duration,
        shouldContinue: @escaping @Sendable () -> Bool
    ) async -> Int {
        let api = services.api
        let indexer = FaceIndexer(
            database: services.database, cache: services.images.cache,
            fetchPreview: { fileId, etag in
                let network = NetworkCost.shared.current
                guard !network.isExpensive, !network.isConstrained else { return nil }
                return try? await api.preview(fileId: fileId, size: FaceAnalysis.analysisBucket, etag: etag)
            })
        let scanned = (try? await indexer.run(batchSize: batchSize, pause: pause, shouldContinue: shouldContinue)) ?? 0
        let store = DeviceFaceStore(database: services.database)
        let finished = ((try? store.candidates(limit: 1)) ?? []).isEmpty
        let grouped = (try? await engine.group(scanFinished: finished, shouldContinue: shouldContinue)) ?? 0
        let applied = (try? await engine.applySharedNames()) ?? false
        if grouped > 0 || applied { try? store.mirrorNamedPeople() }
        return scanned
    }

    /// Looks at the cached previews of `services` in small batches while the Library is on screen and the device allows
    /// it; returns when the task is cancelled.
    @MainActor public static func trickle(_ session: SessionModel) async {
        guard isActive(for: session), let services = session.services, !isTrickling else { return }
        isTrickling = true
        defer { isTrickling = false }
        let engine = engine(services)
        // After the screen and the other on-device work have settled.
        try? await Task.sleep(for: .seconds(8))
        while !Task.isCancelled {
            if isActive(for: session), SimilarIndexing.Conditions.current.allowsForegroundWork {
                let work = Task.detached(priority: .background) {
                    await pass(services: services, engine: engine, batchSize: 12, pause: .milliseconds(500)) {
                        let info = ProcessInfo.processInfo
                        return !info.isLowPowerModeEnabled && info.thermalState.rawValue <= ProcessInfo.ThermalState.fair.rawValue
                    }
                }
                let done = await withTaskCancellationHandler {
                    await work.value
                } onCancel: {
                    work.cancel()
                }
                if done == 0 { try? await Task.sleep(for: .seconds(180)) }
            } else {
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    @MainActor static var isTrickling = false

    /// Looks at the cached previews of the active account until `shouldContinue` says stop (background task).
    @MainActor static func run(model: AppModel?, shouldContinue: @escaping @Sendable () -> Bool) async -> Int {
        guard let session = model?.session, isActive(for: session), let services = session.services else { return 0 }
        let engine = engine(services)
        let work = Task.detached(priority: .background) {
            await pass(services: services, engine: engine, batchSize: 24, pause: .zero, shouldContinue: shouldContinue)
        }
        return await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }

    /// Debug builds: `PHOTOS_DEBUG_FACES_NOW=1` looks at the cached previews once, shortly after launch (checks on the
    /// Mac; with `PHOTOS_DEBUG_FACES_FETCH=1` the 1024 previews of photos with faces are fetched too).
    @MainActor static func runNowIfAskedForDebugging(model: @escaping @MainActor () -> AppModel?) {
        #if DEBUG
            guard ProcessInfo.processInfo.environment["PHOTOS_DEBUG_FACES_NOW"] == "1" else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                let start = ContinuousClock.now
                let scanned = await run(model: model(), shouldContinue: { true })
                logger.info("debug faces: \(scanned) photos in \(ContinuousClock.now - start, privacy: .public)")
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
                    let scanned = await work.value
                    logger.info("background faces: \(scanned) photos")
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
                    let scanned = await run(model: macModel?(), shouldContinue: { !deferral.shouldDefer })
                    logger.info("background faces: \(scanned) photos")
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

extension SessionModel {
    /// Where the People screens get people from: Recognize on the server, else this device (when the switch is on);
    /// nil when neither.
    public var peopleDirectory: (any PeopleDirectory)? {
        guard let services else { return nil }
        if features.has(.recognize) {
            return RecognizePeopleDirectory(api: services.api) { [weak self] in await self?.recognizeKey() }
        }
        guard DevicePeopleIndexing.isEnabled() else { return nil }
        return DevicePeopleIndexing.directory(services)
    }

    /// Whether People is offered at all (sidebar, Collections, links).
    public var offersPeople: Bool {
        features.has(.recognize) || (services != nil && DevicePeopleIndexing.isEnabled())
    }
}
