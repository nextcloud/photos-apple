// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosBackup
import PhotosMedia
import PhotosModel
import PhotosNetworking
import PhotosStore

/// All services of one account. Created once per signed-in account; shared by the app and extensions.
public final class AccountServices: Sendable {
    public let account: Account
    public let connection: ServerConnection
    public let http: HTTPClient
    public let dav: DAVClient
    public let ocs: OCSClient
    public let api: PhotosAPI
    public let database: AccountDatabase
    public let library: LibraryStore
    public let collections: CollectionStore
    public let sync: SyncEngine
    public let outbox: Outbox
    public let images: ImagePipeline
    public let layout: StorageLayout

    public init(
        account: Account,
        appPassword: String,
        http: HTTPClient,
        features: ServerFeatures,
        userAgent: String,
        layout: StorageLayout = AppPaths.layout,
        onUnauthorized: @escaping @Sendable () -> Void
    ) throws {
        self.account = account
        self.http = http
        self.layout = layout
        let connection = ServerConnection(
            serverURL: account.serverURL, userId: account.userId, loginName: account.loginName, appPassword: appPassword,
            userAgent: userAgent)
        self.connection = connection
        var dav = DAVClient(http: http, connection: connection, onUnauthorized: onUnauthorized)
        if let key = features.validRecognizeKey() { dav.extraHeaders["X-Recognize-Api-Key"] = key }
        self.dav = dav
        self.ocs = OCSClient(http: http, connection: connection, onUnauthorized: onUnauthorized)
        self.api = PhotosAPI(dav: dav, ocs: ocs)
        self.database = try AccountDatabase(url: layout.database(account.id))
        self.library = LibraryStore(database: database)
        self.collections = CollectionStore(database: database)
        let sync = SyncEngine(api: api, database: database, features: features)
        self.sync = sync
        // Failed for good or discarded: the rows the operation had changed come back from the server.
        self.outbox = Outbox(api: api, database: database, restore: { _ = try? await sync.restoreRows() })
        let cache = PreviewCache(directory: layout.previews(account.id))
        let originals = OriginalStore(directory: layout.originals(account.id), dav: dav)
        let images = ImagePipeline(
            api: api, cache: cache, originals: originals, pinnedFileIds: { [database] in Self.pinnedFileIds(database) })
        self.images = images
        // Launch: bring the caches below their limits (SPEC §5.5) before this session adds to them.
        Task.detached(priority: .utility) { await images.trimCaches() }
        // Keep the query planner's statistics current (indexes added by a migration, a library grown by a large sync);
        // `0x10002` is what SQLite recommends at open: bounded work, and only for tables whose statistics are stale.
        Task.detached(priority: .utility) { [database] in
            try? await database.writer.write { try $0.execute(sql: "PRAGMA optimize=0x10002") }
        }
    }

    /// Files that are kept for offline use; their previews survive a trim of the preview cache.
    static func pinnedFileIds(_ database: AccountDatabase) -> Set<FileID> {
        (try? database.writer.read { db in try Set(FileID.fetchAll(db, sql: "SELECT fileId FROM offlineFile")) }) ?? []
    }

    /// The app went to the background: trim the caches while nothing is being looked at.
    public func didEnterBackground() {
        Task.detached(priority: .utility) { [images] in await images.trimCaches() }
    }

    /// DAV URL of an item's original: the user's file, or for a file of someone else's shared album, the album's child.
    public func originalURL(for item: MediaItem) -> URL { connection.originalURL(path: item.path) }

    /// Stops everything that runs for this account and waits until it has stopped: sync, the outbox worker and image loads.
    ///
    /// The services stay usable afterwards (a later `sync()` starts again) unless `closeDatabase` is set, which is what
    /// account removal does right before the files are deleted, so that nothing writes into a deleted database.
    public func shutdown(closeDatabase: Bool = false) async {
        await sync.shutdown()
        await outbox.shutdown()
        if closeDatabase {
            await images.shutdown()
            try? database.writer.close()
        }
    }

