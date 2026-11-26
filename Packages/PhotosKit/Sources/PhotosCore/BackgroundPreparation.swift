// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Network
import OSLog
import PhotosDomain
import PhotosMedia
import PhotosModel
import PhotosNetworking
import PhotosStore

#if canImport(UIKit)
    import UIKit
#endif

/// Prepares the app before it is opened (SPEC §18.3.2, §5.5.1): the previews of the first screens of the timeline, of
/// today's memories (covers and first story pages) and of the albums opened recently are put into the disk cache, so the
/// app opens without placeholders.
///
/// Runs after the background refresh's sync on iPhone and iPad (the existing `com.nextcloud.photos.refresh` task, so no
/// new task identifier), in smart offline's processing task, and in the Mac's background activity. Downloads only on an
/// unmetered network and not in Low Power Mode; about 300 previews at most, what is cached already is skipped.
public enum BackgroundPreparation {
    static let logger = Logger(subsystem: "com.nextcloud.photos", category: "preparation")
    /// Downloads at a time; the app is not on screen.
    static let concurrency = 4

    /// What a preparation did.
    public struct Outcome: Sendable, Equatable {
        public var planned = 0
        /// Already on the device.
        public var present = 0
        public var downloaded = 0
        public var failed = 0
        /// Nothing was downloaded: no unmetered network or Low Power Mode.
        public var skipped = false
    }

    // MARK: The timeline's tiles

    /// The timeline's tiles as the grid lays them out at the stored zoom step on this device. Mirrors `GridColumns`
    /// (PhotosAppUI) at its reference width: the bucket a tile needs only changes at ×4 steps, so the real window width
    /// does not matter for the choice.
    @MainActor public static func tiles(_ defaults: UserDefaults = .standard) -> PreparationPlan.Tiles {
        #if os(macOS)
            let (referenceWidth, spacing, defaultStep, screenHeight) = (1056.0, 2.0, 8, 760.0)
        #elseif os(visionOS)
            let (referenceWidth, spacing, defaultStep, screenHeight) = (1000.0, 4.0, 5, 700.0)
        #elseif os(iOS)
            let isPad = UIDevice.current.userInterfaceIdiom == .pad
            let (referenceWidth, spacing, defaultStep, screenHeight) = isPad ? (768.0, 2.0, 5, 1000.0) : (390.0, 1.0, 5, 760.0)
        #else
            let (referenceWidth, spacing, defaultStep, screenHeight) = (1000.0, 4.0, 5, 700.0)
        #endif
        let stored = defaults.integer(forKey: "gridColumns")
        let step = stored > 0 ? stored : defaultStep
        let side = GridZoom.targetSide(step: step, referenceWidth: referenceWidth, spacing: spacing)
        let rows = Int((screenHeight / (side + spacing)).rounded(.up))
        let square = (defaults.object(forKey: "squareTiles") as? Bool) ?? true
        return PreparationPlan.Tiles(side: side, scale: 2, square: square, perScreen: max(1, step * rows))
    }

    // MARK: Running

    /// Prepares the current account of the app (see the type's description).
    @MainActor public static func run(model: AppModel?, shouldContinue: @escaping @Sendable () -> Bool = { true }) async -> Outcome {
        guard let session = model?.session, let services = session.services, !session.isSignedOut else { return Outcome() }
        let tiles = tiles()
        let excluded = session.excludedFolders + (session.partners?.hiddenFolders ?? [])
        let network = await currentNetwork()
        let work = Task.detached(priority: .utility) {
            await prepare(
                services: services, excludedFolders: excluded, tiles: tiles, network: network,
                isLowPowerMode: isLowPowerMode, shouldContinue: shouldContinue)
        }
        let outcome = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        logger.info(
            "prepared: \(outcome.downloaded) downloaded, \(outcome.present) present of \(outcome.planned), \(outcome.failed) failed")
        return outcome
    }

