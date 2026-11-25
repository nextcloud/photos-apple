// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Observation
import PhotosDomain
import PhotosModel
import PhotosNetworking
import PhotosStore

#if canImport(UIKit)
    import UIKit
#endif

/// Smart albums made with the rule builder, folder rules and the camera details they need (SPEC §16.4), for one account.
///
/// Smart albums and folder rules live in the user's Nextcloud (`.nextcloud-photos/`), so all devices share them; a copy
/// on the device keeps them usable offline, and changes made offline are merged when the server is reachable again.
@MainActor
@Observable
public final class OrganizeModel {
    public private(set) var smartAlbums: [SmartAlbumDefinition] = []
    public private(set) var folderRules: [FolderRule] = []
    /// The log of rule runs, newest first (from whichever device ran them).
    public private(set) var ruleLog: [FolderRuleState.LogEntry] = []
    /// Camera details read so far, of all photos that can have them (nil before the first count).
    public private(set) var cameraProgress: (read: Int, total: Int)?
    public private(set) var isReadingCameraDetails = false
    /// The last sync with the server failed (offline): what is shown is this device's copy.
    public private(set) var syncError: String?
    public private(set) var isRunningRules = false

    @ObservationIgnored let services: AccountServices
    @ObservationIgnored weak var session: SessionModel?
    @ObservationIgnored private var smartCopy: LocalCopy<SmartAlbumDefinition>
    @ObservationIgnored private var rulesCopy: LocalCopy<FolderRule>
    @ObservationIgnored private var stateCopy: StateCopy
    @ObservationIgnored private var lastSync: Date?
    @ObservationIgnored private var lastRuleRun: Date?
    @ObservationIgnored private var cameraTask: Task<Void, Never>?
    @ObservationIgnored private var context: (value: SmartRuleContext, items: [MediaItem], camera: Bool, at: Date)?

    static let smartAlbumsFile = "smart-albums.json"
    static let folderRulesFile = "folder-rules.json"
    static let ruleStateFile = "folder-rules-state.json"
    static let leaseFile = "folder-rules.lock"

    /// A copy of a shared list on the device.
    struct LocalCopy<Record: SyncedRecord>: Codable {
        var etag: String?
        var list: SyncedList<Record>
    }

    struct StateCopy: Codable {
        var etag: String?
        var state: FolderRuleState
    }

    /// The state file is read by other devices (and could be by other clients): dates as Unix seconds.
    nonisolated static var stateEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    nonisolated static var stateDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    init(services: AccountServices, session: SessionModel) {
        self.services = services
        self.session = session
        let directory = services.layout.accountDirectory(services.account.id).appending(path: "Organize")
        self.directory = directory
        smartCopy = Self.load(directory.appending(path: Self.smartAlbumsFile)) ?? LocalCopy(list: SyncedList())
        rulesCopy = Self.load(directory.appending(path: Self.folderRulesFile)) ?? LocalCopy(list: SyncedList())
        stateCopy = Self.load(directory.appending(path: Self.ruleStateFile)) ?? StateCopy(state: FolderRuleState())
        publish()
    }

    @ObservationIgnored let directory: URL

    var files: AppDataFiles { AppDataFiles(dav: services.dav) }

    private func publish() {
        smartAlbums = smartCopy.list.live
        folderRules = rulesCopy.list.live
        ruleLog = stateCopy.state.log
    }

    static func load<T: Decodable>(_ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T, _ name: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(value) { try? data.write(to: directory.appending(path: name), options: .atomic) }
    }

    // MARK: Sync

    /// Merges this device's lists with the server's (at most every 2 minutes unless forced).
    public func sync(force: Bool = false) async {
        if !force, let lastSync, Date().timeIntervalSince(lastSync) < 120 { return }
        lastSync = Date()
        do {
            await migrateLegacySmartAlbums()
            smartCopy = try await Self.sync(Self.smartAlbumsFile, smartCopy, files: files)
            save(smartCopy, Self.smartAlbumsFile)
            rulesCopy = try await Self.sync(Self.folderRulesFile, rulesCopy, files: files)
            save(rulesCopy, Self.folderRulesFile)
            if let content = try await files.read(Self.ruleStateFile),
                let state = try? Self.stateDecoder.decode(FolderRuleState.self, from: content.data)
            {
                stateCopy = StateCopy(etag: content.etag, state: state)
                save(stateCopy, Self.ruleStateFile)
            }
            syncError = nil
        } catch {
            syncError = error.localizedDescription
            SessionModel.organizeLogger.error("organize sync failed: \(error.localizedDescription, privacy: .public)")
        }
        publish()
    }

