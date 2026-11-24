// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import OSLog
import Observation
import Photos
import PhotosBackup
import PhotosModel
import PhotosNetworking
import Synchronization

#if os(iOS)
    import UIKit
#endif

/// How a backup pass ended, for callers that have to tell the user (the "Back up now" App Intent, background tasks).
public enum BackupOutcome: Sendable, Equatable {
    /// Everything on this device is on the server.
    case upToDate
    /// The pass ran to its end. `remaining` items are still waiting (for example videos that wait for Wi-Fi).
    case finished(uploaded: Int, remaining: Int, failed: Int)
    /// Stopped before the end; the reason is ready to show ("Waiting for Wi-Fi").
    case paused(String)
    case failed(String)
    /// Stopped by something only the user can fix: full storage, an expired login, a refused upload, an untrusted certificate.
    case blocked(BackupStatus.Blocker)
    /// No access to the photo library.
    case notAuthorized
    /// Backup could not start at all: it is turned off, or its account is signed out.
    case unavailable(String)

    /// The system stopped the pass before its end (the background time ran out); it goes on at the next opportunity.
    case interrupted(uploaded: Int)
    /// Everything that may be uploaded is, but this many items were left out: their originals are only in iCloud and
    /// "Download originals from iCloud" is off.
    case skipped(Int)

    /// Derives the outcome from the engine's status after a pass.
    public init(status: BackupStatus) {
        switch status.phase {
        case .upToDate: self = status.skipped > 0 ? .skipped(status.skipped) : .upToDate
        // The pass ran to its end, but items failed (now or in an earlier pass, still waiting for their next attempt).
        case .incomplete(let failed):
            self = .finished(uploaded: status.uploadedThisPass, remaining: status.pending, failed: failed)
        // A pause is the final state of a pass now: the engine keeps it until the run continues (by itself when the
        // network or power state allows it, or with the next pass after the user's pause).
        case .paused(let reason): self = .paused(reason)
        case .failed(let message):
            if let blocker = status.blocker { self = .blocked(blocker) } else { self = .failed(message) }
        case .notAuthorized: self = .notAuthorized
        case .idle where status.isInterrupted: self = .interrupted(uploaded: status.uploadedThisPass)
        case .idle, .scanning, .reconciling, .uploading:
            // What this pass uploaded, not the ledger's count of everything that was ever uploaded.
            self = .finished(uploaded: status.uploadedThisPass, remaining: status.pending, failed: status.failed)
        }
    }

    /// The outcome for the log: its name and counts, no messages (they can name the account or the server).
    public var logName: String {
        switch self {
        case .upToDate: "up to date"
        case .finished(let uploaded, let remaining, let failed): "finished: uploaded \(uploaded), remaining \(remaining), failed \(failed)"
        case .paused: "paused"
        case .failed: "failed"
        case .blocked(let blocker): "blocked (\(blocker))"
        case .notAuthorized: "not authorized"
        case .unavailable: "unavailable"
        case .interrupted(let uploaded): "interrupted after \(uploaded) uploads"
        case .skipped(let count): "up to date, \(count) skipped"
        }
    }

    /// True when nothing is left to do.
    public var isComplete: Bool {
        switch self {
        case .upToDate: true
        case .finished(_, let remaining, let failed): remaining == 0 && failed == 0
        default: false
        }
    }

    /// One sentence for the user.
    public var message: String {
        switch self {
        case .upToDate: String(localized: "Your photos are backed up.", bundle: .module)
        case .finished(let uploaded, let remaining, let failed):
            if failed > 0 {
                String(localized: "Backup finished, but \(failed) items could not be uploaded.", bundle: .module)
            } else if remaining > 0 {
                String(localized: "\(uploaded) items were backed up, \(remaining) are still waiting.", bundle: .module)
            } else {
                String(localized: "Backup finished.", bundle: .module)
            }
        case .paused(let reason): String(localized: "Backup is paused: \(reason)", bundle: .module)
        case .interrupted:
            String(localized: "Backup was interrupted. It continues the next time Nextcloud Photos is running.", bundle: .module)
        case .failed(let message): String(localized: "Backup failed: \(message)", bundle: .module)
        case .blocked(let blocker):
            switch blocker {
            case .insufficientStorage: String(localized: "Backup stopped: your Nextcloud storage is full.", bundle: .module)
            case .unauthorized: String(localized: "Backup stopped: log in to your Nextcloud again.", bundle: .module)
            case .forbidden: String(localized: "Backup stopped: the server does not allow uploads to the backup folder.", bundle: .module)
            case .serverTrust: String(localized: "Backup stopped: the connection to your Nextcloud is not trusted.", bundle: .module)
            case .deviceStorageFull:
                #if os(macOS)
                    String(localized: "Backup stopped: free up space on this Mac.", bundle: .module)
                #else
                    String(localized: "Backup stopped: free up space on this device.", bundle: .module)
                #endif
            }
        case .skipped(let count):
            String(
                localized:
                    "Backup finished. \(count) items that are only in iCloud were not backed up, because downloading from iCloud is turned off.",
                bundle: .module)
        case .notAuthorized: String(localized: "Nextcloud Photos has no access to your photos.", bundle: .module)
        case .unavailable(let reason): reason
        }
    }

