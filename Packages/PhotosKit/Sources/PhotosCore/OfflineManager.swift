// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import Network
import OSLog
import PhotosModel
import PhotosNetworking
import PhotosStore

/// What the offline download needs to know about the current network.
public struct NetworkConditions: Sendable, Equatable {
    public var isConnected: Bool
    /// Cellular or a personal hotspot.
    public var isExpensive: Bool
    /// Low Data Mode.
    public var isConstrained: Bool

    public init(isConnected: Bool = true, isExpensive: Bool = false, isConstrained: Bool = false) {
        self.isConnected = isConnected
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }

    init(_ path: NWPath) {
        self.init(isConnected: path.status == .satisfied, isExpensive: path.isExpensive, isConstrained: path.isConstrained)
    }
}

/// Offline albums and photos (SPEC §7.19): originals are downloaded into the account's Offline folder and kept in sync.
///
/// Originals are large, so by default they are only downloaded on Wi-Fi ("Download offline albums only on Wi-Fi" in Settings).
/// The folder is excluded from device backups (the files can be downloaded again), and the database stores file names
/// relative to it, because the absolute path of the app container changes when the app is restored or reinstalled.
public actor OfflineManager {
    let services: AccountServices
    let directory: URL
    private let wifiOnlySetting: @Sendable () -> Bool
    private let logger = Logger(subsystem: "com.nextcloud.photos", category: "offline")
    private var running: Task<Void, Never>?
    private var needsAnotherPass = false
    private var isShutDown = false
    /// The last pass skipped downloads because of the network; a change of network starts another one.
    public private(set) var isWaitingForWiFi = false
    private let pathMonitor = NWPathMonitor()
    /// Tests set the network instead of reading the real one.
    var networkOverride: NetworkConditions?

    /// `UserDefaults` key of "Download offline albums only on Wi-Fi" (default on).
    public static let wifiOnlyKey = "offlineWifiOnly"

    /// - Parameter wifiOnly: reads the "Wi-Fi only" setting; by default from the app's `UserDefaults`.
    public init(services: AccountServices, wifiOnly: @escaping @Sendable () -> Bool = OfflineManager.wifiOnlyDefault) {
        self.services = services
        self.wifiOnlySetting = wifiOnly
        self.directory = services.layout.offline(services.account.id)
        Self.prepare(directory)
        Self.makePathsRelative(in: services.database)
        pathMonitor.pathUpdateHandler = { [weak self] _ in Task { await self?.networkChanged() } }
        pathMonitor.start(queue: DispatchQueue(label: "com.nextcloud.photos.offline.path"))
    }

    /// Creates the folder and keeps it out of iCloud and computer backups.
    static func prepare(_ directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = directory
        try? url.setResourceValues(values)
    }

    /// Earlier versions stored absolute paths; keep only the file name.
    static func makePathsRelative(in database: AccountDatabase) {
        try? database.writer.write { db in
            let rows = try Row.fetchAll(db, sql: "SELECT fileId, localPath FROM offlineFile WHERE localPath LIKE '%/%'")
            for row in rows {
                let path: String = row["localPath"]
                let fileId: Int64 = row["fileId"]
                try db.execute(
                    sql: "UPDATE offlineFile SET localPath = ? WHERE fileId = ?", arguments: [storedPath(for: path), fileId])
            }
        }
    }

    /// What is stored in `offlineFile.localPath`: the file name inside the Offline folder.
    static func storedPath(for path: String) -> String { (path as NSString).lastPathComponent }

    /// The file a stored path points to (also resolves absolute paths written by earlier versions).
    nonisolated func url(forStored path: String) -> URL { directory.appending(path: Self.storedPath(for: path)) }

    // MARK: Network

    public static let wifiOnlyDefault: @Sendable () -> Bool = { UserDefaults.standard.object(forKey: wifiOnlyKey) as? Bool ?? true }

    public nonisolated var wifiOnly: Bool { wifiOnlySetting() }

    /// Originals are downloaded when there is a connection and, with "Wi-Fi only", it is neither cellular/hotspot nor in Low Data Mode.
    public static func downloadsAllowed(wifiOnly: Bool, network: NetworkConditions) -> Bool {
        guard network.isConnected else { return false }
        return !wifiOnly || (!network.isExpensive && !network.isConstrained)
    }

    var network: NetworkConditions { networkOverride ?? NetworkConditions(pathMonitor.currentPath) }

    func setNetwork(_ network: NetworkConditions?) { networkOverride = network }

    private func networkChanged() async {
        guard isWaitingForWiFi, Self.downloadsAllowed(wifiOnly: wifiOnly, network: network) else { return }
        await syncPins()
    }

    /// Stops a running download pass and waits until it has stopped (account switch, removal).
    public func shutdown() async {
        isShutDown = true
        pathMonitor.cancel()
        running?.cancel()
        await running?.value
    }

    var database: AccountDatabase { services.database }

    public struct Pin: Sendable, Hashable, Identifiable {
        public var id: String
        public var title: String
        public var fileCount: Int
        public var bytes: Int64
    }

    public static func pinId(album: Album) -> String { "album:\(album.id)" }

    public func pin(album: Album) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO offlinePin(id, title, createdAt) VALUES (?, ?, ?)",
                arguments: [Self.pinId(album: album), album.title, Date().timeIntervalSince1970])
        }
        await syncPins()
    }

    public func unpin(album: Album) async throws {
        // Only the files of this album are candidates, and only when the content of every album that stays pinned is
        // known: a file is never deleted because rows are missing locally. What is left over goes with the next
        // `syncPins()` that has checked every pinned album with the server.
        let (files, othersKnown): (Set<FileID>, Bool) = try await database.writer.write { db in
            let files = Set(try FileID.fetchAll(db, sql: "SELECT fileId FROM albumItem WHERE albumId = ?", arguments: [album.id]))
            try db.execute(sql: "DELETE FROM offlinePin WHERE id = ?", arguments: [Self.pinId(album: album)])
            let unknown =
                try Int.fetchOne(
                    db,
                    sql: """
                        SELECT count(*) FROM offlinePin LEFT JOIN album ON 'album:' || album.id = offlinePin.id
                        WHERE album.contentFetchedAt IS NULL
                        """) ?? 0
            return (files, unknown == 0)
        }
        if othersKnown { try await removeUnpinnedFiles(among: files) }
    }

    public func isPinned(_ id: String) -> Bool {
        (try? database.writer.read { db in try Bool.fetchOne(db, sql: "SELECT 1 FROM offlinePin WHERE id = ?", arguments: [id]) }) ?? false
    }

    public func pins() throws -> [Pin] {
        try database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT id, title FROM offlinePin ORDER BY createdAt").map { row in
                let id: String = row["id"]
                let albumId = id.hasPrefix("album:") ? String(id.dropFirst(6)) : ""
                let stats = try Row.fetchOne(
                    db,
                    sql:
                        "SELECT count(*) AS n, coalesce(sum(offlineFile.bytes), 0) AS b FROM albumItem JOIN offlineFile ON offlineFile.fileId = albumItem.fileId WHERE albumItem.albumId = ?",
                    arguments: [albumId])
                return Pin(id: id, title: row["title"], fileCount: stats?["n"] ?? 0, bytes: stats?["b"] ?? 0)
            }
        }
    }

    /// Local original of a file when it is available offline.
    public nonisolated func localFile(fileId: FileID, etag: String) -> URL? {
        guard
            let row = try? services.database.writer.read({ db in
                try Row.fetchOne(db, sql: "SELECT localPath, etag FROM offlineFile WHERE fileId = ?", arguments: [fileId])
            }),
            (row["etag"] as String) == etag
        else { return nil }
        let url = url(forStored: row["localPath"])
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    /// Downloads missing files of every pinned album and removes files no pinned album contains any more.
    /// Downloads honour the "Wi-Fi only" setting; a call while a pass is running makes it run once more.
    public func syncPins() async {
        guard !isShutDown else { return }
        if let running {
            needsAnotherPass = true
            await running.value
            return
        }
        let task = Task {
            repeat {
                self.needsAnotherPass = false
                await self.performSync()
            } while self.needsAnotherPass && !Task.isCancelled
        }
        running = task
        await task.value
        running = nil
    }

    private func performSync() async {
        isWaitingForWiFi = false
        do {
            let albumIds: [String] = try await database.writer.read { db in
                try String.fetchAll(db, sql: "SELECT substr(id, 7) FROM offlinePin WHERE id LIKE 'album:%'")
            }
            // Whether this pass knows from the server what every pinned album contains. Only then may files be removed:
            // album rows that are merely missing locally (index rebuilt, album list not loaded, server not reachable)
            // must never cost the downloaded originals.
            var verified = true
            var albumListRefreshed = false
            for albumId in albumIds {
                var known = try services.collections.album(id: albumId)
                if known == nil {
                    // Not in the local list. Deleted on the server, or just not known here? The server's list decides.
                    if !albumListRefreshed { albumListRefreshed = (try? await services.sync.refreshAlbums()) != nil }
                    guard albumListRefreshed else {
                        verified = false
                        continue
                    }
                    known = try services.collections.album(id: albumId)
                }
                guard let album = known else { continue }  // the server has no such album any more
                do {
                    try await services.sync.refreshAlbumContent(album)
                } catch {
                    if Task.isCancelled { throw error }
                    verified = false
                }
                let items = try services.collections.albumItems(albumId: albumId)
                let map = try services.library.items(items.map(\.fileId))
                for info in items {
                    guard let item = map[info.fileId], localFile(fileId: item.fileId, etag: item.etag) == nil else { continue }
                    try Task.checkCancellation()
                    guard Self.downloadsAllowed(wifiOnly: wifiOnly, network: network) else {
                        isWaitingForWiFi = true
                        break
                    }
                    let path = info.ownerPath ?? item.path
                    let url =
                        item.isOwnStorage || info.ownerPath != nil
                        ? services.connection.filesURL(path) : services.api.albumURL(album).appending(path: info.childName)
                    do {
                        let (file, _) = try await services.dav.download(url)
                        let name = "\(item.fileId)-\(CacheFileName.etag(item.etag)).\((item.name as NSString).pathExtension)"
                        let target = directory.appending(path: name)
                        try? FileManager.default.removeItem(at: target)
                        try FileManager.default.moveItem(at: file, to: target)
                        let size = Int64((try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                        try await database.writer.write { db in
                            try db.execute(
                                sql:
                                    "INSERT OR REPLACE INTO offlineFile(fileId, etag, localPath, bytes, downloadedAt) VALUES (?, ?, ?, ?, ?)",
                                arguments: [item.fileId, item.etag, name, size, Date().timeIntervalSince1970])
                        }
                    } catch {
                        logger.error("offline download failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
            if verified { try await removeUnpinnedFiles() }
        } catch {
            logger.error("offline sync failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Deletes offline files that no pinned album contains any more, going by the album content stored locally.
    ///
    /// Callers make sure that content is what the server has (see `performSync` and `unpin`).
    /// - Parameter candidates: only these files are considered (all when nil).
    func removeUnpinnedFiles(among candidates: Set<FileID>? = nil) async throws {
        let stale: [(Int64, String)] = try await database.writer.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT fileId, localPath FROM offlineFile WHERE fileId NOT IN (
                      SELECT albumItem.fileId FROM albumItem JOIN offlinePin ON offlinePin.id = 'album:' || albumItem.albumId)
                    """
            ).map { ($0["fileId"] as Int64, $0["localPath"] as String) }.filter { candidates?.contains($0.0) ?? true }
        }
        for (_, path) in stale { try? FileManager.default.removeItem(at: url(forStored: path)) }
        let ids = stale.map(\.0)
        guard !ids.isEmpty else { return }
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM offlineFile WHERE fileId IN (\(ids.map(String.init).joined(separator: ",")))")
        }
    }

    public func removeAll() async throws {
        try await database.writer.write { db in try db.execute(sql: "DELETE FROM offlinePin; DELETE FROM offlineFile") }
        try? FileManager.default.removeItem(at: directory)
        Self.prepare(directory)
    }
}