    /// One list: the server's version merged with the device's, written back when the device had something new.
    nonisolated static func sync<Record: SyncedRecord>(
        _ name: String, _ copy: LocalCopy<Record>, files: AppDataFiles
    ) async throws -> LocalCopy<Record> {
        let local = copy.list
        let written = try await files.update(name) { current in
            let remote = try current.map { try SyncedList<Record>.decoded($0.data) } ?? SyncedList<Record>()
            let merged = remote.merged(with: local)
            // Nothing new here: no write (an empty list is not written either).
            if current != nil && merged == remote { return nil }
            if current == nil && merged.records.isEmpty { return nil }
            return try merged.encoded()
        }
        guard let written else { return LocalCopy(etag: nil, list: local) }
        let list = (try? SyncedList<Record>.decoded(written.data)) ?? local
        return LocalCopy(etag: written.etag, list: list)
    }

    /// Smart albums saved "On this device" before rule-based albums existed become shared ones (same id), once.
    private func migrateLegacySmartAlbums() async {
        guard let legacy = try? services.collections.smartAlbums().filter(\.isLocal).map(\.0), !legacy.isEmpty else { return }
        for album in legacy where !smartCopy.list.records.contains(where: { $0.id == album.id }) {
            smartCopy.list.upsert(SmartAlbumDefinition(id: album.id, name: album.name, rule: SmartRule(album.filters)))
        }
        save(smartCopy, Self.smartAlbumsFile)
        try? services.collections.replaceSmartAlbums([], isLocal: true)
    }

    // MARK: Smart albums

    public func save(_ album: SmartAlbumDefinition) async {
        smartCopy.list.upsert(album)
        save(smartCopy, Self.smartAlbumsFile)
        context = nil
        publish()
        await sync(force: true)
    }

    public func delete(_ album: SmartAlbumDefinition) async {
        smartCopy.list.delete(id: album.id)
        save(smartCopy, Self.smartAlbumsFile)
        publish()
        await sync(force: true)
    }

    public func smartAlbum(id: String) -> SmartAlbumDefinition? { smartAlbums.first { $0.id == id } }

    /// The rule context and the photos rules look at, cached for a minute (the builder counts on every change).
    public func ruleInputs(camera: Bool, maxAge: TimeInterval = 60) async throws -> (SmartRuleContext, [MediaItem]) {
        if let context, Date().timeIntervalSince(context.at) < maxAge, context.camera || !camera {
            return (context.value, context.items)
        }
        let store = OrganizeStore(database: services.database)
        let excluded = session?.excludedFolders ?? []
        async let value = store.ruleContext(camera: camera)
        async let items = store.ruleItems(excludedFolders: excluded)
        let result = (try await value, try await items)
        context = (result.0, result.1, camera, Date())
        return result
    }

    /// Drops the cached inputs (after a sync or a change of photos).
    public func invalidateRuleInputs() { context = nil }

    /// The photos of a rule-based smart album.
    public func items(of album: SmartAlbumDefinition) async throws -> [MediaItem] {
        let (context, items) = try await ruleInputs(camera: album.rule.needsCameraDetails)
        return await Task.detached(priority: .userInitiated) { SmartRuleEvaluator.items(of: album, from: items, in: context) }.value
    }

    /// How many photos a rule matches, and the newest few (the builder's live preview).
    public func preview(of rule: SmartRule, limit: Int = 12) async throws -> (count: Int, sample: [MediaItem]) {
        let (context, items) = try await ruleInputs(camera: rule.needsCameraDetails)
        return await Task.detached(priority: .userInitiated) {
            var count = 0
            var sample: [MediaItem] = []
            for item in items where SmartRuleEvaluator.matches(rule, item, in: context) {
                count += 1
                if sample.count < limit { sample.append(item) }
            }
            return (count, sample)
        }.value
    }

    // MARK: Camera details