    /// The sentence for the user, with what the outcome cannot know: with access to selected photos only, "your photos
    /// are backed up" would promise too much.
    public func message(limitedAccess: Bool) -> String {
        guard limitedAccess else { return message }
        switch self {
        case .notAuthorized, .unavailable: return message
        default:
            let note = String(localized: "Only the photos you selected for Nextcloud Photos are backed up.", bundle: .module)
            return message + " " + note
        }
    }
}

/// The latest status of the engine, written from the engine's actor and read after a pass.
private final class BackupStatusBox: Sendable {
    private let status = Mutex(BackupStatus())

    var value: BackupStatus { status.withLock { $0 } }

    func set(_ value: BackupStatus) { status.withLock { $0 = value } }
}

/// Backup state for the UI and background tasks (SPEC §7.18).
///
/// There is one backup per app, set up for one account (`BackupSettings.accountId`). It runs for that account whichever
/// account is shown: while another account is active it uses its own `AccountServices` for the backup account.
@MainActor
@Observable
public final class BackupModel {
    public private(set) var settings: BackupSettings
    public private(set) var status = BackupStatus()
    public private(set) var authorization: PHAuthorizationStatus = PhotoLibrarySource.authorization
    @ObservationIgnored private var engine: BackupEngine?
    /// The services the engine was built on.
    @ObservationIgnored private var engineServices: AccountServices?
    @ObservationIgnored private var engineConfigured = false
    @ObservationIgnored private var statusBox = BackupStatusBox()
    /// Services of the backup account while another account is the active one.
    @ObservationIgnored private var ownServices: AccountServices?
    @ObservationIgnored private var runningPasses = 0
    /// The app's background transfer session, where it has one (iOS): uploads go on while the app is suspended.
    @ObservationIgnored private(set) var backgroundUploads: (any BackgroundUploading)?
    @ObservationIgnored private var backgroundEvents: Task<Void, Never>?
    @ObservationIgnored private var observer: LibraryObserver?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored let settingsFile: URL
    /// State changes of the backup, for Settings › Export diagnostics. No account names, servers or paths in public
    /// strings; the engine logs its phases under the same category.
    @ObservationIgnored private let logger = Logger(subsystem: "com.nextcloud.photos", category: "backup")
    /// The first check before backup is turned on (`preview`), while it runs.
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    public private(set) var isPreviewing = false
    /// A pass runs in a continued processing task with system progress (iOS, `startBackup`).
    public internal(set) var isInContinuedTask = false
    /// "Keep screen on while backing up" (iOS): the screen doesn't lock while a pass runs and the app is in front. A
    /// preference of this device, kept in the app's defaults.
    public var keepScreenOn = false {
        didSet {
            app?.defaults.set(keepScreenOn, forKey: Self.keepScreenOnKey)
            #if os(iOS)
                updateIdleTimer()
            #endif
        }
    }
    static let keepScreenOnKey = "backup.keepScreenOn"
    #if os(iOS)
        /// The idle timer is off because of the backup (and only then is it turned on again here).
        @ObservationIgnored var holdsIdleTimer = false
    #endif

    init(settingsFile: URL = AppPaths.layout.backupSettingsFile) {
        self.settingsFile = settingsFile
        settings = BackupSettings.load(from: settingsFile)
    }

