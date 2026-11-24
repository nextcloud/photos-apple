// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import OSLog
import PhotosModel
import PhotosNetworking

/// Progress of the sync engine, published to the UI.
public enum SyncStatus: Sendable, Equatable {
    case idle(lastSync: Date?)
    case initialSync(itemsFetched: Int)
    case syncing
    case reconciling(itemsChecked: Int)
    case offline(lastSync: Date?)
    case failed(message: String, lastSync: Date?)

    public var isWorking: Bool {
        switch self {
        case .initialSync, .syncing, .reconciling: true
        default: false
        }
    }
}

/// Keeps the local index in sync with the server (SPEC §5.4).
public actor SyncEngine {
    public let api: PhotosAPI
    public let library: LibraryStore
    public let collections: CollectionStore
    private var features: ServerFeatures
    private let logger = Logger(subsystem: "com.nextcloud.photos", category: "sync")
    private var running: Task<Void, Never>?
    /// A reconcile was asked for ("Sync now", pull-to-refresh) and has not run to the end yet.
    private var reconcileRequested = false
    private var statusHandler: (@Sendable (SyncStatus) -> Void)?
    private var lastStatus: SyncStatus = .idle(lastSync: nil)

    /// The shortest time between two full reconciliations that nobody asked for (seconds).
    ///
    /// Any change below a source folder changes its ETag, and on a busy account (a phone backing up, a shared folder)
    /// that is nearly every sync. New and changed files arrive through the delta SEARCH at once; only deletes and moves
    /// made elsewhere need the walk through the whole library, and those can wait this long. "Sync now" and
    /// pull-to-refresh are not held back.
    let reconcileInterval: TimeInterval
    public static let defaultReconcileInterval: TimeInterval = 600

    public init(
        api: PhotosAPI, database: AccountDatabase, features: ServerFeatures,
        reconcileInterval: TimeInterval = SyncEngine.defaultReconcileInterval
    ) {
        self.api = api
        self.library = LibraryStore(database: database)
        self.collections = CollectionStore(database: database)
        self.features = features
        self.reconcileInterval = reconcileInterval
    }

    var database: AccountDatabase { library.database }

    public func setStatusHandler(_ handler: @escaping @Sendable (SyncStatus) -> Void) {
        statusHandler = handler
        handler(lastStatus)
    }

    public func updateFeatures(_ features: ServerFeatures) {
        self.features = features
    }

    private func publish(_ status: SyncStatus) {
        lastStatus = status
        statusHandler?(status)
    }

    // MARK: State keys

    enum Key {
        static let initialComplete = "initialComplete"
        static let initialCursor = "initialCursor"
        static let lastDeltaSync = "lastDeltaSync"
        static let lastReconcile = "lastReconcile"
        static let sourceFolders = "sourceFolders"
        /// "1" while a change below a source folder still waits for its (throttled) reconciliation.
        static let reconcileOwed = "reconcileOwed"
        /// Set when a reconciliation would have removed a large part of the index and was not applied; the next one decides.
        static let suspectedMassDelete = "suspectedMassDelete"
        /// Comma-separated file ids whose rows must be read from the server again (`requestRestore`).
        static let restoreFileIds = "restoreFileIds"
        static func rootETag(_ folder: String) -> String { "rootETag:\(folder)" }
    }

    public var lastSyncDate: Date? {
        (try? database.syncValue(Key.lastDeltaSync)).flatMap { $0.flatMap(Double.init) }.map { Date(timeIntervalSince1970: $0) }
    }

    var indexProperties: [QName] {
        DAVProp.mediaIndex + (features.has(.placeCountry) ? [DAVProp.metadataPlaceCountry] : [])
            + (features.has(.captions) ? [DAVProp.metadataCaption] : [])
            + (features.has(.mediaDuration) ? [DAVProp.metadataDuration] : [])
    }

    var mimeTypes: [String] { features.allMimeTypes + MimeTypes.appleExtras }

    /// Source folders plus the archive folder (SPEC §7.13).
    var baseScopes: [String] {
        var folders = features.userConfig.photosSourceFolders
        if !folders.contains("/") && !folders.contains("/.archive") { folders.append("/.archive") }
        return folders
    }

    /// What is indexed: the timeline folders and the partner folders (`PartnerTimeline.swift`).
    var scopes: [String] {
        let base = baseScopes
        return base + partnerScopes(base: base)
    }

    // MARK: Entry points

    /// Runs whatever sync is due. Coalesces concurrent calls.
    ///
    /// A `forceReconcile` request made while a sync is already running is remembered: the caller waits for the running
    /// sync and then runs another one that reconciles. Cancelling the calling task cancels the running sync.
    public func sync(forceReconcile: Bool = false) async {
        if forceReconcile { reconcileRequested = true }
        await withTaskCancellationHandler {
            while !Task.isCancelled {
                if let running {
                    await running.value
                    // The sync that just finished may have started before the reconcile was requested.
                    guard forceReconcile, reconcileRequested else { return }
                    continue
                }
                let force = reconcileRequested
                reconcileRequested = false
                let task = Task {
                    await self.performSync(forceReconcile: force)
                    // Cleared by the task itself, so no waiter can observe a finished task as still running.
                    self.running = nil
                }
                running = task
                await task.value
                return
            }
        } onCancel: {
            Task { await self.cancelRunning() }
        }
    }

    private func cancelRunning() {
        running?.cancel()
    }

    /// Cancels a running sync and waits until it has stopped (account switch, removal).
    public func shutdown() async {
        running?.cancel()
        await running?.value
    }

    private func performSync(forceReconcile: Bool) async {
        var reconciled = false
        defer {
            // A requested reconcile that did not finish (offline, cancelled, failed) stays due for the next sync.
            if forceReconcile && !reconciled { reconcileRequested = true }
        }
        do {
            // Partner folders are not part of the key: adding or removing one changes the index by itself, not by a rebuild.
            let folderKey = baseScopes.joined(separator: "|")
            if try database.syncValue(Key.sourceFolders) != folderKey {
                // Timeline folders changed: rebuild the index. Albums and their content do not depend on the folders
                // and stay (offline albums hang on them).
                try library.deleteIndex()
                try database.setSyncValue(Key.sourceFolders, folderKey)
            }
            try await restoreRows()
            // Root ETags are read once, before anything is fetched: a change that happens while we fetch then shows
            // up as a different ETag on the next sync instead of being missed.
            let roots = try await existingRoots(scopes)
            let folders = roots.map(\.folder)
            var changedRoots: [Root] = []
            let isInitial = try database.syncValue(Key.initialComplete) != "1"
            if isInitial {
                try await initialSync(roots)
            } else {
                publish(.syncing)
                changedRoots = try await incrementalSync(roots)
            }
            let sinceReconcile = Date().timeIntervalSince1970 - (try database.syncValue(Key.lastReconcile).flatMap(Double.init) ?? 0)
            // Deletes and moves do not show up in the delta SEARCH, only in a reconciliation: one is owed after any
            // change below a source folder, but not more often than `reconcileInterval`.
            let owed = try !changedRoots.isEmpty || database.syncValue(Key.reconcileOwed) == "1"
            let confirming = try database.syncValue(Key.suspectedMassDelete) != nil
            if forceReconcile || confirming || sinceReconcile > 24 * 3600 || (owed && sinceReconcile >= reconcileInterval) {
                try await reconcile(folders: folders)
                reconciled = true
            } else {
                // Remembered before the root ETags are stored: the next syncs see no changed root any more.
                if owed { try database.setSyncValue(Key.reconcileOwed, "1") }
                // Favourites do not change any ETag; without a reconciliation they need their own (cheap) check.
                try await syncFavorites(folders: folders)
            }
            // Only now: if the reconciliation was interrupted, the next sync must still see these roots as changed.
            try storeRootETags(changedRoots)
            publish(.idle(lastSync: lastSyncDate))
        } catch let error as NetworkError where error == .offline || error == .timedOut {
            publish(.offline(lastSync: lastSyncDate))
        } catch let error where error is CancellationError || (error as? NetworkError) == .cancelled {
            publish(.idle(lastSync: lastSyncDate))
        } catch {
            logger.error("sync failed: \(error.localizedDescription, privacy: .public)")
            publish(.failed(message: error.localizedDescription, lastSync: lastSyncDate))
        }
    }

    /// A source folder that exists on the server, with its recursive ETag as read at the start of the sync.
    struct Root: Sendable, Equatable {
        var folder: String
        var etag: String?
    }

    /// Source folders that exist (a missing folder makes the whole SEARCH fail with 404), with their current ETags.
    func existingRoots(_ folders: [String]) async throws -> [Root] {
        var result: [Root] = []
        for folder in folders {
            try Task.checkCancellation()
            do {
                result.append(Root(folder: folder, etag: try await api.folderETag(folder)))
            } catch NetworkError.notFound {
                if folder == features.userConfig.photosLocation {
                    try? await api.dav.mkcolRecursive(userPath: folder)
                    // Unknown ETag: counts as changed on the next sync.
                    result.append(Root(folder: folder, etag: nil))
                }
            }
        }
        return result
    }

    func storeRootETags(_ roots: [Root]) throws {
        for root in roots { try database.setSyncValue(Key.rootETag(root.folder), root.etag) }
    }

    // MARK: Initial sync

    func initialSync(_ roots: [Root]) async throws {
        let started = Date()
        let folders = roots.map(\.folder)
        var cursor = try database.syncValue(Key.initialCursor).flatMap(Double.init)
        var fetched = try library.count()
        publish(.initialSync(itemsFetched: fetched))
        while true {
            try Task.checkCancellation()
            let page = try await api.indexPage(
                sourceFolders: folders, mimeTypes: mimeTypes, properties: indexProperties, order: .captureTime, before: cursor)
            try upsertFromServer(page.items)
            fetched += page.items.count
            publish(.initialSync(itemsFetched: fetched))
            guard let next = page.next else { break }
            cursor = next
            try database.setSyncValue(Key.initialCursor, String(next))
        }
        // The ETags from before the first page; whatever changed since is picked up by the next delta sync.
        try storeRootETags(roots)
        try database.setSyncValue(Key.initialComplete, "1")
        try database.setSyncValue(Key.initialCursor, nil)
        try database.setSyncValue(Key.lastDeltaSync, String(started.timeIntervalSince1970))
        // Items without a capture time are not reachable by capture-time paging; reconcile soon.
        try database.setSyncValue(Key.lastReconcile, "0")
    }

    // MARK: Incremental

    /// Fetches what changed below roots whose ETag differs from the stored one. Returns those roots; the caller stores
    /// their new ETags once the following reconciliation is through.
    func incrementalSync(_ roots: [Root]) async throws -> [Root] {
        let started = Date()
        var changedRoots: [Root] = []
        for root in roots {
            let stored = try database.syncValue(Key.rootETag(root.folder))
            if root.etag == nil || root.etag != stored { changedRoots.append(root) }
        }
        if !changedRoots.isEmpty {
            let last = try database.syncValue(Key.lastDeltaSync).flatMap(Double.init) ?? 0
            let since = Date(timeIntervalSince1970: max(0, last - 600))
            let changed = try await api.changedItems(
                since: since, sourceFolders: changedRoots.map(\.folder), mimeTypes: mimeTypes, properties: indexProperties)
            try upsertFromServer(changed)
        }
        // Metadata the server fills in later (place, caption, EXIF on external storage) changes no ETag: refresh recent
        // uploads on every sync.
        let recent = try recentUploads(within: 48 * 3600)
        if !recent.isEmpty {
            try Task.checkCancellation()
            let refreshed = try await api.items(fileIds: recent, properties: indexProperties)
            try upsertFromServer(refreshed)
        }
        try database.setSyncValue(Key.lastDeltaSync, String(started.timeIntervalSince1970))
        return changedRoots
    }

    func recentUploads(within seconds: TimeInterval) throws -> [FileID] {
        let threshold = Date().timeIntervalSince1970 - seconds
        return try database.writer.read { db in
            try FileID.fetchAll(db, sql: "SELECT fileId FROM media WHERE uploadedAt > ? LIMIT 500", arguments: [threshold])
        }
    }

    /// Server state wins, except for files with operations still in the outbox (SPEC §5.4.5): their optimistic local
    /// state must not be overwritten (or a locally deleted file brought back) before the operation ran.
    func upsertFromServer(_ items: [MediaItem]) throws {
        guard !items.isEmpty else { return }
        let pending = try pendingFileIds()
        try library.upsert(pending.isEmpty ? items : items.filter { !pending.contains($0.fileId) })
    }

    func pendingFileIds() throws -> Set<FileID> {
        try database.writer.read { db in try Outbox.pendingFileIds(db) }
    }

    // MARK: Favourites

    /// Aligns the favourite flags with the server. Setting a favourite changes neither the file's nor any folder's
    /// ETag, so neither the root ETag check nor the delta SEARCH notice it. One SEARCH that returns only file ids.
    func syncFavorites(folders: [String]) async throws {
        guard !folders.isEmpty else { return }
        try Task.checkCancellation()
        let search = DAVSearch(
            select: [DAVProp.fileId],
            scopes: folders.map { DAVSearch.Scope(href: api.connection.filesHref($0)) },
            condition: .and([PhotosAPI.mimeCondition(mimeTypes), .eq(DAVProp.favorite, "1")])
        )
        let remote = Set(try await api.dav.search(search, timeout: 300).compactMap { $0.int64(DAVProp.fileId) })
        try await database.writer.write { db in
            let pending = try Outbox.pendingFileIds(db)
            let local = Set(try FileID.fetchAll(db, sql: "SELECT fileId FROM media WHERE isFavorite = 1"))
            for (value, ids) in [(true, remote.subtracting(local)), (false, local.subtracting(remote))] {
                let ids = ids.subtracting(pending)
                guard !ids.isEmpty else { continue }
                // Ids the index does not know (yet) match no row.
                try db.execute(
                    sql: "UPDATE media SET isFavorite = ? WHERE fileId IN (\(ids.map { String($0) }.joined(separator: ",")))",
                    arguments: [value])
            }
        }
    }

    // MARK: Reconciliation

    /// What reconciliation compares per item: everything the cheap reconcile properties can tell.
    struct ReconcileKey: Equatable {
        var etag: String
        var path: String
        var isFavorite: Bool
        var place: String
        var caption: String
    }

    /// Pages through everything by modification time: removes deleted items, fixes moves, fetches unknown ones and
    /// those whose ETag, favourite flag, place or caption differ.
    func reconcile(folders: [String]) async throws {
        var seen: Set<FileID> = []
        var cursor: Double?
        publish(.reconciling(itemsChecked: 0))
        let compareCaptions = features.has(.captions)
        let (known, pending): ([FileID: ReconcileKey], Set<FileID>) = try await database.writer.read { db in
            var map: [FileID: ReconcileKey] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT fileId, etag, path, isFavorite, place, caption FROM media") {
                map[row["fileId"]] = ReconcileKey(
                    etag: row["etag"], path: row["path"], isFavorite: row["isFavorite"], place: row["place"] ?? "",
                    caption: compareCaptions ? (row["caption"] ?? "") : "")
            }
            return (map, try Outbox.pendingFileIds(db))
        }
        let properties =
            DAVProp.mediaReconcile + [DAVProp.lastModified, DAVProp.contentType, DAVProp.metadataOriginalDateTime]
            + (compareCaptions ? [DAVProp.metadataCaption] : [])
        var toRefresh: [FileID] = []
        while !folders.isEmpty {
            try Task.checkCancellation()
            let page = try await api.indexPage(
                sourceFolders: folders, mimeTypes: mimeTypes, properties: properties, order: .modified, before: cursor, limit: 2000)
            for item in page.items where seen.insert(item.fileId).inserted {
                let key = ReconcileKey(
                    etag: item.etag, path: item.path, isFavorite: item.isFavorite, place: item.place ?? "",
                    caption: compareCaptions ? (item.caption ?? "") : "")
                // Files with queued operations keep their optimistic local state until the outbox ran.
                if known[item.fileId] != key && !pending.contains(item.fileId) { toRefresh.append(item.fileId) }
            }
            publish(.reconciling(itemsChecked: seen.count))
            guard let next = page.next else { break }
            cursor = next
        }
        let removed = Array(Set(known.keys).subtracting(seen))
        // A listing that lacks a large part of the library is more often a server that answered incompletely (a storage
        // that is not mounted, a search cut short) than a real mass delete. It is not applied at once: the next sync
        // reconciles again, and what that second listing says is applied, so a real mass delete gets through then.
        let unconfirmed = try database.syncValue(Key.suspectedMassDelete) == nil
        if unconfirmed, Self.isSuspiciousRemoval(removed: removed.count, known: known.count) {
            try database.setSyncValue(Key.suspectedMassDelete, String(removed.count))
            logger.notice(
                "reconcile: \(removed.count) of \(known.count) items missing on the server; waiting for the next listing to confirm")
        } else {
            try library.delete(removed)
            try database.setSyncValue(Key.suspectedMassDelete, nil)
        }
        for chunk in stride(from: 0, to: toRefresh.count, by: 200).map({ Array(toRefresh[$0..<min($0 + 200, toRefresh.count)]) }) {
            try Task.checkCancellation()
            try library.upsert(try await api.items(fileIds: chunk, properties: indexProperties))
        }
        try database.setSyncValue(Key.lastReconcile, String(Date().timeIntervalSince1970))
        try database.setSyncValue(Key.reconcileOwed, nil)
        logger.info("reconciled: \(seen.count) items, \(removed.count) removed, \(toRefresh.count) refreshed")
    }

    /// Whether removing `removed` of `known` indexed items needs a confirming second listing: more than half of an
    /// index that is not tiny.
    static func isSuspiciousRemoval(removed: Int, known: Int) -> Bool {
        known > massDeleteMinimumIndex && removed * 2 > known
    }

    static let massDeleteMinimumIndex = 20

    // MARK: Restoring rows

    /// Marks rows whose local state is no longer backed by a queued operation (it failed for good or was discarded):
    /// they are read from the server again by `restoreRows()`, now or at the next sync.
    static func requestRestore(_ fileIds: some Sequence<FileID>, db: Database) throws {
        let ids = try restoreRequests(db).union(fileIds)
        try db.execute(
            sql: "INSERT OR REPLACE INTO syncState(key, value) VALUES (?, ?)",
            arguments: [Key.restoreFileIds, ids.isEmpty ? nil : ids.sorted().map(String.init).joined(separator: ",")])
    }

    static func restoreRequests(_ db: Database) throws -> Set<FileID> {
        let value = try String.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = ?", arguments: [Key.restoreFileIds]) ?? ""
        return Set(value.split(separator: ",").compactMap { FileID($0) })
    }

    /// Reads the rows marked by `requestRestore` from the server: the optimistic change of an operation that never
    /// reached the server is undone (a deleted photo comes back, a favourite or archive flag is what the server has).
    /// A file the server no longer has is removed from the index. Files with operations still queued are left alone.
    public func restoreRows() async throws {
        let requested = try await database.writer.read { db in try Self.restoreRequests(db) }
        guard !requested.isEmpty else { return }
        let ids = requested.sorted()
        let items = try await api.items(fileIds: ids, properties: indexProperties)
        let found = Set(items.map(\.fileId))
        try await database.writer.write { db in
            let pending = try Outbox.pendingFileIds(db)
            let gone = requested.subtracting(found).subtracting(pending)
            _ = try MediaItem.deleteAll(db, keys: Array(gone))
            // What was requested meanwhile stays requested.
            let remaining = try Self.restoreRequests(db).subtracting(requested)
            try db.execute(
                sql: "INSERT OR REPLACE INTO syncState(key, value) VALUES (?, ?)",
                arguments: [Key.restoreFileIds, remaining.isEmpty ? nil : remaining.sorted().map(String.init).joined(separator: ",")])
        }
        try upsertFromServer(items)
    }

    // MARK: Collections

    public func refreshAlbums() async throws {
        let extended = features.has(.albumCover) || features.has(.albumComments) || features.has(.albumLastModified)
        let own = try await api.listAlbums(.own, extended: extended)
        try collections.replaceAlbums(own, kind: .own)
        let shared = try await api.listAlbums(.shared, extended: extended)
        try collections.replaceAlbums(shared, kind: .shared)
    }

    public func refreshAlbumContent(_ album: Album) async throws {
        let children = try await api.albumContent(album)
        try collections.replaceAlbumContent(albumId: album.id, children: children)
    }

    public func refreshPlaces() async throws {
        guard features.has(.places) else { return }
        try collections.replacePlaces(try await api.listPlaces(withCountry: features.has(.placeCountry)))
    }
}
