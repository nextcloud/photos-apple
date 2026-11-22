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
    public private(set) var features: ServerFeatures
    public private(set) var syncStatus: SyncStatus = .idle(lastSync: nil)
    public private(set) var failedOperations: [FailedOperation] = []
    public private(set) var featureDetectionError: String?
    public let transfers = TransferQueue()
    public private(set) var offline: OfflineManager?
    @ObservationIgnored var albumsRefreshedAt: Date?
    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var unauthorizedCheckRunning = false
    @ObservationIgnored private let logger = Logger(subsystem: "com.nextcloud.photos", category: "session")

    init(app: AppModel, account: Account, password: String?) {
        self.app = app
        self.account = account
        let cached = AccountServices.loadFeatures(account.id)
        self.features = cached ?? ServerFeatures(serverVersion: account.serverVersion ?? ServerVersion(major: 0))
        guard let password else { return }
        do {
            let id = account.id
            services = try AccountServices(
                account: account, appPassword: password, http: app.http, features: features, userAgent: app.userAgent,
                onUnauthorized: { [weak self] in Task { @MainActor in await self?.handleUnauthorized(id) } })
        } catch {
            logger.error("could not open account database: \(error.localizedDescription, privacy: .public)")
        }
        transfers.session = self
        if let services {
            let offline = OfflineManager(services: services)
            self.offline = offline
            Task { await services.images.setLocalOriginalProvider { fileId, etag in offline.localFile(fileId: fileId, etag: etag) } }
        }
    }

    public var isSignedOut: Bool { account.isSignedOut || services == nil }

    /// Directories excluded from all views (`.nomedia`).
    public var excludedFolders: [String] { features.nomediaPaths }

    func start() {
        guard let services else { return }
        tasks.append(
            Task { [weak self] in
                await services.sync.setStatusHandler { status in
                    Task { @MainActor in self?.syncStatus = status }
                }
                await self?.refreshFeatures()
                await self?.syncNow()
                await services.outbox.kick()
                await self?.offline?.syncPins()
            })
    }

    func stop() {
        tasks.forEach { $0.cancel() }
        tasks = []
    }

    // MARK: Sync

    public func refreshFeatures() async {
        guard let services else { return }
        do {
            let detected = try await FeatureDetector(dav: services.dav, ocs: services.ocs).detect()
            features = detected
            featureDetectionError = nil
            AccountServices.saveFeatures(detected, for: account.id)
            await services.sync.updateFeatures(detected)
        } catch {
            featureDetectionError = error.localizedDescription
            logger.error("feature detection failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func syncNow(forceReconcile: Bool = false) async {
        guard let services else { return }
        await services.sync.sync(forceReconcile: forceReconcile)
        await services.outbox.kick()
        await refreshFailedOperations()
    }

    /// Called when the app comes to the foreground.
    public func didBecomeActive() {
        guard services != nil else { return }
        tasks.append(
            Task { [weak self] in
                guard let self else { return }
                if Date().timeIntervalSince(self.features.detectedAt) > 3600 { await self.refreshFeatures() }
                await self.syncNow()
            })
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
        features.userConfig = config
        AccountServices.saveFeatures(features, for: account.id)
        await services.sync.updateFeatures(features)
        if key == .photosSourceFolders { await syncNow() }
    }

    // MARK: Unauthorized (SPEC §5.1.6)

    func handleUnauthorized(_ id: AccountID) async {
        guard id == account.id, !unauthorizedCheckRunning, let services, let app else { return }
        unauthorizedCheckRunning = true
        defer { unauthorizedCheckRunning = false }
        let accountAPI = AccountAPI(ocs: services.ocs)
        do {
            _ = try await accountAPI.profile()
            return  // credentials still valid
        } catch NetworkError.unauthorized {
            if (try? await accountAPI.remoteWipeRequested()) == true {
                await app.wipe(id, api: accountAPI)
            } else {
                app.markSignedOut(id)
            }
        } catch {
            return
        }
    }
}
