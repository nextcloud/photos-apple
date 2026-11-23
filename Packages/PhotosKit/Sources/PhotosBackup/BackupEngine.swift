// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import OSLog
import Photos
import PhotosModel
import PhotosNetworking
import PhotosStore

/// Backup progress shown in the UI (SPEC §7.18.7).
public struct BackupStatus: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case idle
        case notAuthorized
        case scanning
        case reconciling(checked: Int, total: Int)
        case uploading(done: Int, total: Int, current: String)
        case paused(String)
        case upToDate
        case failed(String)
    }

    public var phase: Phase = .idle
    public var uploaded = 0
    public var matched = 0
    public var pending = 0
    public var failed = 0
    public var lastRun: Date?
    /// Set when a run stopped because of something only the user can fix (the phase is then `.failed` with the message).
    public var blocker: Blocker?

    /// Problems that stop the whole backup, not just one file.
    public enum Blocker: Sendable, Equatable {
        /// The account's quota is used up (507).
        case insufficientStorage
        /// The login is no longer valid (401).
        case unauthorized
        /// The server refuses the upload (403), e.g. a read-only folder or a file access rule.
        case forbidden
        /// The server's certificate is not trusted, or it asks for a client certificate.
        case serverTrust
    }

    public init() {}
}

/// Per-resource state in the `backupAsset` table (SPEC §7.18.3).
public enum BackupItemState: String, Codable, Sendable {
    case pending, uploaded, matched, failed, skipped
}

public struct BackupLedgerEntry: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    public static let databaseTableName = "backupAsset"
    public var localIdentifier: String
    public var resourceKind: String
    public var fingerprint: String?
    public var state: String
    public var serverPath: String?
    public var serverFileId: Int64?
    public var serverEtag: String?
    public var matchedBy: String?
    public var attempts: Int
    public var lastError: String?
    public var assetCreatedAt: Double?
    public var assetModifiedAt: Double?
    public var updatedAt: Double
}

