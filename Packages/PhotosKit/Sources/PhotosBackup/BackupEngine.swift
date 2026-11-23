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
    /// Everything this app has uploaded so far (the ledger's count).
    public var uploaded = 0
    /// What the current or last pass uploaded.
    public var uploadedThisPass = 0
    public var matched = 0
    public var pending = 0
    public var failed = 0
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
        case .idle, .notAuthorized, .paused, .upToDate, .failed: false
        }
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

    struct Resume {
        var settings: BackupSettings
        /// Only videos wait (Wi-Fi only for videos); everything else went through.
        var videosOnly: Bool
        /// A request failed although the path looked fine: wait for the next change instead of trying again at once.
        var needsChange: Bool
    }

    static let scanSignatureKey = "backup.scanSignature"

    /// - Parameter background: hand uploads to a background transfer session, so they go on while the app is suspended.
    ///   Without it every upload is sent by the app itself.
    public init(api: PhotosAPI, database: AccountDatabase, accountId: AccountID, background: BackgroundUploads? = nil) {
        self.init(
            library: PhotoLibrarySource(), remote: PhotosBackupRemote(api: api, library: LibraryStore(database: database), database: database),
            database: database, accountId: accountId, systemConditions: true, background: background)
    }

    /// - Parameter systemConditions: watch the network path and Low Power Mode. Tests pass `false` and call
    ///   `setNetwork` / `setLowPower` themselves.
    init(
        library: any BackupLibrary, remote: any BackupRemote, database: AccountDatabase, accountId: AccountID,
        systemConditions: Bool = false, background: BackgroundUploads? = nil, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.background = background
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

    private func publish(_ phase: BackupStatus.Phase) {
        status.phase = phase
        statusHandler?(status)
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

    /// The user's pause: the run stops and does not continue by itself. Uploads the system works on are taken back.
    public func cancel() {
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
        interrupting = true
        running.cancel()
    }

    /// Stops for good and waits until nothing runs any more (account removal): a running pass is cancelled, a waiting one
    /// is forgotten, and the engine no longer reacts to network or power changes. A later `run` does nothing.
    public func shutdown() async {
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
            await remote.removeStaleUploads()
            let waiting = try await upload(toUpload, settings: settings)
            status.lastRun = now()
            try refreshCounts()
            if let waiting {
                pause(waiting.reason, settings: settings, videosOnly: waiting.videosOnly)
            } else {
                publish(status.pending == 0 ? .upToDate : .idle)
            }
        } catch where Task.isCancelled || BackupPolicy.isCancellation(error) {
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
    /// is interrupted. Larger files are sent in chunks by the app itself, as without `background`.
    func upload(_ work: [BackupResource], settings: BackupSettings) async throws -> (reason: BackupPause, videosOnly: Bool)? {
        backgroundStop = nil
        await checkForMissingUploads()
        // What the system reported while the server was asked is done already.
        progress = (work.count { settled.contains(LedgerKey($0)) }, work.count, "")
        defer { progress = nil }
        publishProgress()
        var heldVideos: BackupPause?
        for resource in work {
            try Task.checkCancellation()
            try throwBackgroundStop()
            if let reason = pauseReason(settings, isVideo: false) { return (reason, false) }
            if resource.mediaKind == .video, let reason = pauseReason(settings, isVideo: true) {
                // Photos go on while the videos wait for Wi-Fi.
                heldVideos = reason
                continue
            }
            // With the system since an earlier pass, or reported by it since this one started.
            if journal?.job(for: resource) != nil || settled.contains(LedgerKey(resource)) { continue }
            while backgroundIsFull(adding: resource) {
                try await waitForBackgroundUploads()
                if let reason = pauseReason(settings, isVideo: false) { return (reason, false) }
                if let reason = await takeBackHeldVideos(settings) { heldVideos = reason }
            }
            progress?.current = resource.originalName
            publishProgress()
            var file: URL?
            var handedOver = false
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
                if let background, Self.size(of: exported) <= background.maxFileSize {
                    handedOver = try await handOver(resource, file: exported, fileName: name, folder: folder, settings: settings)
                } else {
                    let uploaded = try await remote.upload(file: exported, fileName: name, folder: folder, capturedAt: resource.createdAt)
                    try await completed(resource, uploaded: uploaded)
                }
            } catch {
                // The user's pause is not a failure of this file.
                if Task.isCancelled { throw CancellationError() }
                if let stop = uploadFailed(resource, error: error) { throw stop }
            }
            // An upload that is with the system now is counted when the system reports it.
            if handedOver { continue }
            progress?.done += 1
            status.pending = max(0, status.pending - 1)
        }
        // The pass is through when the system is.
        while (journal?.jobs.count ?? 0) + finishing > 0 {
            try await waitForBackgroundUploads()
            if let reason = pauseReason(settings, isVideo: false) { return (reason, false) }
            if let reason = await takeBackHeldVideos(settings) { heldVideos = reason }
        }
        try throwBackgroundStop()
        return heldVideos.map { ($0, true) }
    }

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
        if let error = error as? NetworkError, error.isTransient { return error }
        logger.error("backup of \(resource.originalName, privacy: .private) failed: \(error.localizedDescription, privacy: .public)")
        let blocker = BackupPolicy.blocker(for: error)
        // A full quota or a refusal may concern this file only (too big, blocked type): it backs off like any
        // failed file, so the next run starts with another one. A lost login or certificate says nothing about the file.
        if blocker != .unauthorized, blocker != .serverTrust {
            try? record(resource, state: .failed, error: error.localizedDescription)
            status.failed += 1
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
        let counts = await finish(job, event: event)
        finishing -= 1
        settled.insert(LedgerKey(job.resource))
        if counts {
            progress?.done += 1
            status.pending = max(0, status.pending - 1)
        }
        publishProgress()
        wakeWaiters()
    }

    /// Returns whether the resource is done with for this pass (uploaded, or failed and recorded).
    private func finish(_ job: BackgroundUploadJob, event: BackgroundUploadEvent) async -> Bool {
        do {
            if let error = event.error { throw error }
            guard let response = event.response else { throw NetworkError.invalidResponse("upload without an answer") }
            let uploaded = try await remote.finishUpload(path: job.path, response: response)
            try await completed(job.resource, uploaded: uploaded)
            return true
        } catch {
            // Taken back (the user's pause, a video that has to wait for Wi-Fi): still to do, not a failure.
            if BackupPolicy.isCancellation(error) { return false }
            guard let stop = uploadFailed(job.resource, error: error) else { return true }
            // Only a running pass can be stopped; without one the resource simply stays to do.
            if progress != nil, backgroundStop == nil { backgroundStop = stop }
            return false
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