    /// Reads the camera details of photos that lack them, in the background, while a rule needs them.
    /// - Parameter batches: the most requests in this pass (90 photos each); nil until all are read.
    public func readCameraDetails(batches: Int? = nil) {
        guard cameraTask == nil else { return }
        isReadingCameraDetails = true
        let services = services
        let folders = session?.features.userConfig.photosSourceFolders ?? ["/Photos"]
        cameraTask = Task { [weak self] in
            let store = OrganizeStore(database: services.database)
            var remaining = batches ?? Int.max
            while remaining > 0, !Task.isCancelled {
                guard let ids = try? await store.filesNeedingCameraDetails(limit: PhotosAPI.cameraDetailsBatch * 2), !ids.isEmpty else {
                    break
                }
                let halves = stride(from: 0, to: ids.count, by: PhotosAPI.cameraDetailsBatch).map {
                    Array(ids[$0..<min($0 + PhotosAPI.cameraDetailsBatch, ids.count)])
                }
                var failed = false
                await withTaskGroup(of: [FileID: CameraDetails]?.self) { group in
                    for half in halves {
                        group.addTask { try? await services.api.cameraDetails(fileIds: half, sourceFolders: folders) }
                    }
                    for await details in group {
                        if let details { try? await store.storeCameraDetails(details) } else { failed = true }
                    }
                }
                remaining -= halves.count
                if let progress = try? await store.cameraDetailsProgress() {
                    await MainActor.run {
                        // Rules see the new details at their next count.
                        self?.context = nil
                        self?.cameraProgress = progress
                    }
                }
                if failed { break }
            }
            await MainActor.run {
                self?.cameraTask = nil
                self?.isReadingCameraDetails = false
                self?.context = nil
            }
        }
    }

    public func refreshCameraProgress() async {
        cameraProgress = try? await OrganizeStore(database: services.database).cameraDetailsProgress()
    }

    /// A rule of a smart album or an enabled folder rule asks about cameras.
    var rulesNeedCameraDetails: Bool {
        smartAlbums.contains { $0.rule.needsCameraDetails } || folderRules.contains { $0.isEnabled && $0.rule.needsCameraDetails }
    }

    func stop() {
        cameraTask?.cancel()
    }
}

// MARK: - Folder rules

extension OrganizeModel {
    public func save(_ rule: FolderRule) async {
        rulesCopy.list.upsert(rule)
        save(rulesCopy, Self.folderRulesFile)
        publish()
        await sync(force: true)
    }

    public func delete(_ rule: FolderRule) async {
        rulesCopy.list.delete(id: rule.id)
        save(rulesCopy, Self.folderRulesFile)
        publish()
        await sync(force: true)
    }

    /// What a rule would act on now (the editor's preview), without acting.
    public func preview(of rule: FolderRule) async throws -> [MediaItem] {
        let (context, items) = try await ruleInputs(camera: rule.rule.needsCameraDetails, maxAge: 0)
        var runnable = rule
        runnable.isEnabled = true
        let state = stateCopy.state
        let steps = FolderRulePlanner.plan(rules: [runnable], items: items, context: context, state: state)
        let ids = Set(steps.first?.fileIds ?? [])
        return items.filter { ids.contains($0.fileId) }
    }

    /// A random id of this installation for this account (the lease holder), kept in the account's directory.
    var holderId: String {
        let url = directory.appending(path: "device-id")
        if let id = try? String(contentsOf: url, encoding: .utf8), !id.isEmpty { return id }
        let id = UUID().uuidString
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? id.write(to: url, atomically: true, encoding: .utf8)
        return id
    }

    static var deviceName: String {
        #if os(macOS)
            Host.current().localizedName ?? "Mac"
        #elseif canImport(UIKit) && !os(watchOS)
            UIDevice.current.name
        #else
            "Device"
        #endif
    }

    /// Runs the folder rules after a sync (SPEC §16.4): at most every 2 minutes, on one device at a time.
    /// - Returns: how many photos were acted on.
    @discardableResult
    public func runRules(force: Bool = false) async -> Int {
        guard let session, !isRunningRules else { return 0 }
        let rules = rulesCopy.list.live.filter(\.isRunnable)
        guard !rules.isEmpty else { return 0 }
        if !force, let lastRuleRun, Date().timeIntervalSince(lastRuleRun) < 120 { return 0 }
        lastRuleRun = Date()
        isRunningRules = true
        defer { isRunningRules = false }
        let files = files
        let holder = holderId
        let device = Self.deviceName
        // The lease: only one device acts at a time, or the same photo would be added twice.
        guard let leaseTag = try? await Self.acquireLease(files: files, holder: holder, device: device) else { return 0 }
        defer { Task { try? await files.delete(Self.leaseFile, expected: leaseTag) } }
        guard let (ruleContext, items) = try? await ruleInputs(camera: rules.contains { $0.rule.needsCameraDetails }, maxAge: 0) else {
            return 0
        }
        // The state as the server has it now (another device may have run since the last sync).
        let latest = try? await files.read(Self.ruleStateFile)
        var state = latest.flatMap { try? Self.stateDecoder.decode(FolderRuleState.self, from: $0.data) } ?? stateCopy.state
        let steps = FolderRulePlanner.plan(rules: rules, items: items, context: ruleContext, state: state)
        guard !steps.isEmpty else { return 0 }
        let byId = Dictionary(uniqueKeysWithValues: items.map { ($0.fileId, $0) })
        var total = 0
        for step in steps {
            let targets = step.fileIds.compactMap { byId[$0] }
            var failure: String?
            do {
                try await perform(step.rule.action, on: targets, session: session)
                total += targets.count
            } catch {
                failure = error.localizedDescription
            }
            state.record(
                FolderRuleState.LogEntry(
                    date: Date(), ruleId: step.rule.id, ruleName: step.rule.name, count: failure == nil ? targets.count : 0,
                    device: device, error: failure),
                handled: failure == nil ? step.fileIds : [])
        }
        state.prune(keeping: Set(rulesCopy.list.records.map(\.id)))
        let finalState = state
        if let written = try? await files.update(
            Self.ruleStateFile,
            { current in
                // Another device cannot hold the lease meanwhile, but keep what is there if it ever did.
                var merged = finalState
                if let current, let other = try? Self.stateDecoder.decode(FolderRuleState.self, from: current.data) {
                    merged = Self.merge(finalState, other)
                }
                return try Self.stateEncoder.encode(merged)
            }), let saved = try? Self.stateDecoder.decode(FolderRuleState.self, from: written.data)
        {
            stateCopy = StateCopy(etag: written.etag, state: saved)
        } else {
            stateCopy = StateCopy(etag: stateCopy.etag, state: finalState)
        }
        save(stateCopy, Self.ruleStateFile)
        self.context = nil
        publish()
        return total
    }