    /// What to prepare for these services now, most important first, without what is cached already.
    static func plan(services: AccountServices, excludedFolders: [String], tiles: PreparationPlan.Tiles, now: Date = Date()) async
        -> (entries: [PreparationPlan.Entry], present: Int)
    {
        let store = CacheFillStore(database: services.database)
        let timeline =
            (try? await store.timelineStart(limit: tiles.perScreen * PreparationPlan.timelineScreens, excludedFolders: excludedFolders))
            ?? []
        let today = (try? await services.library.memories(onlyOnThisDay: true, now: now).onThisDay) ?? []
        let chosen = Array(today.prefix(PreparationPlan.memories))
        let ids = chosen.flatMap { [$0.cover] + $0.items.prefix(PreparationPlan.memoryPhotos) }
        let photos = (try? await store.photos(ids)) ?? [:]
        let memories = chosen.map { memory in
            PreparationPlan.Collection(
                cover: photos[memory.cover], photos: memory.items.prefix(PreparationPlan.memoryPhotos).compactMap { photos[$0] })
        }
        let albums =
            (try? await store.recentAlbums(
                since: now.addingTimeInterval(-PreparationPlan.albumWindow), limit: PreparationPlan.albums, photos: tiles.perScreen))
            ?? []
        let entries = PreparationPlan.entries(timeline: timeline, memories: memories, albums: albums, tiles: tiles)
        let cache = services.images.cache
        let missing = entries.filter { !cache.hasDiskImage(fileId: $0.fileId, etag: $0.etag, bucket: $0.bucket) }
        return (missing, entries.count - missing.count)
    }

    /// Prepares for one account. `network` and `isLowPowerMode` are the conditions now.
    public static func prepare(
        services: AccountServices, excludedFolders: [String], tiles: PreparationPlan.Tiles, network: NetworkConditions,
        isLowPowerMode: Bool, now: Date = Date(), shouldContinue: @escaping @Sendable () -> Bool = { true }
    ) async -> Outcome {
        var outcome = Outcome()
        let (entries, present) = await plan(services: services, excludedFolders: excludedFolders, tiles: tiles, now: now)
        outcome.planned = entries.count + present
        outcome.present = present
        guard !entries.isEmpty else { return outcome }
        guard
            SmartOfflinePolicy.mayDownload(
                isConnected: network.isConnected, isExpensive: network.isExpensive, isConstrained: network.isConstrained,
                isLowPowerMode: isLowPowerMode)
        else {
            outcome.skipped = true
            return outcome
        }
        let cache = services.images.cache
        let api = services.api
        await withTaskGroup(of: Bool.self) { group in
            var next = 0
            var inFlight = 0
            while true {
                while next < entries.count, inFlight < concurrency, shouldContinue(), !Task.isCancelled {
                    let entry = entries[next]
                    next += 1
                    inFlight += 1
                    group.addTask { await download(entry, cache: cache, api: api) }
                }
                guard inFlight > 0, let ok = await group.next() else { break }
                inFlight -= 1
                if ok { outcome.downloaded += 1 } else { outcome.failed += 1 }
            }
        }
        return outcome
    }

    /// Downloads one preview into the disk cache (a lossless one as HEIC), without decoding it.
    static func download(_ entry: PreparationPlan.Entry, cache: PreviewCache, api: PhotosAPI) async -> Bool {
        guard !Task.isCancelled,
            let data = try? await api.preview(fileId: entry.fileId, size: entry.bucket, etag: entry.etag),
            PreviewTranscoding.type(of: data) != nil
        else { return false }
        return cache.storeFile(
            PreviewTranscoding.storage(for: data).data, fileId: entry.fileId, etag: entry.etag, bucket: entry.bucket)
    }

    /// Low Power Mode as the fillers see it. Debug builds: `PHOTOS_DEBUG_FILL_IGNORE_LOW_POWER=1` makes them ignore it, for
    /// checks on a Mac that is in Low Power Mode.
    static var isLowPowerMode: Bool {
        #if DEBUG
            if ProcessInfo.processInfo.environment["PHOTOS_DEBUG_FILL_IGNORE_LOW_POWER"] == "1" { return false }
        #endif
        return ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    /// The network now: the first path a monitor reports (a background task has no monitor running yet).
    static func currentNetwork(timeout: Duration = .seconds(2)) async -> NetworkConditions {
        let monitor = NWPathMonitor()
        defer { monitor.cancel() }
        let stream = AsyncStream<NetworkConditions> { continuation in
            monitor.pathUpdateHandler = { path in
                continuation.yield(NetworkConditions(path))
                continuation.finish()
            }
            monitor.start(queue: DispatchQueue(label: "com.nextcloud.photos.preparation.path"))
        }
        return await withTaskGroup(of: NetworkConditions?.self) { group in
            group.addTask {
                for await conditions in stream { return conditions }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? NetworkConditions(monitor.currentPath)
        }
    }
}
