// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CryptoKit
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
        /// Everything this device has is on the server: nothing failed, nothing waits.
        case upToDate
        /// The pass ran to its end, but this many items could not be uploaded (`lastFailure` says why). They are tried
        /// again after their waiting time, or at once when the user asks.
        case incomplete(failed: Int)
        case failed(String)
    }

    public var phase: Phase = .idle
    /// Everything this app has uploaded so far (the ledger's count).
    public var uploaded = 0
    /// What the current or last pass uploaded.
    public var uploadedThisPass = 0
    public var matched = 0
    /// Items that still have to be uploaded (they wait for Wi-Fi, for the system, or for the next pass). Failed items
    /// are not in here; see `failed`.
    public var pending = 0
    /// Items whose upload failed and that wait for their next attempt.
    public var failed = 0
    /// Why the most recent of them failed.
    public var lastFailure: String?
    /// Items left out because their original is only in iCloud and "Download originals from iCloud" is off.
    public var skipped = 0
    /// The app may only see the photos the user selected ("limited access"); everything else is not backed up.
    public var isLimitedAccess = false
    public var lastRun: Date?
    /// Set when a run stopped because of something only the user can fix (the phase is then `.failed` with the message).
    public var blocker: Blocker?
    /// The system took the time away from the last pass (a background task expired) before it was through. This is not
    /// the user's pause: the phase is `.idle` and the pass is taken up again at the next opportunity.
    public var isInterrupted = false

    /// A pass is at work.
    public var isRunning: Bool {
        switch phase {
        case .scanning, .reconciling, .uploading: true
        case .idle, .notAuthorized, .paused, .upToDate, .incomplete, .failed: false
        }
    }

    /// The phase for the log (Settings › Export diagnostics): its name and numbers only. File names, pause reasons and
    /// error messages are left out; they can contain names of the user's files, account and server.
    public var phaseLogDescription: String {
        switch phase {
        case .idle: isInterrupted ? "idle (interrupted)" : "idle"
        case .notAuthorized: "not authorized"
        case .scanning: "scanning"
        case .reconciling(_, let total): "reconciling \(total) items"
        case .uploading(_, let total, _): "uploading \(total) items"
        case .paused: "paused"
        case .upToDate: "up to date"
        case .incomplete(let failed): "incomplete, \(failed) failed"
        case .failed: blocker.map { "failed (\($0))" } ?? "failed"
        }
    }

    /// Counts for the log line at the end of a pass.
    public var countsLogDescription: String {
        "uploaded this pass \(uploadedThisPass), pending \(pending), failed \(failed), skipped \(skipped)"
            + (isLimitedAccess ? ", limited access" : "")
    }

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
        /// This device has no room for the file that would be uploaded.
        case deviceStorageFull
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
    /// Set by `interrupt()` for the pass it stops.
    private var interrupting = false
    var metadataEditing = false

    // Uploads handed to the system (SPEC §7.18.6); all nil or empty without `background`.
    nonisolated let background: BackgroundUploads?
    private var journal: BackgroundUploadJournal?
    /// Uploads the system reported that are still being recorded.
    private var finishing = 0
    /// What an upload the system reported means for the running pass: the error that ends it.
    private var backgroundStop: (any Error)?
    /// The pass waits here for the system (for room to hand over the next file, or for the last uploads).
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// Resources whose upload the system reported since the pass started.
    private var settled: Set<LedgerKey> = []
    /// Uploads the system no longer knows although nothing was reported, seen once. Seen twice, they are given up.
    private var missing: Set<String> = []
    private var lastMissingCheck = Date.distantPast
    /// How long the pass waits for a report before it asks the system what it is still working on.
    var missingCheckInterval: TimeInterval = 60
    /// Counts of the upload phase of the running pass.
    private var progress: (done: Int, total: Int, current: String)?
    /// Uploads the server refused because their name was taken meanwhile (412): the running pass prepares them again.
    private var retake: [BackupResource] = []
    /// Where the library writes its exports (`PhotoLibrarySource.exportDirectory`); nil: nothing is kept or swept.
    let exportDirectory: URL?
    private var exportsSwept = false
    private var keptExportMinimumSize = BackupPolicy.keptExportMinimumSize
    /// What the Files app uploaded (SPEC §7.18.5).
    let filesLedger: @Sendable (AccountID) -> Set<String>
    /// Free space on this device, when it can be told.
    private var freeSpace: @Sendable () -> Int64?

    struct Resume {
        var settings: BackupSettings
        /// Only videos wait (Wi-Fi only for videos); everything else went through.
        var videosOnly: Bool
        /// A request failed although the path looked fine: wait for the next change instead of trying again at once.
        var needsChange: Bool
        /// Originals wait for a connection that may download from iCloud (Wi-Fi, no Low Data Mode).
        var needsICloud = false
    }

    /// Why some resources still wait after the upload phase.
    struct Waiting: Equatable {
        var reason: BackupPause
        var videosOnly = false
        var needsICloud = false
    }

    static let scanSignatureKey = "backup.scanSignature"

    /// - Parameter background: hand uploads to a background transfer session, so they go on while the app is suspended.
    ///   Without it every upload is sent by the app itself.
    public init(api: PhotosAPI, database: AccountDatabase, accountId: AccountID, background: BackgroundUploads? = nil) {
        self.init(
            library: PhotoLibrarySource(),
            remote: PhotosBackupRemote(api: api, library: LibraryStore(database: database), database: database),
            database: database, accountId: accountId, systemConditions: true, background: background,
            exportDirectory: PhotoLibrarySource.exportDirectory)
    }

    /// - Parameter systemConditions: watch the network path and Low Power Mode. Tests pass `false` and call
    ///   `setNetwork` / `setLowPower` themselves.
    init(
        library: any BackupLibrary, remote: any BackupRemote, database: AccountDatabase, accountId: AccountID,
        systemConditions: Bool = false, background: BackgroundUploads? = nil, exportDirectory: URL? = nil,
        filesLedger: @escaping @Sendable (AccountID) -> Set<String> = { FilesAppLedger.uploadedAssets(accountId: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.background = background
        self.exportDirectory = exportDirectory
        self.filesLedger = filesLedger
        freeSpace = { Self.freeDeviceSpace(at: exportDirectory ?? FileManager.default.temporaryDirectory) }
        if let background {
            let journal = BackgroundUploadJournal(directory: background.directory)
            journal.removeUnknownFiles()
            self.journal = journal
        }
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

    func setFreeSpace(_ freeSpace: @escaping @Sendable () -> Int64?) { self.freeSpace = freeSpace }

    func setKeptExportMinimumSize(_ size: Int64) { keptExportMinimumSize = size }

    /// What the system says can be written for something the user asked for (it frees caches for that), in bytes.
    static func freeDeviceSpace(at directory: URL) -> Int64? {
        // The directory may not exist yet; its volume is that of the first parent that does.
        var url = directory
        while !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)), url.pathComponents.count > 1 {
            url = url.deletingLastPathComponent()
        }
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    private func publish(_ phase: BackupStatus.Phase) {
        status.phase = phase
        logTransition()
        statusHandler?(status)
    }

    /// What the last log line said about the phase: progress within a phase is not logged, a change of phase is.
    private var loggedPhase: String?

    private func logTransition() {
        let description = status.phaseLogDescription
        guard description != loggedPhase else { return }
        loggedPhase = description
        switch status.phase {
        case .upToDate, .incomplete, .failed, .paused, .notAuthorized:
            logger.notice("backup: \(description, privacy: .public); \(self.status.countsLogDescription, privacy: .public)")
        case .idle where status.isInterrupted:
            logger.notice("backup: \(description, privacy: .public); \(self.status.countsLogDescription, privacy: .public)")
        default:
            logger.info("backup: \(description, privacy: .public)")
        }
    }

    // MARK: Conditions

    func setNetwork(_ network: BackupNetwork) {
        guard network != self.network else { return }
        self.network = network
        wakeWaiters()
        conditionsChanged(byEvent: true)
    }

    func setLowPower(_ enabled: Bool) {
        guard enabled != lowPower else { return }
        lowPower = enabled
        wakeWaiters()
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
        // Originals from iCloud wait for Wi-Fi; switching the download off ends the wait (they are skipped then).
        if waiting.needsICloud, waiting.settings.downloadFromICloud,
            !BackupPolicy.allowsICloudDownload(waiting.settings, network: network)
        {
            return
        }
        resume = nil
        logger.notice("backup: conditions allow it again, the waiting pass resumes")
        Task { await self.run(waiting.settings) }
    }

    private func pause(
        _ reason: BackupPause, settings: BackupSettings, videosOnly: Bool = false, needsChange: Bool = false, needsICloud: Bool = false
    ) {
        resume = Resume(settings: settings, videosOnly: videosOnly, needsChange: needsChange, needsICloud: needsICloud)
        let scope = videosOnly ? ", videos only" : ""
        logger.notice("backup: waiting (\(String(describing: reason), privacy: .public)\(scope, privacy: .public))")
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

    /// The user's pause: the run stops and does not continue by itself. Uploads the system works on are taken back.
    public func cancel() {
        if running != nil || resume != nil { logger.notice("backup: paused by the user") }
        resume = nil
        running?.cancel()
        cancelBackgroundUploads()
    }

    /// The system takes the time away (a background task expires, the background time runs out): the pass stops like
    /// after the user's pause, but it is not shown as "Paused" and stays due: `BackupStatus.isInterrupted` says so, and
    /// whoever gets time again (the next background task, the app coming to the foreground) runs a pass.
    ///
    /// Uploads that were handed to the system go on; that is what they are for.
    public func interrupt() {
        guard let running else { return }
        logger.notice("backup: interrupted by the system")
        interrupting = true
        running.cancel()
    }

    /// Stops for good and waits until nothing runs any more (account removal): a running pass is cancelled, a waiting one
    /// is forgotten, and the engine no longer reacts to network or power changes. A later `run` does nothing.
    public func shutdown() async {
        logger.notice("backup: shut down (account removed)")
        isShutDown = true
        monitor = nil
        resume = nil
        running?.cancel()
        if let background, let ids = journal.map({ Set($0.jobs.keys) }), !ids.isEmpty {
            await background.transport.cancel(jobIds: ids)
        }
        await running?.value
        // The cancelled pass may have ended in a wait (connection lost at the same moment).
        resume = nil
    }

    private func perform(_ settings: BackupSettings, dryRun: Bool, retryFailed: Bool) async {
        resume = nil
        interrupting = false
        settled = []
        status.blocker = nil
        status.isInterrupted = false
        status.uploadedThisPass = 0
        // Logged again for every pass, even when it ends as the last one did.
        loggedPhase = nil
        let kind = (dryRun ? " (dry run: Files does the backup)" : "") + (retryFailed ? ", retrying failed items" : "")
        logger.notice("backup: pass starts\(kind, privacy: .public)")
        guard library.isAuthorized else {
            publish(.notAuthorized)
            return
        }
        status.isLimitedAccess = library.isLimited
        sweepExports()
        if !dryRun, let reason = pauseReason(settings, isVideo: false) {
            pause(reason, settings: settings)
            return
        }
        publish(.scanning)
        do {
            let toUpload = try await scanAndReconcile(settings, retryFailed: retryFailed)
            try refreshCounts()
            if dryRun || toUpload.isEmpty {
                status.lastRun = now()
                // "Up to date" is what the ledger says, not what this pass found to do: items that failed earlier and
                // wait for their next attempt are not in `toUpload`.
                publish(toUpload.isEmpty ? BackupPolicy.finalPhase(failed: status.failed, pending: status.pending) : .idle)
                return
            }
            await remote.removeStaleUploads()
            let waiting = try await upload(toUpload, settings: settings)
            status.lastRun = now()
            try refreshCounts()
            if let waiting {
                pause(waiting.reason, settings: settings, videosOnly: waiting.videosOnly, needsICloud: waiting.needsICloud)
            } else {
                publish(BackupPolicy.finalPhase(failed: status.failed, pending: status.pending))
            }
        } catch  where Task.isCancelled || BackupPolicy.isCancellation(error) {
            // A request that was cancelled in the middle reports it as a network error.
            try? refreshCounts()
            if interrupting {
                interrupting = false
                status.isInterrupted = true
                publish(.idle)
            } else {
                publish(.paused(BackupPause.user.message))
            }
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
        let filesUploaded = settings.filesAppMode == .notUsed ? [] : filesLedger(accountId)
        // Files' record stands for the photo or video itself, not for every resource of the asset.
        let filesPrimary = filesUploaded.isEmpty ? [] : BackupPolicy.filesAppPrimary(resources)
        try removeStaleEntries(ledger: ledger, scanned: resources, everythingScanned: fullScan || retryFailed, now: now)

        var order: [LedgerKey: Int] = [:]
        var work: [BackupResource] = []
        var direct: [BackupResource] = []
        var touched: [BackupResource] = []
        var unknown: [BackupResource] = []
        for (index, resource) in resources.enumerated() {
            let key = LedgerKey(localIdentifier: resource.localIdentifier, kind: resource.kind.rawValue)
            order[key] = index
            let entry = ledger[key]
            let action = BackupPolicy.action(
                for: resource, entry: entry, now: now, retryFailed: retryFailed, retrySkipped: settings.downloadFromICloud)
            switch action {
            case .done, .waiting: continue
            case .touch: touched.append(resource)
            case .upload: direct.append(resource)
            case .reconcile:
                if filesUploaded.contains(resource.localIdentifier), filesPrimary.contains(key) {
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
                // The system reported this upload while the server was asked: it is recorded, and the file the server
                // just listed is that very upload.
                if settled.contains(LedgerKey(resource)) { continue }
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
    ///
    /// With `background`, files up to its size limit are prepared here (name, folder) and handed to the system, a few
    /// ahead of what it has finished; the pass ends when the system has reported all of them, or leaves them to it when it
    /// is interrupted. Larger files are sent in chunks by the app itself, as without `background`; they come last
    /// (`BackupPolicy.uploadOrder`), so that a pass that only gets a short time hands everything else over first.
    func upload(_ work: [BackupResource], settings: BackupSettings) async throws -> Waiting? {
        backgroundStop = nil
        retake = []
        await checkForMissingUploads()
        // What the system reported while the server was asked is done already.
        progress = (work.count { settled.contains(LedgerKey($0)) }, work.count, "")
        defer { progress = nil }
        publishProgress()
        var heldVideos: BackupPause?
        var heldForICloud = false
        let order = BackupPolicy.uploadOrder(work, backgroundLimit: background?.maxFileSize)
        var queue = order.first + order.last
        /// Resources the app sends itself, after everything the system can take.
        var large = Set(order.last.map { LedgerKey($0) })
        /// Exports that turned out too large for the system while smaller files were still waiting.
        var postponed: [LedgerKey: (resource: BackupResource, file: URL)] = [:]
        defer {
            // The pass ended before it got to them: the next one does not have to read them again.
            for (resource, file) in postponed.values { keepOrDiscard(file, of: resource, settings: settings, keep: true) }
        }
        var nameAttempts: [LedgerKey: Int] = [:]
        var index = 0
        while true {
            try Task.checkCancellation()
            try throwBackgroundStop()
            if !retake.isEmpty {
                // Their name was taken meanwhile: once more, with a new look at what is there.
                for resource in retake { nameAttempts[LedgerKey(resource), default: 0] += 1 }
                queue.insert(contentsOf: retake, at: index)
                retake = []
            }
            guard index < queue.count else {
                // The pass is through when the system is.
                guard (journal?.jobs.count ?? 0) + finishing > 0 else { break }
                try await waitForBackgroundUploads()
                if let reason = pauseReason(settings, isVideo: false) { return Waiting(reason: reason) }
                if let reason = await takeBackHeldVideos(settings) { heldVideos = reason }
                continue
            }
            let resource = queue[index]
            let key = LedgerKey(resource)
            index += 1
            if let reason = pauseReason(settings, isVideo: false) { return Waiting(reason: reason) }
            if resource.mediaKind == .video, let reason = pauseReason(settings, isVideo: true) {
                // Photos go on while the videos wait for Wi-Fi.
                heldVideos = reason
                continue
            }
            // With the system since an earlier pass, or reported by it since this one started.
            if journal?.job(for: resource) != nil || settled.contains(key) { continue }
            // The system has to have room for a file it will take; a file the app sends itself does not wait for it.
            while !large.contains(key), backgroundIsFull(adding: resource) {
                try await waitForBackgroundUploads()
                if let reason = pauseReason(settings, isVideo: false) { return Waiting(reason: reason) }
                if let reason = await takeBackHeldVideos(settings) { heldVideos = reason }
            }
            progress?.current = resource.originalName
            publishProgress()
            var file: URL? = postponed.removeValue(forKey: key)?.file
            var handedOver = false
            var keep = false
            defer { if let file { keepOrDiscard(file, of: resource, settings: settings, keep: keep) } }
            let mayDownload = BackupPolicy.allowsICloudDownload(settings, network: network)
            do {
                if nameAttempts[key, default: 0] > Self.maxNameAttempts { throw NetworkError.preconditionFailed }
                let exported: URL
                if let file {
                    exported = file
                } else if let kept = keptExport(of: resource, settings: settings) {
                    exported = kept
                    file = kept
                } else {
                    // Before anything is written: a full device is not this file's fault, and the next one would not fit either.
                    guard BackupPolicy.hasRoom(free: freeSpace(), size: resource.byteSize) else { throw BackupDeviceError.outOfSpace }
                    var written = try await library.export(resource, settings: settings, allowNetwork: mayDownload)
                    file = written
                    if settings.format == .mostCompatible, resource.mediaKind == .image, resource.kind != .raw {
                        written = try PhotoLibrarySource.convertToJPEG(written)
                        file = written
                    }
                    exported = written
                }
                let name = BackupNaming.fileName(
                    originalName: resource.originalName, fileExtension: exported.pathExtension, isVideo: resource.mediaKind == .video,
                    date: resource.createdAt, naming: settings.naming)
                let folder = BackupNaming.folder(base: settings.folder, subfolders: settings.subfolders, date: resource.createdAt)
                // Layer 5: an existing file with the same name and size counts as uploaded; otherwise " (2)".
                if let background, Self.size(of: exported) <= background.maxFileSize {
                    handedOver = try await handOver(resource, file: exported, fileName: name, folder: folder, settings: settings)
                } else if background != nil, !large.contains(key), queue[index...].contains(where: { !large.contains(LedgerKey($0)) }) {
                    // Larger than PhotoKit said (or it did not say): after the files the system can take, like the others.
                    large.insert(key)
                    postponed[key] = (resource, exported)
                    file = nil
                    queue.append(resource)
                    continue
                } else {
                    let uploaded = try await remote.upload(file: exported, fileName: name, folder: folder, capturedAt: resource.createdAt)
                    try await completed(resource, uploaded: uploaded)
                }
            } catch BackupDeviceError.needsICloudDownload where !mayDownload {
                if settings.downloadFromICloud {
                    // It waits for Wi-Fi; that is not a failure.
                    heldForICloud = true
                    continue
                }
                // The user does not want downloads from iCloud: left out until that changes.
                try record(resource, state: .skipped, error: BackupDeviceError.needsICloudDownload.localizedDescription)
            } catch {
                // An upload that was interrupted goes on with the same file (a large one is expensive to read again).
                keep = Task.isCancelled || BackupPolicy.isCancellation(error) || (error as? NetworkError)?.isTransient == true
                // The user's pause is not a failure of this file.
                if Task.isCancelled { throw CancellationError() }
                if let stop = uploadFailed(resource, error: error) { throw stop }
            }
            // An upload that is with the system now is counted when the system reports it.
            if handedOver { continue }
            progress?.done += 1
            try? refreshCounts()
        }
        try throwBackgroundStop()
        if let heldVideos { return Waiting(reason: heldVideos, videosOnly: true, needsICloud: heldForICloud) }
        return heldForICloud ? Waiting(reason: .iCloud, needsICloud: true) : nil
    }

    /// How often a pass prepares an upload again whose name was taken between the name check and the PUT.
    static let maxNameAttempts = 3

    /// The upload of a resource arrived: remembers it, links Live Photo halves, puts the file into the local index.
    private func completed(_ resource: BackupResource, uploaded: UploadedFile) async throws {
        try record(resource, state: .uploaded, matchedBy: .ownUpload, serverPath: uploaded.path, serverFileId: uploaded.fileId)
        status.uploaded += 1
        status.uploadedThisPass += 1
        await linkLivePhoto(resource, uploaded: uploaded)
        await remote.didUpload(uploaded, resource: resource, metadataEditing: metadataEditing)
    }

    /// Deals with the failed upload of one resource. Returns the error that ends the pass, or nil when the pass goes on
    /// (the failure is then recorded and the resource backs off).
    private func uploadFailed(_ resource: BackupResource, error: any Error) -> (any Error)? {
        if BackupPolicy.isCancellation(error) { return CancellationError() }
        if let error = error as? NetworkError, BackupPolicy.endsPass(error) { return error }
        logger.error("backup of \(resource.originalName, privacy: .private) failed: \(error.localizedDescription, privacy: .public)")
        let blocker = BackupPolicy.blocker(for: error)
        // A full quota or a refusal may concern this file only (too big, blocked type): it backs off like any
        // failed file, so the next run starts with another one. A lost login or certificate says nothing about the file.
        // Nor does a full device.
        if blocker != .unauthorized, blocker != .serverTrust, blocker != .deviceStorageFull {
            try? record(resource, state: .failed, error: error.localizedDescription)
        }
        return blocker != nil ? error : nil
    }

    static func size(of file: URL) -> Int64 {
        Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    // MARK: Uploads handed to the system (SPEC §7.18.6)

    func setMissingCheckInterval(_ interval: TimeInterval) { missingCheckInterval = interval }

    /// Uploads that are with the system, by the id it knows them by (tests).
    var backgroundJobs: [String: BackgroundUploadJob] { journal?.jobs ?? [:] }

    /// Whether the next file has to wait until the system has finished some of what it was given.
    private func backgroundIsFull(adding resource: BackupResource) -> Bool {
        guard let background, let journal, !journal.jobs.isEmpty || finishing > 0 else { return false }
        if journal.jobs.count + finishing >= background.maxJobs { return true }
        let size = resource.byteSize ?? 0
        return size <= background.maxFileSize && journal.stagedBytes + size > background.maxStagedBytes
    }

    /// Prepares the upload and hands the file to the system. Returns false when nothing had to be sent because the file
    /// is on the server already.
    private func handOver(_ resource: BackupResource, file: URL, fileName: String, folder: String, settings: BackupSettings) async throws
        -> Bool
    {
        guard let background else { return false }
        // Names of uploads that are on their way are taken, although the server has nothing there yet.
        let prepared = try await remote.prepareUpload(
            file: file, fileName: fileName, folder: folder, capturedAt: resource.createdAt, reserved: journal?.reservedPaths ?? [])
        switch prepared {
        case .existing(let uploaded):
            try await completed(resource, uploaded: uploaded)
            return false
        case .put(let path, var request):
            // The system sends the file whenever it likes; the request itself has to say where it must not go.
            let isVideo = resource.mediaKind == .video
            request.allowsExpensiveNetwork = !(settings.wifiOnly || (isVideo && settings.wifiOnlyForVideos))
            request.allowsConstrainedNetwork = settings.allowLowDataMode
            let job = BackgroundUploadJob(
                id: UUID().uuidString, resource: resource, path: path, size: Self.size(of: file), startedAt: now())
            guard let staged = try journal?.stage(file, id: job.id) else { return false }
            do {
                // Recorded before it starts: a report without a record could not be understood.
                try journal?.add(job)
                try await background.transport.start(jobId: job.id, request: request, file: staged)
            } catch {
                journal?.remove(job.id)
                throw error
            }
            return true
        }
    }

    /// The system reports that an upload has ended, with the server's answer or an error. This may be long after the pass
    /// that handed it over, and in another launch of the app.
    public func backgroundUploadFinished(_ event: BackgroundUploadEvent) async {
        guard let job = journal?.remove(event.jobId) else { return }
        missing.remove(job.id)
        guard !isShutDown else { return }
        finishing += 1
        let result = await finish(job, event: event)
        finishing -= 1
        switch result {
        case .done:
            settled.insert(LedgerKey(job.resource))
            progress?.done += 1
        case .stillToDo:
            settled.insert(LedgerKey(job.resource))
        case .nameTaken:
            // Only a running pass can prepare it again; otherwise the next one does.
            if progress != nil { retake.append(job.resource) }
        }
        try? refreshCounts()
        publishProgress()
        wakeWaiters()
    }

    enum Finished {
        /// Done with for this pass: uploaded, or failed and recorded.
        case done
        /// Not sent (taken back, or the pass was stopped): it stays to do.
        case stillToDo
        /// The server did not take the file because its name was taken after the name check (`If-None-Match: *` → 412).
        /// Nothing was overwritten; the upload is prepared again, which finds the file that is there now (the same size
        /// counts as uploaded) or the next free name.
        case nameTaken
    }

    private func finish(_ job: BackgroundUploadJob, event: BackgroundUploadEvent) async -> Finished {
        do {
            if let error = event.error { throw error }
            guard let response = event.response else { throw NetworkError.invalidResponse("upload without an answer") }
            let uploaded = try await remote.finishUpload(path: job.path, response: response)
            try await completed(job.resource, uploaded: uploaded)
            return .done
        } catch NetworkError.preconditionFailed {
            return .nameTaken
        } catch {
            // Taken back (the user's pause, a video that has to wait for Wi-Fi): still to do, not a failure.
            if BackupPolicy.isCancellation(error) { return .stillToDo }
            guard let stop = uploadFailed(job.resource, error: error) else { return .done }
            // Only a running pass can be stopped; without one the resource simply stays to do.
            if progress != nil, backgroundStop == nil { backgroundStop = stop }
            return .stillToDo
        }
    }

    private func throwBackgroundStop() throws {
        guard let stop = backgroundStop else { return }
        backgroundStop = nil
        throw stop
    }

    private func publishProgress() {
        if let progress {
            publish(.uploading(done: progress.done, total: progress.total, current: progress.current))
        } else {
            statusHandler?(status)
        }
    }

    private func cancelBackgroundUploads() {
        guard let background, let ids = journal.map({ Set($0.jobs.keys) }), !ids.isEmpty else { return }
        Task { await background.transport.cancel(jobIds: ids) }
    }

    /// Videos that were handed over on Wi-Fi must not go on over a cellular connection. The system would let them wait
    /// and they would block the queue for the photos, so they are taken back; they are handed over again on Wi-Fi.
    private func takeBackHeldVideos(_ settings: BackupSettings) async -> BackupPause? {
        guard let background, let journal, let reason = pauseReason(settings, isVideo: true) else { return nil }
        let ids = Set(journal.jobs.values.filter { $0.resource.mediaKind == .video }.map(\.id))
        guard !ids.isEmpty else { return nil }
        await background.transport.cancel(jobIds: ids)
        return reason
    }

    /// Gives up uploads the system no longer knows and never reported (it was reset, or the report got lost). They are
    /// given up the second time they are found missing, so a report that is just on its way is not overtaken. The
    /// resources stay to do: the next pass finds the file on the server or uploads it again.
    private func checkForMissingUploads() async {
        guard let background, let ids = journal.map({ Set($0.jobs.keys) }), !ids.isEmpty else {
            missing = []
            return
        }
        lastMissingCheck = Date()
        let active = await background.transport.activeJobIds()
        let gone = ids.subtracting(active)
        for id in gone.intersection(missing) where journal?.remove(id) != nil {
            logger.notice("an upload handed to the system was lost; it is done again")
        }
        missing = gone.subtracting(missing)
    }

    private func wakeWaiters() {
        let waiting = waiters
        waiters = [:]
        for continuation in waiting.values { continuation.resume() }
    }

    private func wake(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }

    /// Waits until the system reports an upload, the network or power state changes, or some time has passed. Throws when
    /// the pass was cancelled or a reported upload ends it.
    private func waitForBackgroundUploads() async throws {
        let id = UUID()
        let interval = missingCheckInterval
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            await self?.wake(id)
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume() } else { waiters[id] = continuation }
            }
        } onCancel: {
            Task { await self.wake(id) }
        }
        timeout.cancel()
        try Task.checkCancellation()
        try throwBackgroundStop()
        if Date().timeIntervalSince(lastMissingCheck) >= interval { await checkForMissingUploads() }
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

    /// The counts of the status are those of the ledger: what failed stays "failed" (and not "up to date") until it is
    /// uploaded, also across passes that do not touch it because it waits for its next attempt.
    func refreshCounts() throws {
        let (counts, lastFailure) = try database.writer.read { db in
            let counts = try Row.fetchAll(db, sql: "SELECT state, count(*) AS n FROM backupAsset GROUP BY state").reduce(
                into: [String: Int]()
            ) {
                $0[$1["state"]] = $1["n"]
            }
            let lastFailure = try String.fetchOne(
                db, sql: "SELECT lastError FROM backupAsset WHERE state = ? AND lastError IS NOT NULL ORDER BY updatedAt DESC LIMIT 1",
                arguments: [BackupItemState.failed.rawValue])
            return (counts, lastFailure)
        }
        status.uploaded = counts[BackupItemState.uploaded.rawValue] ?? 0
        status.matched = counts[BackupItemState.matched.rawValue] ?? 0
        status.failed = counts[BackupItemState.failed.rawValue] ?? 0
        status.pending = counts[BackupItemState.pending.rawValue] ?? 0
        status.skipped = counts[BackupItemState.skipped.rawValue] ?? 0
        status.lastFailure = lastFailure
    }

    /// Removes entries of resources that are no longer there to upload (the photo was deleted on the device, the options
    /// no longer select it, an edit was reverted). They were never uploaded, and nothing would ever change them again:
    /// the backup could not become "up to date".
    ///
    /// An asset with a pending entry is always scanned, so a pending entry without a scanned resource is stale. A failed
    /// one is only scanned again when its waiting time is over, a skipped one only in a scan of everything.
    func removeStaleEntries(ledger: [LedgerKey: BackupLedgerEntry], scanned: [BackupResource], everythingScanned: Bool, now: Date) throws {
        let found = Set(scanned.map { LedgerKey($0) })
        let stale = ledger.filter { key, entry in
            guard !found.contains(key), journal?.jobs.values.contains(where: { LedgerKey($0.resource) == key }) != true else {
                return false
            }
            switch BackupItemState(rawValue: entry.state) {
            case .pending: return true
            case .failed: return everythingScanned || !BackupPolicy.isBackingOff(entry, now: now)
            case .skipped: return everythingScanned
            default: return false
            }
        }
        guard !stale.isEmpty else { return }
        try database.writer.write { db in
            for key in stale.keys {
                try db.execute(
                    sql: "DELETE FROM backupAsset WHERE localIdentifier = ? AND resourceKind = ?",
                    arguments: [key.localIdentifier, key.kind])
            }
        }
    }

    // MARK: Exported files

    /// The directory an interrupted upload's export waits in for the next attempt.
    private func keptDirectory(of resource: BackupResource, settings: BackupSettings) -> URL? {
        guard let exportDirectory else { return nil }
        // Another edit, another size or another format is another file.
        let identity =
            "\(resource.localIdentifier)|\(resource.kind.rawValue)|\(resource.modifiedAt?.timeIntervalSince1970 ?? 0)|\(resource.byteSize ?? -1)|\(settings.format.rawValue)"
        let name = SHA256.hash(data: Data(identity.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return exportDirectory.appending(path: "\(Self.keptFolder)/\(name)")
    }

    static let keptFolder = "Kept"
    static let keptInfoFile = "resource.json"

    /// What a kept export belongs to, next to it, so that it can be told later whether anybody still needs it.
    struct KeptExport: Codable {
        var localIdentifier: String
        var kind: String
        var keptAt: Date
    }

    /// The export an earlier, interrupted attempt left for this resource.
    private func keptExport(of resource: BackupResource, settings: BackupSettings) -> URL? {
        guard let directory = keptDirectory(of: resource, settings: settings) else { return nil }
        let files =
            (try? FileManager.default.contentsOfDirectory(at: directory.appending(path: "data"), includingPropertiesForKeys: nil)) ?? []
        guard let file = files.first, Self.size(of: file) > 0 else { return nil }
        return file
    }

    /// What happens to an exported file when the engine is done with it: removed, or, when its upload was interrupted and
    /// it is large, put aside for the next attempt (`keep`).
    private func keepOrDiscard(_ file: URL, of resource: BackupResource, settings: BackupSettings, keep: Bool) {
        let files = FileManager.default
        let directory = file.deletingLastPathComponent()
        let kept = keptDirectory(of: resource, settings: settings)
        let isKept = kept.map { directory.standardizedFileURL.path == $0.appending(path: "data").standardizedFileURL.path } ?? false
        guard keep, let kept, files.fileExists(atPath: file.path(percentEncoded: false)),
            Self.size(of: file) >= keptExportMinimumSize
        else {
            try? files.removeItem(at: isKept ? directory.deletingLastPathComponent() : directory)
            return
        }
        if isKept { return }
        do {
            try? files.removeItem(at: kept)
            try files.createDirectory(at: kept, withIntermediateDirectories: true)
            try files.moveItem(at: directory, to: kept.appending(path: "data"))
            let info = KeptExport(localIdentifier: resource.localIdentifier, kind: resource.kind.rawValue, keptAt: now())
            try JSONEncoder().encode(info).write(to: kept.appending(path: Self.keptInfoFile))
        } catch {
            try? files.removeItem(at: directory)
            try? files.removeItem(at: kept)
        }
    }

    /// Removes what earlier runs left in the export directory, once, before the first pass of this engine: exports of a
    /// pass that did not end (the app was ended in the middle), and kept exports nobody needs any more (their resource is
    /// uploaded, gone from the ledger, or they are old).
    func sweepExports() {
        guard let exportDirectory, !exportsSwept else { return }
        exportsSwept = true
        let files = FileManager.default
        let ledger = (try? loadLedger()) ?? [:]
        for url in (try? files.contentsOfDirectory(at: exportDirectory, includingPropertiesForKeys: nil)) ?? [] {
            guard url.lastPathComponent == Self.keptFolder else {
                try? files.removeItem(at: url)
                continue
            }
            for kept in (try? files.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [] {
                if !isNeeded(kept, ledger: ledger) { try? files.removeItem(at: kept) }
            }
        }
    }

    private func isNeeded(_ kept: URL, ledger: [LedgerKey: BackupLedgerEntry]) -> Bool {
        guard let data = try? Data(contentsOf: kept.appending(path: Self.keptInfoFile)),
            let info = try? JSONDecoder().decode(KeptExport.self, from: data),
            now().timeIntervalSince(info.keptAt) < BackupPolicy.keptExportAge,
            let entry = ledger[LedgerKey(localIdentifier: info.localIdentifier, kind: info.kind)]
        else { return false }
        return !BackupPolicy.isComplete(entry) && !BackupPolicy.isSkipped(entry)
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
        cancelBackgroundUploads()
        resume = nil
        status = BackupStatus()
    }
}

extension BackupEngine.LedgerKey {
    init(_ resource: BackupResource) {
        self.init(localIdentifier: resource.localIdentifier, kind: resource.kind.rawValue)
    }
}
