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

/// How much reconciling a sync may do (SPEC §5.4.4). A reconciliation walks through the whole library on the server; on
/// a large one that is minutes of work, so only "Sync now" asks for it unconditionally.
public enum ReconcileRequest: Int, Sendable, Comparable {
    /// Only when one is due: after a change below a source folder, at most every `SyncEngine.reconcileInterval` (longer
    /// for large libraries) and not while a backup uploads; at the latest a day after the last one.
    case ifDue
    /// The app was opened (launched, or back in front after a while): after a change below a source folder at once,
    /// without the interval. Deletes and moves made elsewhere then show up in the first sync after the launch; the
    /// interval hid them for up to ten minutes when the app had been open shortly before. Nothing is walked when no
    /// root ETag changed, and the walk is resumable like any other.
    case opened
    /// Pull to refresh: like `opened`, and also when no root ETag changed, but then not more often than every
    /// `SyncEngine.reconcileInterval`.
    case refresh
    /// "Sync now": at once.
    case now

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Keeps the local index in sync with the server (SPEC §5.4).
public actor SyncEngine {
    public let api: PhotosAPI
    public let library: LibraryStore
    public let collections: CollectionStore
    private var features: ServerFeatures
    private let logger = Logger(subsystem: "com.nextcloud.photos", category: "sync")
    private var running: Task<Void, Never>?
    /// The strongest reconcile request ("Sync now", pull-to-refresh) that has not been taken up by a sync yet.
    private var requested = ReconcileRequest.ifDue
    private var statusHandler: (@Sendable (SyncStatus) -> Void)?
    private var lastStatus: SyncStatus = .idle(lastSync: nil)
    /// Says whether a reconciliation nobody asked for should wait (a backup is uploading).
    private var reconcileDeferral: (@Sendable () async -> Bool)?
    /// Runs after every completed full reconcile (`setAfterFullReconcile`, OrphanRecipes.swift).
    var afterFullReconcile: (@Sendable () async -> Void)?

    /// The shortest time between two full reconciliations that nobody asked for (seconds); 0 reconciles on every sync.
    ///
    /// Any change below a source folder changes its ETag, and on a busy account (a phone backing up, a shared folder)
    /// that is nearly every sync. New and changed files arrive through the delta SEARCH at once; only deletes and moves
    /// made elsewhere need the walk through the whole library, and those can wait this long. A large library waits
    /// longer (`interval(forIndexOf:)`). Pull-to-refresh is held back by this interval only, "Sync now" not at all.
    let reconcileInterval: TimeInterval
    public static let defaultReconcileInterval: TimeInterval = 600

    /// How long a listing that lacks many items (or items on mounted storage) waits before a second listing may confirm
    /// the removal (`applyRemovals`).
    let massDeleteConfirmationDelay: TimeInterval
    public static let defaultMassDeleteConfirmationDelay: TimeInterval = 3600

    /// The shortest time between two looks at the late metadata of recent uploads (`recentUploadsToRefresh`).
    let recentUploadsCheckInterval: TimeInterval
    public static let defaultRecentUploadsCheckInterval: TimeInterval = 600

    public init(
        api: PhotosAPI, database: AccountDatabase, features: ServerFeatures,
        reconcileInterval: TimeInterval = SyncEngine.defaultReconcileInterval,
        massDeleteConfirmationDelay: TimeInterval = SyncEngine.defaultMassDeleteConfirmationDelay,
        recentUploadsCheckInterval: TimeInterval = SyncEngine.defaultRecentUploadsCheckInterval
    ) {
        self.api = api
        self.library = LibraryStore(database: database)
        self.collections = CollectionStore(database: database)
        self.features = features
        self.reconcileInterval = reconcileInterval
        self.massDeleteConfirmationDelay = massDeleteConfirmationDelay
        self.recentUploadsCheckInterval = recentUploadsCheckInterval
    }

    var database: AccountDatabase { library.database }

    public func setStatusHandler(_ handler: @escaping @Sendable (SyncStatus) -> Void) {
        statusHandler = handler
        handler(lastStatus)
    }

    public func updateFeatures(_ features: ServerFeatures) {
        self.features = features
    }

    /// `deferral` returns true while reconciliations that nobody asked for should wait (the session: a backup pass is
    /// running, whose uploads change the root ETag all the time and need the bandwidth). A walk that was already under
    /// way waits too; it resumes where it stopped.
    public func setReconcileDeferral(_ deferral: (@Sendable () async -> Bool)?) {
        reconcileDeferral = deferral
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
        /// Set while a listing that would have removed many items (or items on mounted storage) is not applied yet: the
        /// time of that listing. The rows it lacked are in `reconcileSuspect`.
        static let suspectedMassDelete = "suspectedMassDelete"
        /// Comma-separated file ids whose rows must be read from the server again (`requestRestore`).
        static let restoreFileIds = "restoreFileIds"
        /// A reconciliation walk is under way: the folders it walks (`|`-separated). Its unseen rows are in `reconcileUnseen`.
        static let reconcileWalk = "reconcileWalk"
        /// Where the walk goes on: the modification time of the next page, or "end" when only the removals are left.
        static let reconcileCursor = "reconcileCursor"
        /// Items the walk has checked so far (progress) and the size of the index when it began.
        static let reconcileChecked = "reconcileChecked"
        static let reconcileKnown = "reconcileKnown"
        /// When the late metadata of recent uploads was last refreshed.
        static let recentUploadsChecked = "recentUploadsChecked"
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
    /// A reconcile request (`.refresh`, `.now`) made while a sync is already running is remembered: the caller waits for
    /// the running sync and then runs another one that honours it. Cancelling the calling task cancels the running sync.
    public func sync(reconcile request: ReconcileRequest = .ifDue) async {
        if request > .ifDue { requested = max(requested, request) }
        await withTaskCancellationHandler {
            while !Task.isCancelled {
                if let running {
                    await running.value
                    // The sync that just finished may have started before the reconcile was requested.
                    guard request > .ifDue, requested > .ifDue else { return }
                    continue
                }
                let next = requested
                requested = .ifDue
                let task = Task {
                    await self.performSync(next)
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

    /// `sync(reconcile: .now)` or `sync(reconcile: .ifDue)`.
    public func sync(forceReconcile: Bool) async {
        await sync(reconcile: forceReconcile ? .now : .ifDue)
    }

    private func cancelRunning() {
        running?.cancel()
    }

    /// Cancels a running sync and waits until it has stopped (account switch, removal).
    public func shutdown() async {
        running?.cancel()
        await running?.value
    }

    private func performSync(_ request: ReconcileRequest) async {
        var reconciled = false
        var reconcileAttempted = false
        defer {
            // A requested reconcile that did not finish (offline, cancelled, failed) stays due for the next sync: "Sync now"
            // always, pull-to-refresh when it had begun to walk.
            if !reconciled && (request == .now || (request == .refresh && reconcileAttempted)) { requested = max(requested, request) }
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
            // Deletes and moves do not show up in the delta SEARCH, only in a reconciliation: one is owed after any
            // change below a source folder, but not more often than the interval.
            let owed = try !changedRoots.isEmpty || database.syncValue(Key.reconcileOwed) == "1"
            if request == .now {
                reconcileAttempted = true
            } else {
                reconcileAttempted = try await reconcileDue(request, owed: owed)
            }
            if reconcileAttempted {
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

    /// Whether a sync that was not told to reconcile at once (`.ifDue`, `.opened`, `.refresh`) walks through the library
    /// now. `owed`: a source folder changed since the last walk (now or in an earlier sync).
    func reconcileDue(_ request: ReconcileRequest, owed: Bool) async throws -> Bool {
        let now = Date().timeIntervalSince1970
        let sinceReconcile = now - (try database.syncValue(Key.lastReconcile).flatMap(Double.init) ?? 0)
        // A walk that stopped half-way (the app went to the background) goes on where it stopped.
        let walking = try database.syncValue(Key.reconcileWalk) != nil
        let confirming =
            try database.syncValue(Key.suspectedMassDelete).flatMap(Double.init).map {
                now - $0 >= massDeleteConfirmationDelay
            } ?? false
        let overdue = sinceReconcile > 24 * 3600
        let due: Bool
        switch request {
        case .now: return true
        case .refresh: due = walking || confirming || overdue || owed || sinceReconcile >= reconcileInterval
        case .opened: due = walking || confirming || overdue || owed
        case .ifDue:
            due = try walking || confirming || overdue || (owed && sinceReconcile >= interval(forIndexOf: library.count()))
        }
        guard due else { return false }
        // Not while a backup uploads (its uploads are what changed the root), unless the last one is a day old.
        if request == .ifDue, !overdue, let reconcileDeferral, await reconcileDeferral() { return false }
        return true
    }

    /// The interval between reconciliations nobody asked for, for an index of `count` items: a walk costs about one
    /// request per thousand items, so a large library is walked less often (150 000 items: once an hour at most).
    func interval(forIndexOf count: Int) -> TimeInterval {
        reconcileInterval == 0 ? 0 : max(reconcileInterval, Double(count) * 0.024)
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
        // Metadata the server fills in later (place, caption, EXIF on external storage) changes no ETag: look at recent
        // uploads again, a few times while it may still arrive.
        let now = Date().timeIntervalSince1970
        if let recent = try recentUploadsToRefresh(now: now) {
            if !recent.isEmpty {
                try Task.checkCancellation()
                let refreshed = try await api.items(fileIds: recent, properties: indexProperties)
                try upsertFromServer(refreshed)
            }
            try database.setSyncValue(Key.recentUploadsChecked, String(now))
        }
        try database.setSyncValue(Key.lastDeltaSync, String(started.timeIntervalSince1970))
        return changedRoots
    }

    /// After an upload, how long until its late metadata is looked for again: each recent upload is read once more at
    /// each of these ages, not on every sync.
    static let recentUploadCheckpoints: [TimeInterval] = [600, 3600, 6 * 3600, 24 * 3600, 47 * 3600]

    /// Recent uploads (48 h) whose place is still unknown and that reached a checkpoint since the last look; `nil` when
    /// the last look is less than `recentUploadsCheckInterval` ago. The first look takes all of them.
    func recentUploadsToRefresh(now: Double) throws -> [FileID]? {
        let last = try database.syncValue(Key.recentUploadsChecked).flatMap(Double.init)
        if let last, now - last < recentUploadsCheckInterval, now >= last { return nil }
        var arguments: StatementArguments = [now - 48 * 3600]
        var reached = ""
        if let last, now >= last {
            var ranges: [String] = []
            for checkpoint in Self.recentUploadCheckpoints {
                arguments += [last - checkpoint, now - checkpoint]
                ranges.append("(uploadedAt > ? AND uploadedAt <= ?)")
            }
            reached = " AND (" + ranges.joined(separator: " OR ") + ")"
        }
        let sql = "SELECT fileId FROM media WHERE uploadedAt > ? AND place IS NULL\(reached) ORDER BY uploadedAt DESC"
        return try database.writer.read { [arguments] db in try FileID.fetchAll(db, sql: sql, arguments: arguments) }
    }

    /// Server state wins, except for files with operations still in the outbox (SPEC §5.4.5): their optimistic local
    /// state must not be overwritten (or a locally deleted file brought back) before the operation ran.
    func upsertFromServer(_ items: [MediaItem]) throws {
        guard !items.isEmpty else { return }
        let pending = try pendingFileIds()
        try library.upsert(pending.isEmpty ? items : items.filter { !pending.contains($0.fileId) })
        // What the server just listed exists: a reconciliation walk that is under way need not look for it any more (its
        // modification time may have moved past the walk's cursor).
        if try database.syncValue(Key.reconcileWalk) != nil {
            try database.writer.write { db in try Self.markSeen(items.map(\.fileId), db: db) }
        }
    }

    static func markSeen(_ fileIds: [FileID], db: Database) throws {
        for chunk in fileIds.chunked(500) {
            try db.execute(sql: "DELETE FROM reconcileUnseen WHERE fileId IN (\(chunk.map { String($0) }.joined(separator: ",")))")
        }
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
    ///
    /// The walk can be interrupted at any page (the app goes to the background, the network drops) and goes on from there
    /// at the next sync: which rows it has not met yet is kept in `reconcileUnseen`, the cursor in the sync state. Only
    /// one page of the server's listing and the stored rows of that page are in memory at a time.
    func reconcile(folders: [String]) async throws {
        let walk = folders.joined(separator: "|")
        var cursor: Double?
        var finished = false
        var checked = 0
        var known = 0
        if try database.syncValue(Key.reconcileWalk) == walk {
            let stored = try database.syncValue(Key.reconcileCursor)
            finished = stored == "end"
            cursor = stored.flatMap(Double.init)
            checked = try database.syncValue(Key.reconcileChecked).flatMap { Int($0) } ?? 0
            known = try database.syncValue(Key.reconcileKnown).flatMap { Int($0) } ?? 0
            logger.info("reconcile: resuming after \(checked) items")
        } else {
            // A new walk (or the folders changed since the last one began): every row of the index is unseen.
            known = try await database.writer.write { db in
                try db.execute(sql: "DELETE FROM reconcileUnseen")
                try db.execute(sql: "INSERT INTO reconcileUnseen(fileId) SELECT fileId FROM media")
                let count = db.changesCount
                try Self.setValues(
                    [Key.reconcileWalk: walk, Key.reconcileCursor: nil, Key.reconcileChecked: "0", Key.reconcileKnown: String(count)],
                    db: db)
                return count
            }
        }
        publish(.reconciling(itemsChecked: checked))
        let compareCaptions = features.has(.captions)
        let pending = try pendingFileIds()
        let properties =
            DAVProp.mediaReconcile + [DAVProp.lastModified, DAVProp.contentType, DAVProp.metadataOriginalDateTime]
            + (compareCaptions ? [DAVProp.metadataCaption] : [])
        var refreshed = 0
        while !finished && !folders.isEmpty {
            try Task.checkCancellation()
            let page = try await api.indexPage(
                sourceFolders: folders, mimeTypes: mimeTypes, properties: properties, order: .modified, before: cursor, limit: 2000)
            var ids: [FileID] = []
            var items: [MediaItem] = []
            var seen: Set<FileID> = []
            for item in page.items where seen.insert(item.fileId).inserted {
                ids.append(item.fileId)
                items.append(item)
            }
            let stored = try await Self.reconcileKeys(ids, compareCaptions: compareCaptions, database: database)
            var toRefresh: [FileID] = []
            for item in items {
                let key = ReconcileKey(
                    etag: item.etag, path: item.path, isFavorite: item.isFavorite, place: item.place ?? "",
                    caption: compareCaptions ? (item.caption ?? "") : "")
                // Files with queued operations keep their optimistic local state until the outbox ran.
                if stored[item.fileId] != key && !pending.contains(item.fileId) { toRefresh.append(item.fileId) }
            }
            // Fetched before the page counts as done: a walk interrupted here fetches them again.
            for chunk in toRefresh.chunked(200) {
                try Task.checkCancellation()
                try library.upsert(try await api.items(fileIds: Array(chunk), properties: indexProperties))
            }
            refreshed += toRefresh.count
            checked += ids.count
            let next = page.next
            let progress = checked
            try await database.writer.write { [ids] db in
                try Self.markSeen(ids, db: db)
                try Self.setValues([Key.reconcileCursor: next.map { String($0) } ?? "end", Key.reconcileChecked: String(progress)], db: db)
            }
            publish(.reconciling(itemsChecked: checked))
            guard let next else { break }
            cursor = next
        }
        let removed = try await database.writer.read { db in
            try FileID.fetchAll(db, sql: "SELECT fileId FROM reconcileUnseen WHERE fileId IN (SELECT fileId FROM media)")
        }
        let applied = try await applyRemovals(Set(removed), known: known, folders: folders)
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM reconcileUnseen")
            try Self.setValues(
                [
                    Key.reconcileWalk: nil, Key.reconcileCursor: nil, Key.reconcileChecked: nil, Key.reconcileKnown: nil,
                    Key.lastReconcile: String(Date().timeIntervalSince1970), Key.reconcileOwed: nil,
                ], db: db)
        }
        logger.info("reconciled: \(checked) items, \(applied) of \(removed.count) missing removed, \(refreshed) refreshed")
        if let afterFullReconcile { Task { await afterFullReconcile() } }
    }

    /// The stored comparison keys of some rows.
    static func reconcileKeys(_ ids: [FileID], compareCaptions: Bool, database: AccountDatabase) async throws -> [FileID: ReconcileKey] {
        try await database.writer.read { db in
            var map: [FileID: ReconcileKey] = [:]
            map.reserveCapacity(ids.count)
            for chunk in ids.chunked(500) {
                let sql =
                    "SELECT fileId, etag, path, isFavorite, place, caption FROM media WHERE fileId IN (\(chunk.map { String($0) }.joined(separator: ",")))"
                for row in try Row.fetchAll(db, sql: sql) {
                    map[row[0]] = ReconcileKey(
                        etag: row[1], path: row[2], isFavorite: row[3], place: row[4] ?? "", caption: compareCaptions ? (row[5] ?? "") : "")
                }
            }
            return map
        }
    }

    static func setValues(_ values: [String: String?], db: Database) throws {
        for (key, value) in values {
            try db.execute(sql: "INSERT OR REPLACE INTO syncState(key, value) VALUES (?, ?)", arguments: [key, value])
        }
    }

    // MARK: Mass-delete guard

    /// Removes the rows a finished walk did not meet, unless the listing looks like a server that answered incompletely
    /// (a storage that is not mounted, a search cut short) rather than files that were deleted. Returns how many rows
    /// were removed.
    ///
    /// - Rows on the user's own storage go at once, unless more than half of the index is missing.
    /// - Rows on mounted storage (external storage, shares, group folders: storage that can be away for a while) and a
    ///   suspiciously large removal are kept as suspects. A later listing removes a suspect only when it lacks it too, at
    ///   least `massDeleteConfirmationDelay` after the first one, and when the server answers "not found" for a sample
    ///   of them by path (an external storage that is not available answers with an error, not with 404).
    func applyRemovals(_ removed: Set<FileID>, known: Int, folders: [String]) async throws -> Int {
        let now = Date().timeIntervalSince1970
        let suspectedAt = try database.syncValue(Key.suspectedMassDelete).flatMap(Double.init)
        let suspects: Set<FileID> = try await database.writer.read { db in
            suspectedAt == nil ? [] : Set(try FileID.fetchAll(db, sql: "SELECT fileId FROM reconcileSuspect"))
        }
        // Both listings agree these are gone.
        let carried = removed.intersection(suspects)
        let fresh = removed.subtracting(suspects)
        let mounted: Set<FileID> = try await database.writer.read { db in
            var mounted: Set<FileID> = []
            for chunk in Array(fresh).chunked(500) {
                let list = chunk.map { String($0) }.joined(separator: ",")
                mounted.formUnion(try FileID.fetchAll(db, sql: "SELECT fileId FROM media WHERE fileId IN (\(list)) AND mountType != ''"))
            }
            return mounted
        }
        var remove: Set<FileID> = []
        var keep: Set<FileID> = []
        var keptSince = suspectedAt ?? now
        if !carried.isEmpty {
            if let suspectedAt, now - suspectedAt >= massDeleteConfirmationDelay, try await confirmGone(carried) {
                remove = carried
            } else {
                keep = carried
            }
        }
        // New suspects restart the clock for the whole set.
        if Self.isSuspiciousRemoval(removed: fresh.count, known: known) {
            keep.formUnion(fresh)
            keptSince = now
        } else {
            if !mounted.isEmpty {
                keep.formUnion(mounted)
                keptSince = now
            }
            remove.formUnion(try await verifyGone(fresh.subtracting(mounted), folders: folders))
        }
        try await database.writer.write { [keep, keptSince] db in
            try db.execute(sql: "DELETE FROM reconcileSuspect")
            for id in keep { try db.execute(sql: "INSERT INTO reconcileSuspect(fileId) VALUES (?)", arguments: [id]) }
            try Self.setValues([Key.suspectedMassDelete: keep.isEmpty ? nil : String(keptSince)], db: db)
        }
        if !keep.isEmpty {
            logger.notice("reconcile: \(keep.count) of \(known) items missing on the server; waiting for another listing to confirm")
        }
        try library.delete(Array(remove))
        return remove.count
    }

    /// Whether removing `removed` of `known` indexed items needs a confirming second listing: more than half of an
    /// index that is not tiny.
    static func isSuspiciousRemoval(removed: Int, known: Int) -> Bool {
        known > massDeleteMinimumIndex && removed * 2 > known
    }

    static let massDeleteMinimumIndex = 20

    /// Asks the server for a sample of the suspects by path: true only when every one of them is not found (or another
    /// file is at its place now). An error (a storage that is not available) or a file that is still there means the
    /// listings were incomplete.
    func confirmGone(_ suspects: Set<FileID>) async throws -> Bool {
        let sorted = suspects.sorted()
        let step = max(1, sorted.count / 8)
        let sample = stride(from: 0, to: sorted.count, by: step).prefix(8).map { sorted[$0] }
        let paths: [(FileID, String)] = try await database.writer.read { db in
            try Row.fetchAll(
                db, sql: "SELECT fileId, path FROM media WHERE fileId IN (\(sample.map { String($0) }.joined(separator: ",")))"
            )
            .map { ($0[0], $0[1]) }
        }
        for (fileId, path) in paths {
            try Task.checkCancellation()
            do {
                let found = try await api.dav.propfind(api.connection.filesURL(path), depth: 0, properties: [DAVProp.fileId])
                if found.contains(where: { $0.int64(DAVProp.fileId) == fileId }) { return false }
            } catch NetworkError.notFound {
                continue
            } catch let error as NetworkError where error == .offline || error == .timedOut || error == .cancelled {
                throw error
            } catch {
                logger.notice("reconcile: a missing item could not be checked (\(error.localizedDescription, privacy: .public))")
                return false
            }
        }
        return true
    }

    /// The rows of `candidates` the server really does not have in the timeline any more. A walk that spans several
    /// syncs can miss a file whose modification time moved past its cursor; a small removal is checked by id (a few
    /// requests), a large one is left to the walk.
    func verifyGone(_ candidates: Set<FileID>, folders: [String]) async throws -> Set<FileID> {
        guard !candidates.isEmpty, candidates.count <= 200 else { return candidates }
        let found = try await api.items(fileIds: candidates.sorted(), properties: indexProperties)
        let mimeTypes = Set(self.mimeTypes)
        let alive = found.filter { item in
            mimeTypes.contains(item.mimeType) && folders.contains { $0 == "/" || item.path.hasPrefix($0 + "/") }
        }
        try upsertFromServer(alive)
        return candidates.subtracting(alive.map(\.fileId))
    }

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
    /// A file the server no longer has is removed from the index. Files with operations still queued are left alone, and
    /// so are files outside the timeline (an album photo stored elsewhere) that the index has no row for.
    public func restoreRows() async throws {
        let requested = try await database.writer.read { db in try Self.restoreRequests(db) }
        guard !requested.isEmpty else { return }
        let ids = requested.sorted()
        let fetched = try await api.items(fileIds: ids, properties: indexProperties)
        let found = Set(fetched.map(\.fileId))
        let indexed = try await database.writer.read { db in
            Set(
                try FileID.fetchAll(
                    db, sql: "SELECT fileId FROM media WHERE fileId IN (\(databaseQuestionMarks(count: ids.count)))",
                    arguments: StatementArguments(ids)))
        }
        let items = fetched.filter { indexed.contains($0.fileId) || isInTimeline($0) }
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

    /// Reads these files from the server again (files restored from the trash bin come back into the index).
    public func restore(fileIds: some Sequence<FileID> & Sendable) async throws {
        try await database.writer.write { db in try Self.requestRestore(fileIds, db: db) }
        try await restoreRows()
    }

    /// Whether the timeline indexes a file like this one: a type it shows, below a source folder or the archive.
    func isInTimeline(_ item: MediaItem) -> Bool {
        mimeTypes.contains(item.mimeType)
            && scopes.contains { scope in
                scope == "/" || item.path == scope || item.path.hasPrefix(scope.hasSuffix("/") ? scope : scope + "/")
            }
    }

    // MARK: Collections

    public func refreshAlbums() async throws {
        let extended = features.has(.albumCover) || features.has(.albumComments) || features.has(.albumLastModified)
        let own = try await api.listAlbums(.own, extended: extended)
        try collections.replaceAlbums(own, kind: .own)
        let shared = try await api.listAlbums(.shared, extended: extended)
        try collections.replaceAlbums(shared, kind: .shared)
    }

    /// Reads an album's content from the server, unless the album says it did not change.
    ///
    /// Album collections have no ETag (stock Photos), but their count, last-added photo and date range (and on extended
    /// servers the time something was last added) change with their content. A PROPFIND of the album alone (one small
    /// response) is compared with what these were when the content was last read; the full listing (thousands of
    /// entries) is only read when they differ, when the stored rows no longer match (a local change), for albums whose
    /// content is defined by filters, after a day, or with `force`.
    public func refreshAlbumContent(_ album: Album, force: Bool = false) async throws {
        let key = Self.albumFingerprintKey(album.id)
        var fingerprint: String?
        if album.kind != .publicLink, album.filters == AlbumFilters() {
            let extended = features.has(.albumCover) || features.has(.albumComments) || features.has(.albumLastModified)
            if let current = try await albumIfReadable(album, extended: extended) {
                fingerprint = Self.contentFingerprint(current)
                if !force, let stored = try database.syncValue(key), let fingerprint,
                    Self.contentUnchanged(
                        stored: stored, fingerprint: fingerprint, storedRows: try collections.albumItemCount(albumId: album.id))
                {
                    try collections.markAlbumContentFetched(albumId: album.id)
                    return
                }
            }
        }
        let children = try await api.albumContent(album)
        try collections.replaceAlbumContent(albumId: album.id, children: children)
        let rows = try collections.albumItemCount(albumId: album.id)
        try database.setSyncValue(key, fingerprint.map { "\($0)|\(rows)|\(Int(Date().timeIntervalSince1970))" })
    }

    /// The album alone; `nil` when the server does not answer for it (the full listing then says what is wrong).
    private func albumIfReadable(_ album: Album, extended: Bool) async throws -> Album? {
        do {
            return try await api.album(album, extended: extended)
        } catch let error as NetworkError where error == .offline || error == .timedOut || error == .cancelled {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    static func albumFingerprintKey(_ albumId: String) -> String { "albumContent:\(albumId)" }

    /// What an album says about its content without listing it.
    static func contentFingerprint(_ album: Album) -> String {
        [
            String(album.itemCount), album.lastPhotoFileId.map { String($0) } ?? "",
            album.dateStart.map { String($0.timeIntervalSince1970) } ?? "",
            album.dateEnd.map { String($0.timeIntervalSince1970) } ?? "", album.lastModified.map { String($0.timeIntervalSince1970) } ?? "",
        ].joined(separator: ",")
    }

    /// `stored` is "<fingerprint>|<rows stored then>|<time of the full read>".
    static func contentUnchanged(stored: String, fingerprint: String, storedRows: Int, now: Date = Date()) -> Bool {
        let parts = stored.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3, let rows = Int(parts[1]), let readAt = Double(parts[2]) else { return false }
        return parts[0] == fingerprint && rows == storedRows && now.timeIntervalSince1970 - readAt < 24 * 3600
    }

    public func refreshPlaces() async throws {
        guard features.has(.places) else { return }
        try collections.replacePlaces(try await api.listPlaces(withCountry: features.has(.placeCountry)))
    }
}