    /// Connects the model to the app. Options left behind by an account that no longer exists are discarded.
    func attach(_ app: AppModel) {
        self.app = app
        if let id = settings.accountId, !app.accounts.contains(where: { $0.id == id }) { forgetSettings() }
        keepScreenOn = app.defaults.bool(forKey: Self.keepScreenOnKey)
        #if os(iOS)
            observeIdleTimer()
        #endif
        #if os(iOS)
            // A pass that a background task had to give up goes on as soon as the app is in front again. The model lives
            // as long as the app, so the observer is never removed.
            NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) {
                [weak self] _ in
                Task { @MainActor in await self?.resumeIfInterrupted() }
            }
        #endif
    }

    /// Gives the backup a background transfer session and starts listening to what the system reports about it. Called
    /// once, before the first engine exists.
    func attachBackgroundUploads(_ transport: any BackgroundUploading) {
        backgroundUploads = transport
        backgroundEvents = Task { [weak self] in
            for await signal in transport.signals {
                switch signal {
                case .finished(let event): await self?.backgroundUploadFinished(event)
                // Everything that finished while the app was not running has been recorded: the system may suspend it again.
                case .drained: transport.eventsHandled()
                }
            }
        }
    }

    /// The system reports the end of an upload, possibly one that an earlier launch handed over. The engine of the backup
    /// account has the record of what it was. Without an engine (the account is signed out) the report is dropped; the
    /// record is then found stale by the next pass and the file is looked up on the server.
    func backgroundUploadFinished(_ event: BackgroundUploadEvent) async {
        guard let engine = await configuredEngine() else {
            logger.notice("backup: an upload the system finished is dropped, the backup account is not available")
            return
        }
        await engine.backgroundUploadFinished(event)
    }

    public var isAvailable: Bool {
        #if os(visionOS)
            false
        #else
            true
        #endif
    }

    /// The Files app is installed and readable (same Apple team).
    public var filesAppDetected: Bool { FilesAppLedger.isAvailable }

    /// The account that is backed up: the one backup was set up for, otherwise the active one.
    public var account: Account? {
        guard let app else { return nil }
        if let id = settings.accountId { return app.accounts.first { $0.id == id } }
        return app.session?.account
    }

    /// True when backup is set up for an account other than the one on screen; the Backup screen says so.
    public var isForOtherAccount: Bool {
        guard let account, let active = app?.session?.account else { return false }
        return account.id != active.id
    }

    public func update(_ change: (inout BackupSettings) -> Void) {
        let wasEnabled = settings.isEnabled
        change(&settings)
        if settings.isEnabled != wasEnabled { logger.notice("backup: turned \(self.settings.isEnabled ? "on" : "off", privacy: .public)") }
        try? settings.save(to: settingsFile)
        guard let engine else { return }
        let settings = settings
        Task {
            if !settings.isEnabled { await engine.cancel() }
            // A run that waits (for Wi-Fi, Low Power Mode to end …) continues with the new options, at once when the
            // change lifts what it was waiting for.
            await engine.settingsChanged(settings)
        }
    }

    public func requestAuthorization() async {
        authorization = await PhotoLibrarySource.requestAuthorization()
    }

    /// Only the photos the user selected can be seen (and backed up).
    public var hasLimitedAccess: Bool { authorization == .limited }

    /// Reads the access again (the user comes back from Settings).
    public func refreshAuthorization() {
        authorization = PhotoLibrarySource.authorization
    }

    /// Turns backup on for the active account and runs the first pass.
    public func enable(mode: BackupSettings.FilesAppMode) async {
        guard let session = app?.session else { return }
        // The first check stops; what it found is in the ledger, and the first pass goes on from there.
        await cancelPreview()
        logger.notice("backup: set up, Files app mode \(String(describing: mode), privacy: .public)")
        update {
            $0.accountId = session.account.id
            $0.filesAppMode = mode
            if mode == .switchedFromFiles, let files = FilesAppLedger.settings() {
                $0.adoptFilesAppDefaults(files)
            } else if $0.folder == "/Photos" {
                $0.folder = session.features.userConfig.photosLocation
            }
            $0.isEnabled = mode != .keepFiles
        }
        await startBackup()
    }

    // MARK: First run (SPEC §7.18.1 step 3)

    /// Checks which photos of this device are already on the server before backup is turned on: a dry run for the
    /// active account that records what it finds in the ledger (`assetCounts()`), so that the first pass does not ask
    /// the server again. `status` reports its progress. Returns when it has ended or was stopped by `enable`.
    ///
    /// - Parameter includeFilesApp: also count what the Nextcloud Files app uploaded (SPEC §7.18.5).
    public func preview(includeFilesApp: Bool) async {
        guard !settings.isEnabled, settings.filesAppMode != .keepFiles, previewTask == nil, let session = app?.session else { return }
        // Backup is not set up: it belongs to the account on screen.
        if settings.accountId != session.account.id { update { $0.accountId = session.account.id } }
        let task = Task { [weak self] in
            guard let self, let engine = await self.configuredEngine() else { return }
            var dryRun = self.settings
            dryRun.filesAppMode = includeFilesApp ? .switchedFromFiles : .notUsed
            let box = self.statusBox
            self.authorization = PhotoLibrarySource.authorization
            self.runningPasses += 1
            self.logger.notice("backup: first check before it is turned on")
            await engine.run(dryRun, dryRun: true)
            self.runningPasses -= 1
            if self.engine === engine { self.status = box.value }
        }
        previewTask = task
        isPreviewing = true
        await task.value
        if previewTask == task {
            previewTask = nil
            isPreviewing = false
        }
    }

    /// Stops a running `preview` and waits until it has ended.
    public func cancelPreview() async {
        guard let task = previewTask else { return }
        await engine?.cancel()
        await task.value
        previewTask = nil
        isPreviewing = false
    }

    /// The services of the backup account, for reads beside the engine (the server check before photos are removed
    /// from the device).
    func backupServices() -> AccountServices? {
        account.flatMap { services(for: $0) }
    }

    public func disable() {
        update { $0.isEnabled = false }
    }

    /// Runs a backup pass now (or a dry run when Files keeps doing the backup) and reports how it ended.
    ///
    /// - Parameter retryFailed: also retry items that failed and would still wait for their next attempt (the user asked).
    @discardableResult
    public func runNow(retryFailed: Bool = false) async -> BackupOutcome {
        guard settings.isEnabled || settings.filesAppMode == .keepFiles else {
            return .unavailable(String(localized: "Backup is not turned on in Nextcloud Photos.", bundle: .module))
        }
        guard let engine = await configuredEngine() else {
            let reason = unavailableReason
            logger.notice("backup: paused, the backup account is signed out or cannot be opened")
            status.phase = .paused(reason)
            return .unavailable(reason)
        }
        let box = statusBox
        // The user may have changed the access in Settings since the app asked.
        authorization = PhotoLibrarySource.authorization
        runningPasses += 1
        await engine.run(settings, dryRun: !settings.isEnabled, retryFailed: retryFailed)
        runningPasses -= 1
        let final = box.value
        if self.engine === engine { status = final }
        let outcome = BackupOutcome(status: final)
        logger.info("backup: pass returned \(outcome.logName, privacy: .public)")
        return outcome
    }

    /// Why no engine is available: the backup account is signed out or cannot be opened.
    var unavailableReason: String {
        guard let account else { return String(localized: "Log in to back up your photos.", bundle: .module) }
        return String(localized: "Backup is paused: log in to \(account.displayName) on \(account.hostDisplayName) again.", bundle: .module)
    }

    /// The user's pause.
    public func cancel() {
        Task { await engine?.cancel() }
    }

    /// The system takes the time away (a background task expires). Unlike `cancel()` this is not shown as "Paused", and
    /// the pass is taken up again by the next background task or when the app comes to the foreground.
    public func interrupt() async {
        await engine?.interrupt()
    }

    /// Continues a pass the system interrupted. Called when the app becomes active.
    public func resumeIfInterrupted() async {
        guard settings.isEnabled, status.isInterrupted, !isPassRunning else { return }
        logger.notice("backup: the interrupted pass resumes")
        await runNow()
    }

    /// A pass is running: one started here, or one the engine started by itself after waiting (for Wi-Fi, for the
    /// connection to come back), which only shows in the status it publishes.
    var isPassRunning: Bool { runningPasses > 0 || statusBox.value.isRunning }

    public func entries() async -> [BackupLedgerEntry] {
        (try? await prepareEngine()?.entries()) ?? []
    }

    public func forceUpload(_ entry: BackupLedgerEntry) async {
        try? await prepareEngine()?.forgetMatch(localIdentifier: entry.localIdentifier, kind: entry.resourceKind)
        await runNow()
    }

    /// Services of the backup account: those of the active session when it is the same account (one database connection
    /// pool per account), otherwise services of its own.
    private func services(for account: Account) -> AccountServices? {
        guard let app, !account.isSignedOut else { return nil }
        if let session = app.session, session.account.id == account.id {
            guard !session.account.isSignedOut else { return nil }
            return session.services
        }
        if let ownServices, ownServices.account.id == account.id { return ownServices }
        ownServices = app.makeServices(for: account)
        return ownServices
    }

    /// Engine bound to the backup account, whichever account is active.
    func prepareEngine() -> BackupEngine? {
        guard let account, let services = services(for: account) else {
            if !isPassRunning { dropEngine() }
            return nil
        }
        if let engine, let engineServices {
            // Same services, or a pass is running on the previous ones for the same account: keep it.
            if engineServices === services { return engine }
            if engineServices.account.id == account.id, isPassRunning { return engine }
        }
        dropEngine()
        // Files that wait for their upload live with the account's data and go with it.
        let background = backgroundUploads.map {
            BackgroundUploads(transport: $0, directory: services.layout.accountDirectory(account.id).appending(path: "BackgroundUploads"))
        }
        let engine = BackupEngine(api: services.api, database: services.database, accountId: account.id, background: background)
        self.engine = engine
        engineServices = services
        engineConfigured = false
        statusBox = BackupStatusBox()
        if ownServices !== services { ownServices = nil }
        startObserving()
        return engine
    }

    /// The engine with its status handler in place (set before a pass starts, so the final status is never missed).
    private func configuredEngine() async -> BackupEngine? {
        guard let engine = prepareEngine() else { return nil }
        guard !engineConfigured, let account = engineServices?.account else { return engine }
        engineConfigured = true
        var features: ServerFeatures?
        if let session = app?.session, session.account.id == account.id {
            features = session.features
        } else if let app {
            features = AccountServices.loadFeatures(account.id, layout: app.layout)
        }
        await engine.setMetadataEditing(features?.has(.metadataEdit) ?? false)
        let box = statusBox
        // Weak: the engine keeps the handler, and this model keeps the engine.
        await engine.setStatusHandler { [weak self, weak engine] status in
            box.set(status)
            Task { @MainActor in
                guard let self, self.engine === engine else { return }
                self.status = box.value
            }
        }
        return engine
    }

    private func dropEngine() {
        engine?.cancelDetached()
        engine = nil
        engineServices = nil
        engineConfigured = false
    }

    private func forgetSettings() {
        settings = BackupSettings()
        status = BackupStatus()
        try? FileManager.default.removeItem(at: settingsFile)
    }

    /// The account is about to be removed from this device: stops its backup and waits until nothing uses its database any
    /// more. Backup options that belong to it are forgotten (`AccountPurge` deletes the file).
    func accountWillBeRemoved(_ id: AccountID) async {
        if settings.accountId == id {
            logger.notice("backup: the backup account is removed, its backup options are forgotten")
            debounce?.cancel()
            forgetSettings()
        }
        if let engine, engineServices?.account.id == id {
            self.engine = nil
            engineServices = nil
            engineConfigured = false
            await engine.shutdown()
        }
        if let own = ownServices, own.account.id == id {
            ownServices = nil
            await own.shutdown(closeDatabase: true)
        }
    }

    /// The account's app password stopped working: its backup cannot continue until the user logs in again.
    func accountSignedOut(_ id: AccountID) {
        guard engineServices?.account.id == id || ownServices?.account.id == id else { return }
        logger.notice("backup: stopped, the backup account was signed out")
        dropEngine()
        ownServices = nil
        if settings.isEnabled { status.phase = .paused(unavailableReason) }
    }

    /// New photos trigger a backup (debounced).
    func startObserving() {
        guard observer == nil, authorization == .authorized || authorization == .limited else { return }
        let observer = LibraryObserver { [weak self] in
            Task { @MainActor in self?.libraryChanged() }
        }
        PHPhotoLibrary.shared().register(observer)
        self.observer = observer
    }

    func libraryChanged() {
        guard settings.isEnabled else { return }
        logger.debug("backup: the photo library changed, a pass follows")
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            await self?.runNow()
        }
    }

    /// Called from background tasks; returns when done or cancelled.
    @discardableResult
    public func runInBackground() async -> BackupOutcome {
        guard settings.isEnabled else {
            return .unavailable(String(localized: "Backup is not turned on in Nextcloud Photos.", bundle: .module))
        }
        return await runNow()
    }
}

final class LibraryObserver: NSObject, PHPhotoLibraryChangeObserver, Sendable {
    let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) { onChange() }
}

extension BackupEngine {
    nonisolated func cancelDetached() {
        Task { await cancel() }
    }
}
