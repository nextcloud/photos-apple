// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Observation
import Photos
import PhotosBackup
import PhotosModel
import Synchronization

/// How a backup pass ended, for callers that have to tell the user (the "Back up now" App Intent, background tasks).
public enum BackupOutcome: Sendable, Equatable {
    /// Everything on this device is on the server.
    case upToDate
    /// The pass ran to its end. `remaining` items are still waiting (for example videos that wait for Wi-Fi).
    case finished(uploaded: Int, remaining: Int, failed: Int)
    /// Stopped before the end; the reason is ready to show ("Waiting for Wi-Fi").
    case paused(String)
    case failed(String)
    /// No access to the photo library.
    case notAuthorized
    /// Backup could not start at all: it is turned off, or its account is signed out.
    case unavailable(String)

    /// Derives the outcome from the engine's status after a pass.
    public init(status: BackupStatus, uploadedBefore: Int) {
        switch status.phase {
        case .upToDate: self = .upToDate
        case .paused(let reason): self = .paused(reason)
        case .failed(let message): self = .failed(message)
        case .notAuthorized: self = .notAuthorized
        case .idle, .scanning, .reconciling, .uploading:
            self = .finished(uploaded: max(0, status.uploaded - uploadedBefore), remaining: status.pending, failed: status.failed)
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
        case .upToDate: String(localized: "Your photos are backed up.")
        case .finished(let uploaded, let remaining, let failed):
            if failed > 0 { String(localized: "Backup finished, but \(failed) items could not be uploaded.") } else if remaining > 0 {
                String(localized: "\(uploaded) items were backed up, \(remaining) are still waiting.")
            } else {
                String(localized: "Backup finished.")
            }
        case .paused(let reason): String(localized: "Backup is paused: \(reason)")
        case .failed(let message): String(localized: "Backup failed: \(message)")
        case .notAuthorized: String(localized: "Nextcloud Photos has no access to your photos.")
        case .unavailable(let reason): reason
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
    @ObservationIgnored private var observer: LibraryObserver?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored let settingsFile: URL

    init(settingsFile: URL = AppPaths.layout.backupSettingsFile) {
        self.settingsFile = settingsFile
        settings = BackupSettings.load(from: settingsFile)
    }

    /// Connects the model to the app. Options left behind by an account that no longer exists are discarded.
    func attach(_ app: AppModel) {
        self.app = app
        if let id = settings.accountId, !app.accounts.contains(where: { $0.id == id }) { forgetSettings() }
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
        change(&settings)
        try? settings.save(to: settingsFile)
        if !settings.isEnabled { engine?.cancelDetached() }
    }

    public func requestAuthorization() async {
        authorization = await PhotoLibrarySource.requestAuthorization()
    }

    /// Turns backup on for the active account and runs the first pass.
    public func enable(mode: BackupSettings.FilesAppMode) async {
        guard let session = app?.session else { return }
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
        await runNow()
    }

    public func disable() {
        update { $0.isEnabled = false }
    }

    /// Runs a backup pass now (or a dry run when Files keeps doing the backup) and reports how it ended.
    @discardableResult
    public func runNow() async -> BackupOutcome {
        guard settings.isEnabled || settings.filesAppMode == .keepFiles else {
            return .unavailable(String(localized: "Backup is not turned on in Nextcloud Photos."))
        }
        guard let engine = await configuredEngine() else {
            let reason = unavailableReason
            status.phase = .paused(reason)
            return .unavailable(reason)
        }
        let box = statusBox
        let uploadedBefore = box.value.uploaded
        runningPasses += 1
        await engine.run(settings, dryRun: !settings.isEnabled)
        runningPasses -= 1
        let final = box.value
        if self.engine === engine { status = final }
        return BackupOutcome(status: final, uploadedBefore: uploadedBefore)
    }

    /// Why no engine is available: the backup account is signed out or cannot be opened.
    var unavailableReason: String {
        guard let account else { return String(localized: "Log in to back up your photos.") }
        return String(localized: "Backup is paused: log in to \(account.displayName) on \(account.hostDisplayName) again.")
    }

    public func cancel() {
        Task { await engine?.cancel() }
    }

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
            if runningPasses == 0 { dropEngine() }
            return nil
        }
        if let engine, let engineServices {
            // Same services, or a pass is running on the previous ones for the same account: keep it.
            if engineServices === services { return engine }
            if engineServices.account.id == account.id, runningPasses > 0 { return engine }
        }
        dropEngine()
        let engine = BackupEngine(api: services.api, database: services.database, accountId: account.id)
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
        guard settings.isEnabled else { return .unavailable(String(localized: "Backup is not turned on in Nextcloud Photos.")) }
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