    /// Two states in one: handled ids and log entries of both.
    nonisolated static func merge(_ a: FolderRuleState, _ b: FolderRuleState) -> FolderRuleState {
        var result = a
        for (rule, ids) in b.handled {
            let known = Set(result.handled[rule] ?? [])
            result.handled[rule, default: []].append(contentsOf: ids.filter { !known.contains($0) })
        }
        let ids = Set(result.log.map(\.id))
        result.log = (result.log + b.log.filter { !ids.contains($0.id) }).sorted { $0.date > $1.date }
        if result.log.count > FolderRuleState.maxLogEntries { result.log = Array(result.log.prefix(FolderRuleState.maxLogEntries)) }
        return result
    }

    /// Takes the lease when it is free, expired or this device's; returns its ETag (to release it), nil when another
    /// device holds it.
    nonisolated static func acquireLease(files: AppDataFiles, holder: String, device: String, now: Date = Date()) async throws -> String? {
        let current = try await files.read(leaseFile)
        let lease = current.flatMap { try? JSONDecoder().decode(FolderRuleLease.self, from: $0.data) }
        guard FolderRuleLease.canAcquire(lease, holder: holder, now: now) else { return nil }
        let mine = FolderRuleLease(holder: holder, device: device, expiresAt: now.addingTimeInterval(FolderRuleLease.duration))
        do {
            return try await files.write(leaseFile, data: try JSONEncoder().encode(mine), replacing: current?.etag)
        } catch NetworkError.preconditionFailed {
            // Another device was faster.
            return nil
        }
    }

    /// Does what a rule says, through the outbox (offline-safe, retried).
    private func perform(_ action: FolderRule.Action, on items: [MediaItem], session: SessionModel) async throws {
        guard !items.isEmpty else { return }
        switch action {
        case .favorite:
            await session.enqueue(items.map { .favorite(fileId: $0.fileId, path: $0.path, value: true) })
        case .archive:
            await session.enqueue(items.map { .archive(fileId: $0.fileId, path: $0.path) })
        case .addToAlbum(let name):
            let album = try await ownAlbum(named: name, session: session)
            await session.add(items, to: album)
        case .addTag(let name):
            let tag = try await tag(named: name, session: session)
            await session.setTag(tag, on: items, assigned: true)
        }
    }

    /// The own album with this name, made when there is none.
    func ownAlbum(named name: String, session: SessionModel) async throws -> Album {
        let wanted = SmartRuleContext.fold(name)
        func find() -> Album? {
            (try? services.collections.albums(.own))?.first {
                SmartRuleContext.fold($0.name) == wanted || SmartRuleContext.fold($0.title) == wanted
            }
        }
        if let album = find() { return album }
        try? await session.refreshAlbums(force: true)
        if let album = find() { return album }
        return try await session.createAlbum(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func tag(named name: String, session: SessionModel) async throws -> SystemTag {
        let wanted = SmartRuleContext.fold(name)
        let (tags, _) = await session.assignableTags()
        if let tag = tags.first(where: { SmartRuleContext.fold($0.name) == wanted }) { return tag }
        return try await session.createTag(named: name)
    }
}
