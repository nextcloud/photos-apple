// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import OSLog
import Observation
import PhotosModel
import PhotosNetworking
import PhotosStore

/// State and actions of the active account, observed by the UI.
@MainActor
@Observable
public final class SessionModel {
    public internal(set) var account: Account
    public private(set) var services: AccountServices?
    public internal(set) var features: ServerFeatures
    public private(set) var syncStatus: SyncStatus = .idle(lastSync: nil)
    public private(set) var failedOperations: [FailedOperation] = []
    public private(set) var featureDetectionError: String?
    public let transfers = TransferQueue()
    /// The app's backup. It belongs to one account, which is not necessarily this one, and keeps running across account switches.
    public let backup: BackupModel
    public private(set) var offline: OfflineManager?
    @ObservationIgnored var albumsRefreshedAt: Date?
    @ObservationIgnored weak var app: AppModel?
    /// Running work of this session; a task removes itself when it ends, so the collection does not grow.
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var foregroundRefresh: UUID?
    @ObservationIgnored private(set) var isStopped = false
    @ObservationIgnored private let logger = Logger(subsystem: "com.nextcloud.photos", category: "session")

    init(app: AppModel, account: Account, password: String?) {
        self.app = app
        self.account = account
        self.backup = app.backup
        let cached = AccountServices.loadFeatures(account.id, layout: app.layout)
        self.features = cached ?? ServerFeatures(serverVersion: account.serverVersion ?? ServerVersion(major: 0))
        guard let password else { return }
        do {
            let id = account.id
            services = try AccountServices(
                account: account, appPassword: password, http: app.http, features: features, userAgent: app.userAgent,
                layout: app.layout, onUnauthorized: { [weak app] in Task { @MainActor in await app?.handleUnauthorized(id) } })
        } catch {
            logger.error("could not open account database: \(error.localizedDescription, privacy: .public)")
        }
        transfers.session = self
        if let services {
            let offline = OfflineManager(services: services)
            self.offline = offline
            // Weak: the offline manager owns the services, whose image pipeline would otherwise own the manager.
            Task { [weak offline] in
                await services.images.setLocalOriginalProvider { [weak offline] fileId, etag in
                    offline?.localFile(fileId: fileId, etag: etag)
                }
            }
        }
    }

    public var isSignedOut: Bool { account.isSignedOut || services == nil }

    /// Directories excluded from all views (`.nomedia`).
    public var excludedFolders: [String] { features.nomediaPaths }

    func start() {
        guard let services, !isStopped else { return }
        track { [weak self] in
            await services.sync.setStatusHandler { status in
                Task { @MainActor in self?.syncStatus = status }
            }
            await self?.refreshFeatures()
            await self?.syncNow()
            await services.outbox.kick()
            await self?.offline?.syncPins()
            if self?.backup.settings.isEnabled == true { await self?.backup.runNow() }
        }
    }

    /// Runs work that belongs to this session; it is cancelled by `stop()` and awaited by `shutdown()`.
    @discardableResult
    private func track(_ operation: @escaping @MainActor @Sendable () async -> Void) -> UUID {
        let id = UUID()
        tasks[id] = Task { [weak self] in
            await operation()
            self?.tasks[id] = nil
        }
        return id
    }

    /// Number of tracked tasks still running (tests).
    var runningTaskCount: Int { tasks.count }

    /// Cancels the session's own tasks. Does not wait; `shutdown()` does.
    func stop() {
        isStopped = true
        tasks.values.forEach { $0.cancel() }
    }

    /// Stops everything this session runs for its account and waits until it has stopped: its own tasks, manual uploads,
    /// offline downloads, sync and the outbox worker. With `closeDatabase` (account removal) image loads are stopped too and
    /// the database is closed, so that nothing writes into files that are about to be deleted.
    ///
    /// The backup is not touched: it is app-wide and keeps running for its own account.
    func shutdown(closeDatabase: Bool = false) async {
        stop()
        for task in Array(tasks.values) { await task.value }
        tasks = [:]
        await transfers.shutdown()
        await offline?.shutdown()
        if let services {
            await services.sync.setStatusHandler { _ in }
            await services.shutdown(closeDatabase: closeDatabase)
        }
    }