    public static func loadFeatures(_ id: AccountID, layout: StorageLayout = AppPaths.layout) -> ServerFeatures? {
        guard let data = try? Data(contentsOf: layout.featuresFile(id)) else { return nil }
        return try? JSONDecoder().decode(ServerFeatures.self, from: data)
    }

    public static func saveFeatures(_ features: ServerFeatures, for id: AccountID, layout: StorageLayout = AppPaths.layout) {
        let url = layout.featuresFile(id)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(features).write(to: url, options: .atomic)
    }
}

/// Removes every local trace of an account. The one place that knows what an account leaves behind; used by logout,
/// account removal and remote wipe (SPEC §5.1.6, §8).
///
/// Per account: the database (index, outbox, offline pins, backup ledger), cached features, offline originals, the preview and
/// original caches, the app password, the push key and the push registration. The backup options are removed when backup was
/// set up for this account. Per host, and therefore only removed when no remaining account uses the host: the server
/// certificate the user trusted and the client certificate with its password. Certificates of hosts that no account uses
/// at all (trusted in a login that was cancelled) go as well. What lives outside the container (notifications, widgets,
/// shared diagnostics reports) is cleared by `AppModel`.
///
/// Call it after everything that uses the account has been shut down (`AccountServices.shutdown(closeDatabase: true)`).
public struct AccountPurge: Sendable {
    public let layout: StorageLayout
    public let keychain: Keychain
    /// The live trust store of the app, so a removed certificate is also forgotten in memory.
    public let trustStore: TrustStore?

    public init(layout: StorageLayout = AppPaths.layout, keychain: Keychain, trustStore: TrustStore?) {
        self.layout = layout
        self.keychain = keychain
        self.trustStore = trustStore
    }

    /// - Parameter remaining: the accounts that stay on this device (the purged one may or may not be in the list).
    public func purge(_ account: Account, remaining: [Account]) {
        let id = account.id
        let manager = FileManager.default
        for url in [layout.accountDirectory(id), layout.previews(id), layout.originals(id)] {
            try? manager.removeItem(at: url)
        }
        for key in Keychain.accountKeys(id.rawValue) { keychain.delete(key) }

        if BackupSettings.load(from: layout.backupSettingsFile).accountId == id {
            try? manager.removeItem(at: layout.backupSettingsFile)
        }

        let others = remaining.filter { $0.id != id }
        defer { removeUnusedCertificates(remaining: others) }
        guard let host = Self.host(of: account) else { return }
        let hostStillUsed = others.contains { Self.host(of: $0) == host }
        if !hostStillUsed {
            keychain.delete(Keychain.clientCertificateKey(host))
            keychain.delete(Keychain.clientCertificatePasswordKey(host))
            removeTrust(for: host)
        }
    }

    /// Removes the trusted server certificates of hosts that none of these accounts uses.
    public func removeUnusedCertificates(remaining: [Account]) {
        let used = Set(remaining.compactMap(Self.host(of:)))
        let stored: Set<String>
        if let trustStore {
            stored = trustStore.trustedHosts
        } else {
            let files = (try? FileManager.default.contentsOfDirectory(at: layout.certificates, includingPropertiesForKeys: nil)) ?? []
            stored = Set(files.filter { $0.pathExtension == "der" }.map { $0.deletingPathExtension().lastPathComponent })
        }
        for host in stored.subtracting(used) { removeTrust(for: host) }
    }

    private func removeTrust(for host: String) {
        if let trustStore {
            trustStore.removeTrust(for: host)
        } else {
            try? FileManager.default.removeItem(at: layout.certificates.appending(path: "\(host).der"))
        }
    }

    /// The key under which certificates of an account's server are stored (lower-cased host, no port).
    static func host(of account: Account) -> String? { account.serverURL.host()?.lowercased() }
}
