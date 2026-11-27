// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import OSLog
import Observation
import Photos
import PhotosBackup
import PhotosModel

/// The Library's device layer (SPEC §21.1): which photos of this device are not on the server yet, kept current as the
/// photo library, the backup's ledger and its uploads change. Read off the main actor; the main actor only receives the
/// finished snapshot.
@MainActor
@Observable
public final class DeviceLayerModel {
    /// The latest snapshot; empty while backup is off or the photos cannot be read.
    public private(set) var snapshot = DeviceLayerSnapshot.empty
    /// A snapshot was built for the current options (the summary says nothing before that).
    public private(set) var isLoaded = false

    @ObservationIgnored weak var backup: BackupModel?
    /// PhotoKit's list from the last read, and the options it was read with: the ledger changes far more often than the
    /// photo library, and only the ledger is read again for it.
    @ObservationIgnored private var library: (items: [DeviceLibraryItem], key: LibraryKey)?
    @ObservationIgnored private var libraryDirty = true
    @ObservationIgnored private var building: Task<Void, Never>?
    @ObservationIgnored private var buildAgain = false
    @ObservationIgnored private var observer: LibraryObserver?
    @ObservationIgnored private var continuations: [UUID: AsyncStream<DeviceLayerSnapshot>.Continuation] = [:]
    @ObservationIgnored private let logger = Logger(subsystem: "com.nextcloud.photos", category: "backup")

    /// What PhotoKit is asked for: the options that select assets.
    struct LibraryKey: Equatable {
        var account: AccountID?
        var scope: String
    }

    /// Changes of the photo library and the ledger come in bursts (a pass records file after file); one build per this
    /// interval at most.
    static let interval = Duration.milliseconds(800)

    nonisolated init() {}

    func attach(_ backup: BackupModel) {
        self.backup = backup
        scheduleBuild()
    }

    /// The layer is built: backup is on (or Files keeps doing it and the app only checks), with access to the photos.
    var isActive: Bool {
        guard let backup else { return false }
        let access = backup.authorization == .authorized || backup.authorization == .limited
        return access && backup.isAvailable && backup.account != nil && backup.settings.isEnabled
    }

    /// The device's photos stand in the Library of this account: the layer is active for it and the option is on.
    public func showsInLibrary(of account: AccountID) -> Bool {
        guard let backup, isActive, backup.settings.showsDeviceInLibrary else { return false }
        return backup.account?.id == account
    }

    /// The snapshot now and every new one after it, for the Library's timeline (newest only: a slow reader skips some).
    public func snapshots() -> AsyncStream<DeviceLayerSnapshot> {
        let (stream, continuation) = AsyncStream<DeviceLayerSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        continuations[id] = continuation
        if isLoaded { continuation.yield(snapshot) }
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.continuations[id] = nil }
        }
        return stream
    }

    // MARK: Triggers

    /// Builds the layer again (the Library appeared, the account came back).
    public func refresh() {
        scheduleBuild()
    }

    /// Backup options or the access to the photos changed.
    func settingsChanged() {
        libraryDirty = true
        scheduleBuild()
    }

    /// The backup published a new status: uploads finished, failed or started.
    func statusChanged(from old: BackupStatus, to new: BackupStatus) {
        let changed: Bool =
            old.uploadingIdentifiers != new.uploadingIdentifiers || old.uploaded != new.uploaded || old.matched != new.matched
            || old.pending != new.pending || old.failed != new.failed || old.skipped != new.skipped || old.lastRun != new.lastRun
        if changed { scheduleBuild() }
    }

    /// The device's photo library changed (a new photo, a deleted one, a favourite).
    func libraryChanged() {
        libraryDirty = true
        scheduleBuild()
    }

    // MARK: Building

    private func scheduleBuild() {
        guard building == nil else {
            buildAgain = true
            return
        }
        building = Task { [weak self] in
            await self?.build()
            guard let self else { return }
            try? await Task.sleep(for: Self.interval)
            self.building = nil
            if self.buildAgain {
                self.buildAgain = false
                self.scheduleBuild()
            }
        }
    }

    private func build() async {
        guard let backup, isActive, let database = backup.backupServices()?.database else {
            stopObserving()
            library = nil
            publish(.empty, loaded: backup != nil && !(backup?.settings.isEnabled ?? false))
            return
        }
        startObserving()
        let settings = backup.settings
        let key = LibraryKey(
            account: backup.account?.id,
            scope: "\(settings.photos)|\(settings.videos)|\(settings.since?.timeIntervalSince1970 ?? 0)|\(settings.includeHidden)|"
                + settings.albumIdentifiers.joined(separator: ",") + "|\(backup.authorization.rawValue)")
        let cached: [DeviceLibraryItem]? = !libraryDirty && library?.key == key ? library?.items : nil
        libraryDirty = false
        let inFlight = backup.status.uploadingIdentifiers
        let started = ContinuousClock.now
        let built = await Task.detached(priority: .utility) { () -> ([DeviceLibraryItem], DeviceLayerSnapshot) in
            let items = cached ?? DeviceLibraryReader.read(settings)
            let ledger = (try? DeviceLedger.load(database)) ?? [:]
            return (items, DeviceLayerBuilder.build(library: items, ledger: ledger, inFlight: inFlight))
        }.value
        if cached == nil {
            let elapsed = ContinuousClock.now - started
            logger.info(
                "backup: device layer read \(built.0.count, privacy: .public) assets, \(built.1.notBackedUp, privacy: .public) not backed up, in \(elapsed.formatted(.units(allowed: [.milliseconds])), privacy: .public)"
            )
        }
        library = (built.0, key)
        DeviceAssetDirectory.shared.register(built.1)
        publish(built.1, loaded: true)
    }

    private func publish(_ new: DeviceLayerSnapshot, loaded: Bool) {
        if new != snapshot { snapshot = new }
        if loaded != isLoaded { isLoaded = loaded }
        for continuation in continuations.values { continuation.yield(new) }
    }

    private func startObserving() {
        guard observer == nil else { return }
        let observer = LibraryObserver { [weak self] in
            Task { @MainActor in self?.libraryChanged() }
        }
        PHPhotoLibrary.shared().register(observer)
        self.observer = observer
    }

    private func stopObserving() {
        guard let observer else { return }
        PHPhotoLibrary.shared().unregisterChangeObserver(observer)
        self.observer = nil
    }
}

extension BackupModel {
    /// The backup summary of the Library and the account menu (SPEC §21.1).
    public var summary: BackupSummary {
        BackupSummary(
            isEnabled: settings.isEnabled && isAvailable, isLoaded: deviceLayer.isLoaded, snapshot: deviceLayer.snapshot,
            isRunning: status.isRunning)
    }

    /// "Back up now" for photos of this device (a selection in the Library, SPEC §21.1): they go first, a failed one
    /// at once.
    public func backUpNow(_ localIdentifiers: [String]) async {
        guard settings.isEnabled, !localIdentifiers.isEmpty, let engine = prepareEngine() else { return }
        #if DEBUG
            debugHold = false
        #endif
        await engine.prioritize(Set(localIdentifiers))
        await startBackup()
    }
}
