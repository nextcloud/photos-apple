// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import OSLog
import Observation
import PhotosDomain
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
    /// How many items the first sync will find, when the server can tell (`loadInitialSyncTotal()`).
    public internal(set) var initialSyncTotal: Int?
    /// The month counts behind `initialSyncTotal`: the timeline's shape while the first sync loads it (`TimelineSkeleton`).
    public internal(set) var initialSyncSkeleton: TimelineSkeleton?
    /// The server presents a certificate the app does not trust (`SessionModel+State.swift`).
    public internal(set) var certificateProblem: CertificateProblem?
    /// The last undoable change, for the confirmation banner (`SessionModel+Undo.swift`).
    public internal(set) var lastChange: ChangeNotice?
    /// Undo bookkeeping (`SessionModel+Undo.swift`): where the last change can be undone, and the undo managers this
    /// session registered with.
    @ObservationIgnored var undoState = UndoState()
    /// Recent changes, newest first, for the undo history (SPEC §16.3.4; `SessionModel+Undo.swift`).
    public internal(set) var history: [ChangeHistoryEntry] = []
    /// Counted up whenever edits of photos change (`SessionModel+Edits.swift`): views showing edits read it.
    public internal(set) var editRevision = 0
    public let transfers = TransferQueue()
    /// The app's backup. It belongs to one account, which is not necessarily this one, and keeps running across account switches.
    public let backup: BackupModel
    public private(set) var offline: OfflineManager?
    /// Smart offline: the photos most likely wanted without network, within a budget (SPEC §15.8.1).
    public private(set) var smartOffline: SmartOfflineManager?
    /// Stickers made in the app (SPEC §15.8.2).
    public private(set) var stickerBook: StickerBook?
    /// A partner's shared photos in this account's timeline (SPEC SH-8).
    public private(set) var partners: PartnerTimelineModel?
    /// Smart albums from the rule builder, folder rules, camera details (SPEC §16.4).
    public private(set) var organize: OrganizeModel?
    /// The family library's suggestions (SPEC §16.7.2).
    public internal(set) var family: FamilyLibraryModel?
    /// The Nextcloud album mirrored into the device's library for the Lock Screen (SPEC §16.7.4).
    public internal(set) var lockScreenAlbum: LockScreenAlbumModel?
    /// When the family features last ran after a sync (`SessionModel+Family.swift`).
    @ObservationIgnored var familyState = FamilyState()
    @ObservationIgnored var albumsRefreshedAt: Date?
    /// What was last written to Spotlight for this account (`SessionModel+Spotlight.swift`); nil before the first pass.
    @ObservationIgnored var spotlightEntries: [SpotlightEntry]?
    /// `afterSync()` runs (`SessionModel+Labels.swift`).
    @ObservationIgnored var afterSyncRunning = false
    /// When smart offline and the photo of the day last ran (`SessionModel+Extras.swift`).
    @ObservationIgnored var extrasState = ExtrasState()
    @ObservationIgnored weak var app: AppModel?
    /// Running work of this session; a task removes itself when it ends, so the collection does not grow.
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var foregroundRefresh: UUID?
    /// Syncs every few minutes while a window can be seen (SPEC §5.4.4); not one of `tasks`, which end by themselves.
    @ObservationIgnored private var periodicSync: Task<Void, Never>?
    /// The server's `notify_push` connection, when it has one (`SessionModel+NotifyPush.swift`).
    @ObservationIgnored var notifyPush = NotifyPushState()
    /// When a sync last asked for the walk an opened app makes (`ReconcileRequest.opened`).
    @ObservationIgnored private var openedSyncAt: Date?
    /// When the capabilities were last compared with `features.fingerprint` (foreground check, at most every 5 minutes).
    @ObservationIgnored private var fingerprintCheckedAt: Date?
    /// A detection asked for by `featureUnavailable(_:)` is running or ran recently.
    @ObservationIgnored private var redetectRequestedAt: Date?
    @ObservationIgnored private var detection: Task<Void, Never>?
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
            partners = PartnerTimelineModel(services: services)
            organize = OrganizeModel(services: services, session: self)
            let offline = OfflineManager(services: services)
            self.offline = offline
            let smart = SmartOfflineManager(
                services: services, excludedFolders: { [weak self] in await MainActor.run { self?.excludedFolders ?? [] } })
            smartOffline = smart
            stickerBook = StickerBook(directory: services.layout.accountDirectory(account.id).appending(path: "Stickers"))
            setUpFamily(services)
            // Weak: the offline managers own the services, whose image pipeline would otherwise own the managers.
            Task { [weak offline, weak smart] in
                await services.images.setLocalOriginalProvider { [weak offline, weak smart] fileId, etag in
                    offline?.localFile(fileId: fileId, etag: etag) ?? smart?.localOriginal(fileId: fileId, etag: etag)
                }
                await services.images.setLocalPreviewProvider { [weak smart] fileId, etag, bucket in
                    smart?.localPreview(fileId: fileId, etag: etag, bucket: bucket)
                }
            }
            observeEdits()
        }
    }

    public var isSignedOut: Bool { account.isSignedOut || services == nil }
    /// Signed out because the app password is not in the keychain (it could not be stored or read), not because the
    /// server stopped accepting it: the UI says so instead of "no longer valid".
    public internal(set) var isLoginMissing = false

    /// Directories excluded from all views (`.nomedia`).
    public var excludedFolders: [String] { features.nomediaPaths }

    func start() {
        guard let services, !isStopped else { return }
        _ = ForegroundState.shared  // follows the app's activation from now on (shared-album notifications)
        track { [weak self] in
            await services.sync.setStatusHandler { status in
                Task { @MainActor in
                    let previous = self?.syncStatus
                    self?.syncStatus = status
                    self?.syncStatusChanged(from: previous, to: status)
                }
            }
            // Walks through the whole library wait while a backup pass uploads (it changes the root ETag all the time).
            await services.sync.setReconcileDeferral { [weak self] in
                await MainActor.run { self?.backup.isPassRunning ?? false }
            }
            await self?.refreshFeatures()
            // The launch: what was deleted or moved elsewhere since the last walk goes now, not after the interval.
            await self?.syncNow(reconcile: .opened)
            await services.outbox.kick()
            // Stopped again by `Outbox.shutdown()`, which `shutdown()` reaches through the services.
            await services.outbox.startNetworkMonitoring()
            await self?.offline?.syncPins()
            if self?.backup.settings.isEnabled == true { await self?.backup.runNow() }
        }
        startPeriodicSync()
        startNotifyPush()
    }

    /// How often the library syncs while a window can be seen (SPEC §5.4.4).
    static let periodicSyncInterval: Duration = .seconds(300)

    /// Syncs every `periodicSyncInterval` while a window can be seen. A sync that finds nothing changed is a PROPFIND of
    /// the root folders and the favourites SEARCH; deletes and moves made elsewhere arrive with the reconciliation that a
    /// changed root owes (at most every `SyncEngine.reconcileInterval`).
    private func startPeriodicSync() {
        periodicSync?.cancel()
        periodicSync = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.periodicSyncInterval)
                guard let self, !Task.isCancelled, !self.isStopped else { return }
                if ForegroundState.shared.isVisible { await self.syncNow() }
            }
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
        periodicSync?.cancel()
        stopNotifyPush()
        organize?.stop()
        // Nothing of this account can be undone any more (account switch, removal).
        clearUndo()
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
        await periodicSync?.value
        periodicSync = nil
        await transfers.shutdown()
        await offline?.shutdown()
        await smartOffline?.shutdown()
        if let services {
            await services.sync.setStatusHandler { _ in }
            await services.shutdown(closeDatabase: closeDatabase)
        }
    }

    // MARK: Sync

    /// Detects the server's features. Calls made while a detection runs wait for it instead of starting another one
    /// (launch and the first foreground notification both ask for one).
    public func refreshFeatures() async {
        if let running = detection {
            await running.value
            return
        }
        let task = Task { await self.detectFeatures() }
        detection = task
        await task.value
        detection = nil
    }

    private func detectFeatures() async {
        guard let services else { return }
        do {
            // The cached features go along: a detection that cannot read the Photos settings this time keeps them.
            let detected = try await FeatureDetector(dav: services.dav, ocs: services.ocs).detect(cached: features)
            guard !isStopped else { return }  // nothing is written for a session that was switched away from or removed
            featureDetectionError = nil
            fingerprintCheckedAt = Date()
            if detected.enabled != features.enabled || detected.fingerprint != features.fingerprint {
                let added = detected.enabled.subtracting(features.enabled).map(\.rawValue).sorted().joined(separator: ",")
                let removed = features.enabled.subtracting(detected.enabled).map(\.rawValue).sorted().joined(separator: ",")
                logger.info(
                    "server features changed (\(detected.fingerprint ?? "-", privacy: .public)): +\(added, privacy: .public) -\(removed, privacy: .public)"
                )
            }
            await apply(detected)
        } catch {
            guard !isStopped else { return }
            featureDetectionError = error.localizedDescription
            logger.error("feature detection failed: \(error.localizedDescription, privacy: .public)")
            // Unreachable server: keep what we know. A server that answered with an error: only core features until the
            // next detection succeeds, never APIs of a newer Photos version that may be gone.
            if let fallback = FeatureDetector.fallback(after: error, cached: features), fallback != features {
                await apply(fallback)
            }
        }
    }

    private func apply(_ updated: ServerFeatures) async {
        features = updated
        guard let services else { return }
        AccountServices.saveFeatures(updated, for: account.id, layout: services.layout)
        await services.sync.updateFeatures(updated)
    }

    /// Called when an optional API turned out to be missing although detection had found it (the server's Photos app was
    /// downgraded or disabled since): stops using it at once and detects the features again (at most every 5 minutes).
    public func featureUnavailable(_ feature: ServerFeature) {
        guard features.has(feature), !isStopped else { return }
        logger.notice("server no longer offers \(feature.rawValue, privacy: .public); detecting features again")
        let updated = features.removing([feature])
        track { [weak self] in
            await self?.apply(updated)
            guard let self else { return }
            if let last = self.redetectRequestedAt, Date().timeIntervalSince(last) < 300 { return }
            self.redetectRequestedAt = Date()
            await self.refreshFeatures()
        }
    }

    /// Detects the features again when they are old (1 h) or when the capabilities show that the server changed since
    /// (Nextcloud or Photos upgraded or downgraded; checked at most every 5 minutes).
    func refreshFeaturesIfNeeded() async {
        guard let services else { return }
        if Date().timeIntervalSince(features.detectedAt) > 3600 {
            await refreshFeatures()
            return
        }
        if let checked = fingerprintCheckedAt, Date().timeIntervalSince(checked) < 300 { return }
        fingerprintCheckedAt = Date()
        guard let current = try? await FeatureDetector(dav: services.dav, ocs: services.ocs).currentFingerprint() else { return }
        if current != features.fingerprint { await refreshFeatures() }
    }

    public func syncNow(forceReconcile: Bool = false) async {
        await syncNow(reconcile: forceReconcile ? .now : .ifDue)
    }

    /// Syncs; `.opened` is the launch and a return to the app, `.refresh` is pull-to-refresh (reconciles only if the last
    /// reconciliation is a while ago or something changed), `.now` is "Sync now".
    public func syncNow(reconcile: ReconcileRequest) async {
        guard let services, !isStopped else { return }
        if reconcile >= .opened { openedSyncAt = Date() }
        await services.sync.sync(reconcile: reconcile)
        // Photos without a server preview are asked for again after a sync, with a backoff (SPEC §20.1).
        services.images.librarySynced()
        await services.outbox.kick()
        // Edits saved on other devices, and edits made here while offline (SPEC §16.3.1).
        await services.edits.sync()
        await refreshFailedOperations()
        // Beside, not before, what the caller does next (a background task's backup pass): labels for search and
        // shared-album activity are throttled extras.
        if !afterSyncRunning { track { [weak self] in await self?.afterSync() } }
    }

    /// Called when the app comes to the foreground.
    public func didBecomeActive() {
        guard services != nil, !isStopped else { return }
        // One foreground refresh at a time: coming to the foreground again while it runs adds nothing.
        resumeNotifyPushIfDropped()
        if let foregroundRefresh, tasks[foregroundRefresh] != nil { return }
        foregroundRefresh = track { [weak self] in
            guard let self else { return }
            await self.refreshFeaturesIfNeeded()
            await self.syncNow(reconcile: self.foregroundReconcile())
        }
    }

    /// Coming back to the app is opening it, as the launch is (`ReconcileRequest.opened`), unless that was asked for a
    /// moment ago: on the Mac the app comes to the front whenever one of its windows is clicked.
    func foregroundReconcile(now: Date = Date()) -> ReconcileRequest {
        guard let openedSyncAt else { return .opened }
        return now.timeIntervalSince(openedSyncAt) >= Self.periodicSyncInterval / .seconds(1) ? .opened : .ifDue
    }

    public func refreshFailedOperations() async {
        guard let services else { return }
        let failed = (try? await services.outbox.failedOperations()) ?? []
        if failed.count != failedOperations.count { logger.notice("outbox: \(failed.count) failed operations") }
        failedOperations = failed
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
    // Favourite and archive go through `perform(_:)` (SessionModel+Undo), so that they can be undone.

    /// A delete that is not offered for undo (duplicates, free up space: the user confirmed a list of files).
    public func delete(_ items: [MediaItem]) async {
        await enqueue(items.filter(\.permissions.canDelete).map { .delete(fileId: $0.fileId, path: $0.path) })
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
        guard let services, !operations.isEmpty, !isStopped else { return }
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
        do {
            try await services.api.setUserConfig(key, value: value)
        } catch {
            // An extended key the server does not accept (any more): stop offering it.
            if let feature = FeatureDetector.feature(for: key), FeatureDetector.isMissingAPI(error) { featureUnavailable(feature) }
            throw error
        }
        guard !isStopped else { return }
        features.userConfig = config
        AccountServices.saveFeatures(features, for: account.id, layout: services.layout)
        await services.sync.updateFeatures(features)
        if key == .photosSourceFolders { await syncNow() }
    }
}
