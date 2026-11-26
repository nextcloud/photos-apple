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
import Synchronization

/// The smart offline settings (SPEC §15.8.1). Per device: the same budget for every account.
public enum SmartOfflineSettings {
    public static let budgetKey = "smartOfflineBudget"
    public static let qualityKey = "smartOfflineQuality"

    public static func budget(_ defaults: UserDefaults = .standard) -> SmartOfflineBudget {
        defaults.string(forKey: budgetKey).flatMap(SmartOfflineBudget.init(rawValue:)) ?? .default
    }

    public static func quality(_ defaults: UserDefaults = .standard) -> SmartOfflineQuality {
        defaults.string(forKey: qualityKey).flatMap(SmartOfflineQuality.init(rawValue:)) ?? .screen
    }
}

/// Smart offline (SPEC §15.8.1): keeps the photos the user most likely wants without network — the last months,
/// favourites, the coming days' "On this day" and albums opened recently — within a storage budget.
///
/// `SmartOfflinePolicy` decides what is wanted; this actor carries it out. Photos are kept as previews of screen size
/// (`SmartOfflinePolicy.previewSize`) or, when chosen, as originals (videos always as previews). They live in the
/// account's SmartOffline folder, outside the caches, so a cache trim never removes them; a file's modification date is
/// its "last used" for the LRU eviction and is set when the image pipeline reads it (at most once a day).
///
/// Previews come from the server as JPEG, or as PNG for PNG files; a PNG preview is stored as HEIC, a tenth of its size
/// (`PreviewTranscoding`, SPEC §18.3.3). PNG previews kept by an earlier version are converted in later passes, a few at
/// a time and without the network; JPEG previews are kept as they are.
///
/// Removing is done in every pass. Downloading needs an unmetered network (Wi-Fi, Ethernet; not cellular, a hotspot or Low
/// Data Mode) and no Low Power Mode; in the foreground a pass downloads at most `foregroundLimit` files, the rest is left to
/// the background task that runs while the device charges (`SmartOfflineScheduling`).
public actor SmartOfflineManager {
    let services: AccountServices
    let store: SmartOfflineStore
    public nonisolated let directory: URL
    /// Thumbnails of the whole library (SPEC §18.3.1); smart offline's scheduling runs it too.
    public nonisolated let thumbnails: LibraryThumbnailFiller
    private let settings: @Sendable () -> (budget: SmartOfflineBudget, quality: SmartOfflineQuality)
    private let excludedFolders: @Sendable () async -> [String]
    private let logger = Logger(subsystem: "com.nextcloud.photos", category: "smart-offline")
    private let pathMonitor = NWPathMonitor()
    private var running: Task<Outcome, Never>?
    private var isShutDown = false
    /// What is kept, by file id: read by the image pipeline on every load, so it is in memory.
    private let index: Mutex<[FileID: Entry]>
    /// Files whose "last used" was set in this process.
    private let touched = Mutex<Set<FileID>>([])
    /// Kept previews found not worth converting to HEIC in this process (JPEG): not looked at again.
    private var conversionChecked = Set<FileID>()
    /// Tests set the conditions instead of reading the real ones.
    var networkOverride: NetworkConditions?
    var lowPowerOverride: Bool?

    /// Files a pass downloads in the foreground at most (the background task does the rest while the device charges).
    public static let foregroundLimit = 150
    /// Kept PNG previews a foreground pass converts to HEIC at most (about 0.3 s each for 2048 px).
    public static let foregroundConversions = 20

    struct Entry: Sendable, Equatable {
        var etag: String
        var file: String
        var quality: SmartOfflineQuality
    }

    /// What a pass did.
    public struct Outcome: Sendable, Equatable {
        public var downloaded = 0
        public var evicted = 0
        /// Files that are wanted but not downloaded yet (no Wi-Fi, Low Power Mode, the limit, the budget's real sizes).
        public var remaining = 0
        /// Kept previews converted to HEIC.
        public var converted = 0
    }

    public init(
        services: AccountServices,
        settings: @escaping @Sendable () -> (budget: SmartOfflineBudget, quality: SmartOfflineQuality) = {
            (SmartOfflineSettings.budget(), SmartOfflineSettings.quality())
        },
        excludedFolders: @escaping @Sendable () async -> [String] = { [] }
    ) {
        self.services = services
        self.store = SmartOfflineStore(database: services.database)
        self.settings = settings
        self.excludedFolders = excludedFolders
        directory = services.layout.accountDirectory(services.account.id).appending(path: "SmartOffline")
        thumbnails = LibraryThumbnailFiller(services: services, excludedFolders: excludedFolders)
        OfflineManager.prepare(directory)
        let rows = (try? SmartOfflineStore(database: services.database).kept()) ?? []
        index = Mutex(
            Dictionary(
                rows.map { ($0.fileId, Entry(etag: $0.etag, file: $0.localPath, quality: $0.quality)) }, uniquingKeysWith: { a, _ in a }))
        pathMonitor.start(queue: DispatchQueue(label: "com.nextcloud.photos.smart-offline.path"))
    }

    // MARK: Lookups (any thread)

    /// A kept preview of at least `bucket` pixels for this version of the file.
    public nonisolated func localPreview(fileId: FileID, etag: String, bucket: Int) -> URL? {
        guard bucket <= SmartOfflinePolicy.previewSize,
            let entry = index.withLock({ $0[fileId] }), entry.etag == etag, entry.quality == .screen
        else { return nil }
        return use(fileId, file: entry.file)
    }

    /// The kept original of this version of the file.
    public nonisolated func localOriginal(fileId: FileID, etag: String) -> URL? {
        guard let entry = index.withLock({ $0[fileId] }), entry.etag == etag, entry.quality == .original else { return nil }
        return use(fileId, file: entry.file)
    }

    /// The photo is kept (whatever the quality).
    public nonisolated func isKept(_ fileId: FileID) -> Bool { index.withLock { $0[fileId] != nil } }

    /// How many photos are kept.
    public nonisolated var keptCount: Int { index.withLock { $0.count } }

    /// The file, after noting that it was used (its modification date, at most once a day and once per run).
    private nonisolated func use(_ fileId: FileID, file: String) -> URL? {
        let url = directory.appending(path: file)
        let path = url.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        if touched.withLock({ $0.insert(fileId).inserted }) {
            let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            if modified.map({ Date().timeIntervalSince($0) > 86_400 }) ?? true {
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path)
            }
        }
        return url
    }

    // MARK: Conditions

    var network: NetworkConditions { networkOverride ?? NetworkConditions(pathMonitor.currentPath) }
    var isLowPowerMode: Bool { lowPowerOverride ?? BackgroundPreparation.isLowPowerMode }

    func setConditions(network: NetworkConditions?, lowPower: Bool?) {
        networkOverride = network
        lowPowerOverride = lowPower
    }

    public var mayDownload: Bool {
        let network = network
        return SmartOfflinePolicy.mayDownload(
            isConnected: network.isConnected, isExpensive: network.isExpensive, isConstrained: network.isConstrained,
            isLowPowerMode: isLowPowerMode)
    }

    // MARK: Album views

    public func noteAlbumViewed(_ albumId: String) {
        try? store.noteAlbumViewed(albumId)
    }

    // MARK: Passes

    /// Runs a pass: removes what is no longer wanted or does not fit, then downloads what is missing, best first.
    /// A call while a pass runs waits for that pass.
    ///
    /// - Parameters:
    ///   - limit: downloads at most this many files (nil: no limit).
    ///   - shouldContinue: checked before every download; false stops the pass (the background time is over).
    ///   - conversions: converts at most this many kept PNG previews to HEIC (nil: no limit).
    @discardableResult
    public func run(
        limit: Int? = foregroundLimit, conversions: Int? = foregroundConversions, shouldContinue: @escaping @Sendable () -> Bool = { true }
    ) async -> Outcome {
        guard !isShutDown else { return Outcome() }
        if let running { return await running.value }
        let task = Task { await self.pass(limit: limit, conversions: conversions, shouldContinue: shouldContinue) }
        running = task
        let outcome = await task.value
        running = nil
        return outcome
    }

    private func pass(limit: Int?, conversions: Int?, shouldContinue: @escaping @Sendable () -> Bool) async -> Outcome {
        var outcome = Outcome()
        let (budget, quality) = settings()
        let now = Date()
        do {
            let excluded = await excludedFolders()
            let candidates = budget == .off ? [] : try await store.candidates(now: now, excludedFolders: excluded)
            let ranked = SmartOfflinePolicy.rank(candidates, now: now)
            let rows = try store.kept()
            let present = try await store.present(rows.map(\.fileId), excludedFolders: excluded)
            let kept = rows.map { row in
                SmartOfflineKept(
                    fileId: row.fileId, etag: row.etag, bytes: row.bytes, lastUsed: lastUsed(row), quality: row.quality)
            }
            let previews = rows.filter { $0.quality == .screen && $0.bytes > 0 }
            let average =
                previews.count >= 10 ? previews.reduce(0) { $0 + $1.bytes } / Int64(previews.count) : SmartOfflinePolicy.defaultPreviewBytes
            let plan = SmartOfflinePolicy.plan(
                ranked: ranked, kept: kept, present: present, budget: budget.bytes, quality: quality, previewBytes: average)

            // Removing first: it makes the room the downloads need, and it needs no network.
            let byId = Dictionary(rows.map { ($0.fileId, $0) }, uniquingKeysWith: { a, _ in a })
            for fileId in plan.evictions {
                if let row = byId[fileId] { try? FileManager.default.removeItem(at: directory.appending(path: row.localPath)) }
            }
            try await store.delete(plan.evictions)
            index.withLock { index in for fileId in plan.evictions { index[fileId] = nil } }
            outcome.evicted = plan.evictions.count
            let reasons = Dictionary(
                ranked.filter { plan.wanted.contains($0.fileId) }.map { ($0.fileId, $0.reason) }, uniquingKeysWith: { a, _ in a })
            try await store.updateReasons(reasons)

            var used = rows.filter { !plan.evictions.contains($0.fileId) }.reduce(0) { $0 + $1.bytes }
            // Needs no network: before the downloads, so that it happens offline too.
            let evicted = Set(plan.evictions)
            let (converted, saved) = await convertKept(
                rows.filter { !evicted.contains($0.fileId) }, limit: conversions, shouldContinue: shouldContinue)
            outcome.converted = converted
            used -= saved
            let downloads = plan.downloads
            outcome.remaining = downloads.count
            guard !downloads.isEmpty, mayDownload else { return outcome }
            let items = try await services.library.fetchItems(downloads.map(\.fileId))
            for entry in downloads {
                if let limit, outcome.downloaded >= limit { break }
                guard shouldContinue(), !Task.isCancelled, !isShutDown, mayDownload else { break }
                guard let item = items[entry.fileId] else { continue }
                let itemQuality = SmartOfflinePolicy.quality(of: item.kind, chosen: quality)
                guard let (file, bytes) = await download(item, quality: itemQuality) else { continue }
                if used + bytes > budget.bytes {
                    // Real sizes are larger than estimated: the budget is reached.
                    try? FileManager.default.removeItem(at: directory.appending(path: file))
                    break
                }
                try await store.insert(
                    SmartOfflineStore.Row(
                        fileId: item.fileId, etag: item.etag, quality: itemQuality, localPath: file, bytes: bytes, keptAt: Date(),
                        reason: entry.reason))
                index.withLock { $0[item.fileId] = Entry(etag: item.etag, file: file, quality: itemQuality) }
                used += bytes
                outcome.downloaded += 1
                outcome.remaining -= 1
            }
        } catch {
            logger.error("smart offline pass failed: \(error.localizedDescription, privacy: .public)")
        }
        return outcome
    }

    /// When a kept file was last used: its modification date (set when it is read), else when it was downloaded.
    nonisolated func lastUsed(_ row: SmartOfflineStore.Row) -> Date {
        let path = directory.appending(path: row.localPath).path(percentEncoded: false)
        return ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date) ?? row.keptAt
    }

    /// Downloads a preview or the original into the folder; returns the file name and its size.
    private func download(_ item: MediaItem, quality: SmartOfflineQuality) async -> (String, Int64)? {
        do {
            let name: String
            let target: URL
            switch quality {
            case .screen:
                let data = try await services.api.preview(fileId: item.fileId, size: SmartOfflinePolicy.previewSize, etag: item.etag)
                let stored = PreviewTranscoding.storage(for: data)
                name = Self.previewName(item.fileId, etag: item.etag, heic: stored.isHEIC)
                target = directory.appending(path: name)
                try stored.data.write(to: target, options: .atomic)
            case .original:
                let ext = (item.name as NSString).pathExtension
                name = "\(item.fileId)-\(CacheFileName.etag(item.etag)).\(ext.isEmpty ? "bin" : ext)"
                target = directory.appending(path: name)
                let (file, _) = try await services.dav.download(services.originalURL(for: item))
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: file, to: target)
            }
            let size = Int64((try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            return (name, size)
        } catch {
            if !Task.isCancelled { logger.debug("smart offline download failed: \(error.localizedDescription, privacy: .public)") }
            return nil
        }
    }

    /// The file name of a kept preview.
    static func previewName(_ fileId: FileID, etag: String, heic: Bool) -> String {
        "\(fileId)-\(CacheFileName.etag(etag))-\(SmartOfflinePolicy.previewSize).\(heic ? PreviewTranscoding.heicExtension : "jpg")"
    }

    /// Converts kept previews that are worth storing as HEIC (PNG previews kept before, SPEC §18.3.3): the HEIC file is
    /// written and recorded before the old one is removed, so a lookup in between finds one or the other. Returns how
    /// many were converted and the bytes saved.
    private func convertKept(_ rows: [SmartOfflineStore.Row], limit: Int?, shouldContinue: @escaping @Sendable () -> Bool) async
        -> (Int, Int64)
    {
        guard PreviewTranscoding.canWriteHEIC else { return (0, 0) }
        var converted = 0
        var saved: Int64 = 0
        for row in rows
        where row.quality == .screen && !row.localPath.hasSuffix(".\(PreviewTranscoding.heicExtension)")
            && !conversionChecked.contains(row.fileId)
        {
            if let limit, converted >= limit { break }
            guard shouldContinue(), !Task.isCancelled, !isShutDown else { break }
            let old = directory.appending(path: row.localPath)
            let work = Task.detached(priority: .utility) { () -> Data? in
                // The type comes from the file's first bytes; only a preview worth converting is read whole.
                guard PreviewTranscoding.shouldStoreAsHEIC(PreviewTranscoding.type(of: old)), let data = try? Data(contentsOf: old) else {
                    return nil
                }
                return PreviewTranscoding.heic(from: data)
            }
            guard let heic = await work.value else {
                conversionChecked.insert(row.fileId)
                continue
            }
            let name = Self.previewName(row.fileId, etag: row.etag, heic: true)
            do {
                try heic.write(to: directory.appending(path: name), options: .atomic)
                var updated = row
                updated.localPath = name
                updated.bytes = Int64(heic.count)
                try await store.insert(updated)
                index.withLock { $0[row.fileId] = Entry(etag: row.etag, file: name, quality: .screen) }
                try? FileManager.default.removeItem(at: old)
                converted += 1
                saved += max(0, row.bytes - updated.bytes)
            } catch {
                try? FileManager.default.removeItem(at: directory.appending(path: name))
            }
        }
        return (converted, saved)
    }

    /// What the kept files cover.
    public func summary() -> SmartOfflineSummary {
        (try? store.summary()) ?? SmartOfflineSummary()
    }

    /// Removes every kept file (the files of offline albums stay).
    public func removeAll() async {
        running?.cancel()
        _ = await running?.value
        try? await store.deleteAll()
        index.withLock { $0 = [:] }
        try? FileManager.default.removeItem(at: directory)
        OfflineManager.prepare(directory)
    }

    /// Stops a running pass and waits for it (account switch, removal).
    public func shutdown() async {
        isShutDown = true
        pathMonitor.cancel()
        running?.cancel()
        _ = await running?.value
        await thumbnails.shutdown()
    }
}
