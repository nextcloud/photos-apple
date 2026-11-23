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
    private var statusHandler: (@Sendable (SyncStatus) -> Void)?
    private var lastStatus: SyncStatus = .idle(lastSync: nil)

    public init(api: PhotosAPI, database: AccountDatabase, features: ServerFeatures) {
        self.api = api
        self.library = LibraryStore(database: database)
        self.collections = CollectionStore(database: database)
        self.features = features
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
    var scopes: [String] {
        var folders = features.userConfig.photosSourceFolders
        if !folders.contains("/") && !folders.contains("/.archive") { folders.append("/.archive") }
        return folders
    }

    // MARK: Entry points

    /// Runs whatever sync is due. Coalesces concurrent calls.
    public func sync(forceReconcile: Bool = false) async {
        if let running {
            await running.value
            return
        }
        let task = Task { await self.performSync(forceReconcile: forceReconcile) }
        running = task
        await task.value
        running = nil
    }

    /// Cancels a running sync and waits until it has stopped (account switch, removal).
    public func shutdown() async {
        running?.cancel()
        await running?.value
    }

    private func performSync(forceReconcile: Bool) async {
        do {
            let folderKey = scopes.joined(separator: "|")
            if try database.syncValue(Key.sourceFolders) != folderKey {
                // Timeline folders changed: rebuild the index.
                try library.deleteAll()
                try database.setSyncValue(Key.sourceFolders, folderKey)
            }
            if try database.syncValue(Key.initialComplete) != "1" {
                try await initialSync()
            } else {
                publish(.syncing)
                try await incrementalSync()
            }
            let lastReconcile = try database.syncValue(Key.lastReconcile).flatMap(Double.init) ?? 0
            if forceReconcile || Date().timeIntervalSince1970 - lastReconcile > 24 * 3600 {
                try await reconcile()
            }
            publish(.idle(lastSync: lastSyncDate))
        } catch let error as NetworkError where error == .offline || error == .timedOut {
            publish(.offline(lastSync: lastSyncDate))
        } catch is CancellationError {
            publish(.idle(lastSync: lastSyncDate))
        } catch {
            logger.error("sync failed: \(error.localizedDescription, privacy: .public)")
            publish(.failed(message: error.localizedDescription, lastSync: lastSyncDate))
        }
    }

    // MARK: Initial sync

    func initialSync() async throws {
        let started = Date()
        var cursor = try database.syncValue(Key.initialCursor).flatMap(Double.init)
        var fetched = try library.count()
        publish(.initialSync(itemsFetched: fetched))
        let folders = try await existingFolders(scopes)
        while true {
            try Task.checkCancellation()
            let page = try await api.indexPage(
                sourceFolders: folders, mimeTypes: mimeTypes, properties: indexProperties, order: .captureTime, before: cursor)
            try library.upsert(page.items)
            fetched += page.items.count
            publish(.initialSync(itemsFetched: fetched))
            guard let next = page.next else { break }
            cursor = next
            try database.setSyncValue(Key.initialCursor, String(next))
        }
        try await storeRootETags(folders)
        try database.setSyncValue(Key.initialComplete, "1")
        try database.setSyncValue(Key.initialCursor, nil)
        try database.setSyncValue(Key.lastDeltaSync, String(started.timeIntervalSince1970))
        // Items without a capture time are not reachable by capture-time paging; reconcile soon.
        try database.setSyncValue(Key.lastReconcile, "0")
    }

    /// Source folders that exist (a missing folder makes the whole SEARCH fail with 404).
    func existingFolders(_ folders: [String]) async throws -> [String] {
        var result: [String] = []
        for folder in folders {
            do {
                _ = try await api.folderETag(folder)
                result.append(folder)
            } catch NetworkError.notFound {
                if folder == features.userConfig.photosLocation {
                    try? await api.dav.mkcolRecursive(userPath: folder)
                    result.append(folder)
                }
            }
        }
        return result
    }

    func storeRootETags(_ folders: [String]) async throws {
        for folder in folders {
            if let etag = try? await api.folderETag(folder) { try database.setSyncValue(Key.rootETag(folder), etag) }
        }
    }

    // MARK: Incremental

    func incrementalSync() async throws {
        let started = Date()
        let folders = try await existingFolders(scopes)
        var changedFolders: [String] = []
        for folder in folders {
            let etag = try await api.folderETag(folder)
            if etag != (try database.syncValue(Key.rootETag(folder))) { changedFolders.append(folder) }
        }
        guard !changedFolders.isEmpty else {
            try database.setSyncValue(Key.lastDeltaSync, String(started.timeIntervalSince1970))
            return
        }
        let last = try database.syncValue(Key.lastDeltaSync).flatMap(Double.init) ?? 0
        let since = Date(timeIntervalSince1970: max(0, last - 600))
        let changed = try await api.changedItems(
            since: since, sourceFolders: changedFolders, mimeTypes: mimeTypes, properties: indexProperties)
        try library.upsert(changed)
        // Metadata the server fills in later (place, caption, EXIF on external storage): refresh recent uploads.
        let recent = try recentUploads(within: 48 * 3600)
        if !recent.isEmpty {
            let refreshed = try await api.items(fileIds: recent, properties: indexProperties)
            try library.upsert(refreshed)
        }
        try await storeRootETags(changedFolders)
        try database.setSyncValue(Key.lastDeltaSync, String(started.timeIntervalSince1970))
    }

    func recentUploads(within seconds: TimeInterval) throws -> [FileID] {
        let threshold = Date().timeIntervalSince1970 - seconds
        return try database.writer.read { db in
            try FileID.fetchAll(db, sql: "SELECT fileId FROM media WHERE uploadedAt > ? LIMIT 500", arguments: [threshold])
        }
    }

    // MARK: Reconciliation

    /// Pages through everything by modification time: removes deleted items, fixes moves, fetches unknown ones.
    func reconcile() async throws {
        let folders = try await existingFolders(scopes)
        var seen: Set<FileID> = []
        var cursor: Double?
        publish(.reconciling(itemsChecked: 0))
        let known: [FileID: String] = try await database.writer.read { db in
            var map: [FileID: String] = [:]
            for row in try GRDBRow.fetchAll(db, sql: "SELECT fileId, etag || '|' || path AS key FROM media") { map[row.0] = row.1 }
            return map
        }
        let properties = DAVProp.mediaReconcile + [DAVProp.lastModified, DAVProp.contentType, DAVProp.metadataOriginalDateTime]
        var toRefresh: [FileID] = []
        while true {
            try Task.checkCancellation()
            let page = try await api.indexPage(
                sourceFolders: folders, mimeTypes: mimeTypes, properties: properties, order: .modified, before: cursor, limit: 2000)
            for item in page.items {
                seen.insert(item.fileId)
                if known[item.fileId] != "\(item.etag)|\(item.path)" { toRefresh.append(item.fileId) }
            }
            publish(.reconciling(itemsChecked: seen.count))
            guard let next = page.next else { break }
            cursor = next
        }
        let removed = Array(Set(known.keys).subtracting(seen))
        try library.delete(removed)
        for chunk in stride(from: 0, to: toRefresh.count, by: 200).map({ Array(toRefresh[$0..<min($0 + 200, toRefresh.count)]) }) {
            try library.upsert(try await api.items(fileIds: chunk, properties: indexProperties))
        }
        try database.setSyncValue(Key.lastReconcile, String(Date().timeIntervalSince1970))
        logger.info("reconciled: \(seen.count) items, \(removed.count) removed, \(toRefresh.count) refreshed")
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

/// Helper to fetch `(Int64, String)` pairs.
enum GRDBRow {
    static func fetchAll(_ db: Database, sql: String) throws -> [(Int64, String)] {
        try Row.fetchAll(db, sql: sql).map { ($0[0], $0[1]) }
    }
}
