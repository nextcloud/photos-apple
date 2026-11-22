// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Observation
import Photos
import PhotosBackup
import PhotosModel

/// Backup state for the UI and background tasks (SPEC §7.18).
@MainActor
@Observable
public final class BackupModel {
    public private(set) var settings: BackupSettings
    public private(set) var status = BackupStatus()
    public private(set) var authorization: PHAuthorizationStatus = PhotoLibrarySource.authorization
    @ObservationIgnored private var engine: BackupEngine?
    @ObservationIgnored private var engineAccount: AccountID?
    @ObservationIgnored private var observer: LibraryObserver?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored weak var session: SessionModel?

    static var settingsFile: URL { AppPaths.container.appending(path: "Library/Application Support/backup.json") }

    init() {
        settings = BackupSettings.load(from: Self.settingsFile)
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

    public func update(_ change: (inout BackupSettings) -> Void) {
        change(&settings)
        try? settings.save(to: Self.settingsFile)
        if !settings.isEnabled { engine?.cancelDetached() }
    }

    public func requestAuthorization() async {
        authorization = await PhotoLibrarySource.requestAuthorization()
    }

    /// Turns backup on for the active account and runs the first pass.
    public func enable(mode: BackupSettings.FilesAppMode) async {
        guard let session else { return }
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

    /// Runs a backup pass now (or a dry run when Files keeps doing the backup).
    public func runNow() async {
        guard let engine = prepareEngine() else { return }
        await engine.run(settings, dryRun: !settings.isEnabled)
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

    /// Engine bound to the backup account (only when it is the active session's account).
    func prepareEngine() -> BackupEngine? {
        guard let session, let services = session.services else { return nil }
        if let accountId = settings.accountId, accountId != session.account.id { return nil }
        if let engine, engineAccount == session.account.id { return engine }
        let engine = BackupEngine(api: services.api, database: services.database, accountId: session.account.id)
        self.engine = engine
        engineAccount = session.account.id
        let metadataEditing = session.features.has(.metadataEdit)
        Task {
            await engine.setMetadataEditing(metadataEditing)
            await engine.setStatusHandler { status in Task { @MainActor in self.status = status } }
        }
        startObserving()
        return engine
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
        debounce = Task {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            await runNow()
        }
    }

    /// Called from background tasks; returns when done or cancelled.
    public func runInBackground() async {
        guard settings.isEnabled else { return }
        await runNow()
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