    // MARK: Sync

    public func refreshFeatures() async {
        guard let services else { return }
        do {
            let detected = try await FeatureDetector(dav: services.dav, ocs: services.ocs).detect()
            guard !isStopped else { return }  // nothing is written for a session that was switched away from or removed
            features = detected
            featureDetectionError = nil
            AccountServices.saveFeatures(detected, for: account.id, layout: services.layout)
            await services.sync.updateFeatures(detected)
        } catch {
            featureDetectionError = error.localizedDescription
            logger.error("feature detection failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func syncNow(forceReconcile: Bool = false) async {
        guard let services, !isStopped else { return }
        await services.sync.sync(forceReconcile: forceReconcile)
        await services.outbox.kick()
        await refreshFailedOperations()
    }

    /// Called when the app comes to the foreground.
    public func didBecomeActive() {
        guard services != nil, !isStopped else { return }
        // One foreground refresh at a time: coming to the foreground again while it runs adds nothing.
        if let foregroundRefresh, tasks[foregroundRefresh] != nil { return }
        foregroundRefresh = track { [weak self] in
            guard let self else { return }
            if Date().timeIntervalSince(self.features.detectedAt) > 3600 { await self.refreshFeatures() }
            await self.syncNow()
        }
    }

    public func refreshFailedOperations() async {
        guard let services else { return }
        failedOperations = (try? await services.outbox.failedOperations()) ?? []
    }

    public func retryFailedOperations() async {
        try? await services?.outbox.retryFailed()
        await refreshFailedOperations()
    }

    public func discardFailedOperations() async {
        try? await services?.outbox.discardFailed()
        await refreshFailedOperations()
    }

    // MARK: Actions (optimistic, via outbox)

    public func setFavorite(_ items: [MediaItem], _ value: Bool) async {
        await enqueue(items.map { .favorite(fileId: $0.fileId, path: $0.path, value: value) })
    }

    public func delete(_ items: [MediaItem]) async {
        await enqueue(items.filter(\.permissions.canDelete).map { .delete(fileId: $0.fileId, path: $0.path) })
    }

    public func archive(_ items: [MediaItem]) async {
        await enqueue(
            items.filter { $0.isOwnStorage && $0.permissions.canDelete && !$0.isArchived }.map {
                .archive(fileId: $0.fileId, path: $0.path)
            })
    }

    public func unarchive(_ items: [MediaItem]) async {
        await enqueue(items.filter(\.isArchived).map { .unarchive(fileId: $0.fileId, path: $0.path) })
    }

    public func add(_ items: [MediaItem], to album: Album) async {
        await enqueue(
            items.filter(\.isOwnStorage).map {
                .addToAlbum(albumId: album.id, albumName: album.name, albumKind: album.kind, fileId: $0.fileId, path: $0.path)
            })
    }

    public func setMetadata(
        _ items: [MediaItem], capturedAt: (MediaItem) -> Date?, latitude: Double?, longitude: Double?, removeLocation: Bool
    ) async {
        await enqueue(
            items.map {
                .setMetadata(
                    fileId: $0.fileId, path: $0.path, capturedAt: capturedAt($0), latitude: latitude, longitude: longitude,
                    removeLocation: removeLocation)
            })
    }

    func enqueue(_ operations: [PendingOperation]) async {
        guard let services, !operations.isEmpty else { return }
        do {
            try await services.outbox.enqueue(operations)
        } catch {
            logger.error("enqueue failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Server user config

    public func setUserConfig(_ key: PhotosUserConfig.Key, _ change: (inout PhotosUserConfig) -> Void) async throws {
        guard let services else { return }
        var config = features.userConfig
        change(&config)
        guard let value = config.rawValue(for: key) else { return }
        try await services.api.setUserConfig(key, value: value)
        guard !isStopped else { return }
        features.userConfig = config
        AccountServices.saveFeatures(features, for: account.id, layout: services.layout)
        await services.sync.updateFeatures(features)
        if key == .photosSourceFolders { await syncNow() }
    }
}