/// Camera-roll backup with duplicate protection (SPEC §7.18).
public actor BackupEngine {
    let library: any BackupLibrary
    let remote: any BackupRemote
    let database: AccountDatabase
    let accountId: AccountID
    let now: @Sendable () -> Date
    private let logger = Logger(subsystem: "com.nextcloud.photos", category: "backup")
    private var running: Task<Void, Never>?
    private var status = BackupStatus()
    private var statusHandler: (@Sendable (BackupStatus) -> Void)?
    private var monitor: SystemConditionsMonitor?
    private var network: BackupNetwork?
    private var lowPower: Bool
    /// Set while a run waits for better conditions; cleared when it resumes or the user pauses.
    private var resume: Resume?
    /// Set by `shutdown()`: the account is going away, nothing may start again.
    private var isShutDown = false
    var metadataEditing = false

    struct Resume {
        var settings: BackupSettings
        /// Only videos wait (Wi-Fi only for videos); everything else went through.
        var videosOnly: Bool
        /// A request failed although the path looked fine: wait for the next change instead of trying again at once.
        var needsChange: Bool
    }

    static let scanSignatureKey = "backup.scanSignature"

    public init(api: PhotosAPI, database: AccountDatabase, accountId: AccountID) {
        self.init(
            library: PhotoLibrarySource(), remote: PhotosBackupRemote(api: api, library: LibraryStore(database: database)),
            database: database, accountId: accountId, systemConditions: true)
    }

    /// - Parameter systemConditions: watch the network path and Low Power Mode. Tests pass `false` and call
    ///   `setNetwork` / `setLowPower` themselves.
    init(
        library: any BackupLibrary, remote: any BackupRemote, database: AccountDatabase, accountId: AccountID,
        systemConditions: Bool = false, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.library = library
        self.remote = remote
        self.database = database
        self.accountId = accountId
        self.now = now
        lowPower = systemConditions && ProcessInfo.processInfo.isLowPowerModeEnabled
        if systemConditions { Task { [weak self] in await self?.startMonitoring() } }
    }

    private func startMonitoring() {
        monitor = SystemConditionsMonitor(
            network: { [weak self] network in Task { await self?.setNetwork(network) } },
            lowPower: { [weak self] enabled in Task { await self?.setLowPower(enabled) } })
    }

    public func setStatusHandler(_ handler: @escaping @Sendable (BackupStatus) -> Void) {
        statusHandler = handler
        handler(status)
    }

    public func setMetadataEditing(_ enabled: Bool) { metadataEditing = enabled }

    private func publish(_ phase: BackupStatus.Phase) {
        status.phase = phase
        statusHandler?(status)
    }

    // MARK: Conditions

    func setNetwork(_ network: BackupNetwork) {
        guard network != self.network else { return }
        self.network = network
        conditionsChanged(byEvent: true)
    }

    func setLowPower(_ enabled: Bool) {
        guard enabled != lowPower else { return }
        lowPower = enabled
        conditionsChanged(byEvent: true)
    }

    /// Call when the user changes the backup options, so that a waiting run continues with them (and at once when the
    /// change lifts what it was waiting for, e.g. "Wi-Fi only" switched off).
    public func settingsChanged(_ settings: BackupSettings) {
        guard resume != nil else { return }
        if settings.isEnabled {
            resume?.settings = settings
            conditionsChanged(byEvent: false)
        } else {
            resume = nil
        }
    }

    func pauseReason(_ settings: BackupSettings, isVideo: Bool) -> BackupPause? {
        BackupPolicy.pauseReason(settings, network: network, lowPower: lowPower, isVideo: isVideo)
    }

    /// Continues a waiting run as soon as the network and power state allow it again.
    private func conditionsChanged(byEvent: Bool) {
        guard !isShutDown, var waiting = resume, running == nil else { return }
        if byEvent, waiting.needsChange {
            waiting.needsChange = false
            resume = waiting
        }
        guard !waiting.needsChange, pauseReason(waiting.settings, isVideo: waiting.videosOnly) == nil else { return }
        resume = nil
        Task { await self.run(waiting.settings) }
    }

    private func pause(_ reason: BackupPause, settings: BackupSettings, videosOnly: Bool = false, needsChange: Bool = false) {
        resume = Resume(settings: settings, videosOnly: videosOnly, needsChange: needsChange)
        publish(.paused(reason.message))
    }

    var isWaitingToResume: Bool { resume != nil }

    // MARK: Run

    /// Scans, reconciles and uploads. With `dryRun` only reconciles (status for "keep using Files", SPEC §7.18.1).
    ///
    /// - Parameter retryFailed: also retry resources that failed and would still wait for their next attempt.
    public func run(_ settings: BackupSettings, dryRun: Bool = false, retryFailed: Bool = false) async {
        guard !isShutDown else { return }
        if let running {
            await running.value
            return
        }
        let task = Task { await self.perform(settings, dryRun: dryRun, retryFailed: retryFailed) }
        running = task
        await task.value
        running = nil
        // The conditions may have changed between the pause and here.
        conditionsChanged(byEvent: false)
    }

    /// The user's pause: the run stops and does not continue by itself.
    public func cancel() {
        resume = nil
        running?.cancel()
    }

    /// Stops for good and waits until nothing runs any more (account removal): a running pass is cancelled, a waiting one
    /// is forgotten, and the engine no longer reacts to network or power changes. A later `run` does nothing.
    public func shutdown() async {
        isShutDown = true
        monitor = nil
        resume = nil
        running?.cancel()
        await running?.value
        // The cancelled pass may have ended in a wait (connection lost at the same moment).
        resume = nil
    }

    private func perform(_ settings: BackupSettings, dryRun: Bool, retryFailed: Bool) async {
        resume = nil
        status.blocker = nil
        guard library.isAuthorized else {
            publish(.notAuthorized)
            return
        }
        if !dryRun, let reason = pauseReason(settings, isVideo: false) {
            pause(reason, settings: settings)
            return
        }
        publish(.scanning)
        do {
            let toUpload = try await scanAndReconcile(settings, retryFailed: retryFailed)
            status.pending = toUpload.count
            try refreshCounts()
            if dryRun || toUpload.isEmpty {
                status.lastRun = now()
                publish(toUpload.isEmpty ? .upToDate : .idle)
                return
            }
            let waiting = try await upload(toUpload, settings: settings)
            status.lastRun = now()
            try refreshCounts()
            if let waiting {
                pause(waiting.reason, settings: settings, videosOnly: waiting.videosOnly)
            } else {
                publish(status.pending == 0 ? .upToDate : .idle)
            }
        } catch is CancellationError {
            publish(.paused(BackupPause.user.message))
        } catch let error as NetworkError where Self.isConnectionLoss(error) {
            try? refreshCounts()
            if dryRun {
                publish(.paused(BackupPause.offline.message))
            } else {
                pause(.offline, settings: settings, needsChange: true)
            }
        } catch {
            logger.error("backup failed: \(error.localizedDescription, privacy: .public)")
            try? refreshCounts()
            status.blocker = BackupPolicy.blocker(for: error)
            publish(.failed(error.localizedDescription))
        }
    }

    static func isConnectionLoss(_ error: NetworkError) -> Bool {
        switch error {
        case .offline, .timedOut, .transport: true
        default: false
        }
    }

    // MARK: Scan

    /// Reads the library, consults the ledger and the server, and returns what has to be uploaded (oldest first).
    func scanAndReconcile(_ settings: BackupSettings, retryFailed: Bool) async throws -> [BackupResource] {
        let now = now()
        let ledger = try loadLedger()
        var byAsset: [String: [BackupLedgerEntry]] = [:]
        for entry in ledger.values { byAsset[entry.localIdentifier, default: []].append(entry) }
        // Other options select other resources of an asset, so the "nothing to do" shortcut does not hold then.
        let signature = BackupPolicy.scanSignature(settings)
        let fullScan = (try? database.syncValue(Self.scanSignatureKey)) != signature
        let resources = library.scan(settings) { localIdentifier, modifiedAt in
            if fullScan || retryFailed { return true }
            return BackupPolicy.needsScan(entries: byAsset[localIdentifier] ?? [], modifiedAt: modifiedAt, now: now)
        }
        let filesUploaded = settings.filesAppMode == .notUsed ? [] : FilesAppLedger.uploadedAssets(accountId: accountId)

        var order: [LedgerKey: Int] = [:]
        var work: [BackupResource] = []
        var direct: [BackupResource] = []
        var touched: [BackupResource] = []
        var unknown: [BackupResource] = []
        for (index, resource) in resources.enumerated() {
            let key = LedgerKey(localIdentifier: resource.localIdentifier, kind: resource.kind.rawValue)
            order[key] = index
            let entry = ledger[key]
            switch BackupPolicy.action(for: resource, entry: entry, now: now, retryFailed: retryFailed) {
            case .done, .waiting: continue
            case .touch: touched.append(resource)
            case .upload: direct.append(resource)
            case .reconcile:
                if filesUploaded.contains(resource.localIdentifier) {
                    try record(resource, state: .matched, matchedBy: .filesLedger)
                    continue
                }
                if entry == nil { unknown.append(resource) }
                work.append(resource)
            }
        }
        // Everything found gets a ledger entry now: an asset without one for each of its resources is read again next time.
        try prepareLedger(pending: unknown, touched: touched)
        try database.setSyncValue(Self.scanSignatureKey, signature)
        try Task.checkCancellation()
        let remaining = try await reconcile(work)
        return (remaining + direct).sorted { order[LedgerKey($0), default: 0] < order[LedgerKey($1), default: 0] }
    }

    // MARK: Reconciliation (SPEC §7.18.4 layer 4)

    /// Returns the resources that are not on the server yet; records the matched ones.
    func reconcile(_ work: [BackupResource]) async throws -> [BackupResource] {
        // Batches of ≤ 200 resources spanning ≤ 7 days, so each SEARCH stays small.
        var batches: [[BackupResource]] = []
        for resource in work {
            if let first = batches.last?.first, batches[batches.count - 1].count < 200,
                resource.createdAt.timeIntervalSince(first.createdAt) <= 7 * 86_400
            {
                batches[batches.count - 1].append(resource)
            } else {
                batches.append([resource])
            }
        }
        var remaining: [BackupResource] = []
        var checked = 0
        for batch in batches {
            try Task.checkCancellation()
            guard let first = batch.first?.createdAt, let last = batch.last?.createdAt else { continue }
            let candidates = try await remote.candidates(from: first.addingTimeInterval(-2), to: last.addingTimeInterval(2))
            let locals = batch.map(\.local)
            for resource in batch {
                if let (candidate, reason) = BackupMatcher.match(resource.local, candidates: candidates, localSiblings: locals) {
                    try record(resource, state: .matched, matchedBy: reason, serverPath: candidate.path, serverFileId: candidate.fileId)
                } else {
                    remaining.append(resource)
                }
            }
            checked += batch.count
            publish(.reconciling(checked: checked, total: work.count))
        }
        return remaining
    }

    // MARK: Upload

    /// Uploads the resources. Returns why some of them still wait, or nil when all were tried.
    ///
    /// Throws for what ends the run: cancellation, a lost connection, and errors that every other file would hit as well
    /// (`BackupPolicy.blocker`). A failure of one resource is recorded and the run goes on.
    func upload(_ work: [BackupResource], settings: BackupSettings) async throws -> (reason: BackupPause, videosOnly: Bool)? {
        var done = 0
        var heldVideos: BackupPause?
        for resource in work {
            try Task.checkCancellation()
            if let reason = pauseReason(settings, isVideo: false) { return (reason, false) }
            if resource.mediaKind == .video, let reason = pauseReason(settings, isVideo: true) {
                // Photos go on while the videos wait for Wi-Fi.
                heldVideos = reason
                continue
            }
            publish(.uploading(done: done, total: work.count, current: resource.originalName))
            var file: URL?
            defer { if let file { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) } }
            do {
                var exported = try await library.export(resource, settings: settings)
                file = exported
                if settings.format == .mostCompatible, resource.mediaKind == .image, resource.kind != .raw {
                    exported = try PhotoLibrarySource.convertToJPEG(exported)
                    file = exported
                }
                let name = BackupNaming.fileName(
                    originalName: resource.originalName, fileExtension: exported.pathExtension, isVideo: resource.mediaKind == .video,
                    date: resource.createdAt, naming: settings.naming)
                let folder = BackupNaming.folder(base: settings.folder, subfolders: settings.subfolders, date: resource.createdAt)
                // Layer 5: an existing file with the same name and size counts as uploaded; otherwise " (2)".
                let uploaded = try await remote.upload(file: exported, fileName: name, folder: folder, capturedAt: resource.createdAt)
                try record(resource, state: .uploaded, matchedBy: .ownUpload, serverPath: uploaded.path, serverFileId: uploaded.fileId)
                status.uploaded += 1
                await linkLivePhoto(resource, uploaded: uploaded)
                await remote.didUpload(uploaded, resource: resource, metadataEditing: metadataEditing)
            } catch {
                // The user's pause is not a failure of this file.
                if Task.isCancelled || BackupPolicy.isCancellation(error) { throw CancellationError() }
                if let error = error as? NetworkError, error.isTransient { throw error }
                logger.error(
                    "backup of \(resource.originalName, privacy: .private) failed: \(error.localizedDescription, privacy: .public)")
                let blocker = BackupPolicy.blocker(for: error)
                // A full quota or a refusal may concern this file only (too big, blocked type): it backs off like any
                // failed file, so the next run starts with another one. A lost login or certificate says nothing about the file.
                if blocker != .unauthorized, blocker != .serverTrust {
                    try? record(resource, state: .failed, error: error.localizedDescription)
                    status.failed += 1
                }
                if blocker != nil { throw error }
            }
            done += 1
            status.pending = max(0, status.pending - 1)
        }
        return heldVideos.map { ($0, true) }
    }

    /// Links the still and the motion part of a Live Photo once both are on the server, also when they got there in different runs.
    func linkLivePhoto(_ resource: BackupResource, uploaded: UploadedFile) async {
        guard [.photo, .edited, .pairedVideo].contains(resource.kind) else { return }
        let entries = (try? ledgerEntries(of: resource.localIdentifier)) ?? []
        func server(_ kind: BackupResourceKind) -> (path: String, fileId: FileID)? {
            guard let entry = entries.first(where: { $0.resourceKind == kind.rawValue }), BackupPolicy.isComplete(entry),
                let path = entry.serverPath, let fileId = entry.serverFileId
            else { return nil }
            return (path, fileId)
        }
        let still: (path: String, fileId: FileID)?
        let motion: (path: String, fileId: FileID)?
        if resource.kind == .pairedVideo {
            still = server(.edited) ?? server(.photo)
            motion = (uploaded.path, uploaded.fileId)
        } else {
            still = (uploaded.path, uploaded.fileId)
            motion = server(.pairedVideo)
        }
        guard let still, let motion else { return }
        do {
            try await remote.linkLivePhoto(
                imagePath: still.path, imageFileId: still.fileId, videoPath: motion.path, videoFileId: motion.fileId)
        } catch {
            logger.error("linking a Live Photo failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Ledger

    struct LedgerKey: Hashable {
        var localIdentifier: String
        var kind: String
    }

    func loadLedger() throws -> [LedgerKey: BackupLedgerEntry] {
        try database.writer.read { db in
            var map: [LedgerKey: BackupLedgerEntry] = [:]
            for entry in try BackupLedgerEntry.fetchAll(db) {
                map[LedgerKey(localIdentifier: entry.localIdentifier, kind: entry.resourceKind)] = entry
            }
            return map
        }
    }

    func ledgerEntries(of localIdentifier: String) throws -> [BackupLedgerEntry] {
        try database.writer.read { db in try BackupLedgerEntry.filter(Column("localIdentifier") == localIdentifier).fetchAll(db) }
    }

    /// Adds `pending` entries for new resources and stores the new modification date of unchanged ones, in one transaction.
    func prepareLedger(pending: [BackupResource], touched: [BackupResource]) throws {
        guard !pending.isEmpty || !touched.isEmpty else { return }
        let updatedAt = now().timeIntervalSince1970
        try database.writer.write { db in
            for resource in pending {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO backupAsset(localIdentifier, resourceKind, state, attempts, assetCreatedAt, assetModifiedAt, updatedAt)
                        VALUES (?, ?, ?, 0, ?, ?, ?)
                        """,
                    arguments: [
                        resource.localIdentifier, resource.kind.rawValue, BackupItemState.pending.rawValue,
                        resource.createdAt.timeIntervalSince1970, resource.modifiedAt?.timeIntervalSince1970, updatedAt,
                    ])
            }
            for resource in touched {
                try db.execute(
                    sql: "UPDATE backupAsset SET assetModifiedAt = ? WHERE localIdentifier = ? AND resourceKind = ?",
                    arguments: [resource.modifiedAt?.timeIntervalSince1970, resource.localIdentifier, resource.kind.rawValue])
            }
        }
    }

    func record(
        _ resource: BackupResource, state: BackupItemState, matchedBy: MatchReason? = nil, serverPath: String? = nil,
        serverFileId: FileID? = nil,
        error: String? = nil
    ) throws {
        let updatedAt = now().timeIntervalSince1970
        try database.writer.write { db in
            let previous = try BackupLedgerEntry.fetchOne(
                db, key: ["localIdentifier": resource.localIdentifier, "resourceKind": resource.kind.rawValue])
            // A failure keeps what is known about the copy on the server; a success starts the retry count again.
            let failed = state == .failed
            let entry = BackupLedgerEntry(
                localIdentifier: resource.localIdentifier, resourceKind: resource.kind.rawValue,
                fingerprint: failed ? previous?.fingerprint : resource.sizeFingerprint, state: state.rawValue,
                serverPath: serverPath ?? previous?.serverPath, serverFileId: serverFileId ?? previous?.serverFileId, serverEtag: nil,
                matchedBy: matchedBy?.rawValue ?? previous?.matchedBy, attempts: failed ? (previous?.attempts ?? 0) + 1 : 0,
                lastError: error, assetCreatedAt: resource.createdAt.timeIntervalSince1970,
                assetModifiedAt: resource.modifiedAt?.timeIntervalSince1970, updatedAt: updatedAt)
            try entry.upsert(db)
        }
    }

    func refreshCounts() throws {
        let counts = try database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT state, count(*) AS n FROM backupAsset GROUP BY state").reduce(into: [String: Int]()) {
                $0[$1["state"]] = $1["n"]
            }
        }
        status.uploaded = counts[BackupItemState.uploaded.rawValue] ?? 0
        status.matched = counts[BackupItemState.matched.rawValue] ?? 0
        status.failed = counts[BackupItemState.failed.rawValue] ?? 0
    }

    /// Ledger entries for the details list.
    public func entries(limit: Int = 500) throws -> [BackupLedgerEntry] {
        try database.writer.read { db in try BackupLedgerEntry.order(Column("updatedAt").desc).limit(limit).fetchAll(db) }
    }

    /// Lets the user force-upload a resource that was matched (SPEC §7.18.4): the next run uploads it without asking the
    /// matcher again (which would only find the same server file once more).
    public func forgetMatch(localIdentifier: String, kind: String) throws {
        let updatedAt = now().timeIntervalSince1970
        try database.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE backupAsset SET state = ?, matchedBy = ?, attempts = 0, lastError = NULL, updatedAt = ?
                    WHERE localIdentifier = ? AND resourceKind = ?
                    """,
                arguments: [BackupItemState.pending.rawValue, MatchReason.user.rawValue, updatedAt, localIdentifier, kind])
        }
    }

    public func reset() throws {
        try database.writer.write { db in try db.execute(sql: "DELETE FROM backupAsset") }
        try database.setSyncValue(Self.scanSignatureKey, nil)
        resume = nil
        status = BackupStatus()
    }
}

extension BackupEngine.LedgerKey {
    init(_ resource: BackupResource) {
        self.init(localIdentifier: resource.localIdentifier, kind: resource.kind.rawValue)
    }
}
