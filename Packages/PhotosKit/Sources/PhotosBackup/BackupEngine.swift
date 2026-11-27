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

/// Camera-roll backup with duplicate protection (SPEC §7.18).
public actor BackupEngine {
    // What the extensions in BackupEngine+*.swift share is internal rather than private (SPEC §20.7).
    let library: any BackupLibrary
    let remote: any BackupRemote
    let database: AccountDatabase
    let accountId: AccountID
    let now: @Sendable () -> Date
    let logger = Logger(subsystem: "com.nextcloud.photos", category: "backup")
    private var running: Task<Void, Never>?
    var status = BackupStatus()
    var statusHandler: (@Sendable (BackupStatus) -> Void)?
    private var monitor: SystemConditionsMonitor?
    var network: BackupNetwork?
    private var lowPower: Bool
    /// Set while a run waits for better conditions; cleared when it resumes or the user pauses.
    var resume: Resume?
    /// Set by `shutdown()`: the account is going away, nothing may start again.
    var isShutDown = false
    /// Set by `interrupt()` for the pass it stops.
    private var interrupting = false
    /// Set by the user's pause: chunked uploads are not handed further to the system until the next pass.
    var handOverPaused = false
    /// One piece of work on chunked uploads at a time (a report and a hand-over must not work on two copies of the state).
    let chunkedGate = AsyncGate()
    var metadataEditing = false

    // Uploads handed to the system (SPEC §7.18.6); all nil or empty without `background`.
    nonisolated let background: BackgroundUploads?
    var journal: BackgroundUploadJournal?
    /// Uploads the system reported that are still being recorded.
    var finishing = 0
    /// What an upload the system reported means for the running pass: the error that ends it.
    var backgroundStop: (any Error)?
    /// The pass waits here for the system (for room to hand over the next file, or for the last uploads).
    var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// Resources whose upload the system reported since the pass started.
    var settled: Set<LedgerKey> = []
    /// Uploads the system no longer knows although nothing was reported, seen once. Seen twice, they are given up.
    var missing: Set<String> = []
    var lastMissingCheck = Date.distantPast
    /// How long the pass waits for a report before it asks the system what it is still working on.
    var missingCheckInterval: TimeInterval = 60
    /// How many resources are checked against the server before the uploads of a round start (one SEARCH for up to 200).
    var serverCheckChunk = 200
    /// Counts of the upload phase of the running pass.
    var progress: (done: Int, total: Int, current: String)?
    /// The asset whose resource this app is exporting or sending right now (`BackupStatus.uploadingIdentifiers`).
    var currentUpload: String?
    /// Assets the user asked to back up now (a selection in the Library, SPEC §21.1): they go first, and a failed one
    /// does not wait for its next attempt. Cleared when they are on the server.
    var priority: Set<String> = []
    /// Uploads of the running pass's earlier rounds (`done`), and resources that later rounds check first (`later`).
    var passUploads = (done: 0, later: 0)
    /// The running pass removed what interrupted uploads left on the server.
    var cleanedUp = false
    /// The running pass looked for uploads the system lost.
    var missingChecked = false
    /// Uploads the server refused because their name was taken meanwhile (412): the running pass prepares them again.
    var retake: [BackupResource] = []
    /// Where the library writes its exports (`PhotoLibrarySource.exportDirectory`); nil: nothing is kept or swept.
    let exportDirectory: URL?
    var exportsSwept = false
    var keptExportMinimumSize = BackupPolicy.keptExportMinimumSize
    /// What the Files app uploaded (SPEC §7.18.5).
    let filesLedger: @Sendable (AccountID) -> Set<String>
    /// Free space on this device, when it can be told.
    var freeSpace: @Sendable () -> Int64?
    /// "Most compatible": the file to upload for an export (`MostCompatible.convert`).
    let convert: @Sendable (URL, BackupResource) async throws -> URL
    /// The journal of the jobs PhotoKit's background-upload extension created (`UploadJobJournal`): those resources are
    /// PhotoKit's to send, and their destinations are taken.
    let uploadJobs: URL?

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

    /// - Parameters:
    ///   - background: hand uploads to a background transfer session, so they go on while the app is suspended. Without it
    ///     every upload is sent by the app itself.
    ///   - uploadJobs: the journal of PhotoKit's background-upload extension (`UploadJobJournal.file(in:)`).
    public init(
        api: PhotosAPI, database: AccountDatabase, accountId: AccountID, background: BackgroundUploads? = nil, uploadJobs: URL? = nil
    ) {
        self.init(
            library: PhotoLibrarySource(),
            remote: PhotosBackupRemote(api: api, library: LibraryStore(database: database), database: database),
            database: database, accountId: accountId, systemConditions: true, background: background,
            exportDirectory: PhotoLibrarySource.exportDirectory, uploadJobs: uploadJobs)
    }

    /// - Parameter systemConditions: watch the network path and Low Power Mode. Tests pass `false` and call
    ///   `setNetwork` / `setLowPower` themselves.
    init(
        library: any BackupLibrary, remote: any BackupRemote, database: AccountDatabase, accountId: AccountID,
        systemConditions: Bool = false, background: BackgroundUploads? = nil, exportDirectory: URL? = nil, uploadJobs: URL? = nil,
        filesLedger: @escaping @Sendable (AccountID) -> Set<String> = { FilesAppLedger.uploadedAssets(accountId: $0) },
        convert: @escaping @Sendable (URL, BackupResource) async throws -> URL = { try await MostCompatible.convert($0, resource: $1) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.background = background
        self.convert = convert
        self.uploadJobs = uploadJobs
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
        #if os(tvOS) || os(watchOS)
            // Not on Apple TV and Apple Watch (no backup there, SPEC §15.3): the plain free capacity.
            let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        #else
            let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
            if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        #endif
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    func publish(_ phase: BackupStatus.Phase) {
        status.phase = phase
        status.uploadingIdentifiers = inFlightIdentifiers
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
        // Backup is off: large files that wait in the container for their chunks are given up.
        if !settings.isEnabled { discardChunkedUploads() }
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
        handOverPaused = true
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
        if let background, let ids = journal?.allJobIds, !ids.isEmpty {
            await background.transport.cancel(jobIds: ids)
        }
        await running?.value
        // The cancelled pass may have ended in a wait (connection lost at the same moment).
        resume = nil
    }

    private func perform(_ settings: BackupSettings, dryRun: Bool, retryFailed: Bool) async {
        resume = nil
        interrupting = false
        handOverPaused = false
        settled = []
        status.blocker = nil
        status.isInterrupted = false
        status.uploadedThisPass = 0
        passUploads = (0, 0)
        cleanedUp = false
        missingChecked = false
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
            let work = try scan(settings, retryFailed: retryFailed)
            var outcome = try await process(work, settings: settings, dryRun: dryRun)
            if case .done(let held, let toUpload) = outcome, work.fullScanDue {
                // The daily look at the whole library, after this pass did what it knew of: background time goes to uploads.
                logger.info("backup: the whole library is looked at again")
                publish(.scanning)
                let more = try scan(settings, retryFailed: false, wholeLibrary: true)
                outcome = try await process(more, settings: settings, dryRun: dryRun, held: held)
                if case .done(let held, let found) = outcome { outcome = .done(held: held, toUpload: toUpload || found) }
            }
            status.lastRun = now()
            try refreshCounts()
            switch outcome {
            case .stopped(let waiting):
                pause(waiting.reason, settings: settings, videosOnly: waiting.videosOnly, needsICloud: waiting.needsICloud)
            case .done(let held?, _):
                pause(held.reason, settings: settings, videosOnly: held.videosOnly, needsICloud: held.needsICloud)
            case .done(nil, let toUpload):
                // What the user asked for was tried; failed ones wait for their next attempt like the others.
                priority = []
                // "Up to date" is what the ledger says, not what this pass found to do: items that failed earlier and
                // wait for their next attempt were not part of it.
                publish(dryRun && toUpload ? .idle : BackupPolicy.finalPhase(failed: status.failed, pending: status.pending))
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
}
