// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
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

    public init(
        account: Account,
        appPassword: String,
        http: HTTPClient,
        features: ServerFeatures,
        userAgent: String,
        onUnauthorized: @escaping @Sendable () -> Void
    ) throws {
        self.account = account
        self.http = http
        let connection = ServerConnection(
            serverURL: account.serverURL, userId: account.userId, loginName: account.loginName, appPassword: appPassword,
            userAgent: userAgent)
        self.connection = connection
        var dav = DAVClient(http: http, connection: connection, onUnauthorized: onUnauthorized)
        if let key = features.validRecognizeKey() { dav.extraHeaders["X-Recognize-Api-Key"] = key }
        self.dav = dav
        self.ocs = OCSClient(http: http, connection: connection, onUnauthorized: onUnauthorized)
        self.api = PhotosAPI(dav: dav, ocs: ocs)
        self.database = try AccountDatabase(url: AppPaths.database(account.id))
        self.library = LibraryStore(database: database)
        self.collections = CollectionStore(database: database)
        self.sync = SyncEngine(api: api, database: database, features: features)
        self.outbox = Outbox(api: api, database: database)
        let cache = PreviewCache(directory: AppPaths.previews(account.id))
        let originals = OriginalStore(directory: AppPaths.originals(account.id), dav: dav)
        self.images = ImagePipeline(api: api, cache: cache, originals: originals)
    }

    /// DAV URL of a user file's original.
    public func originalURL(for item: MediaItem) -> URL { connection.filesURL(item.path) }

    public static func loadFeatures(_ id: AccountID) -> ServerFeatures? {
        guard let data = try? Data(contentsOf: AppPaths.featuresFile(id)) else { return nil }
        return try? JSONDecoder().decode(ServerFeatures.self, from: data)
    }

    public static func saveFeatures(_ features: ServerFeatures, for id: AccountID) {
        let url = AppPaths.featuresFile(id)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(features).write(to: url, options: .atomic)
    }

    /// Deletes every local trace of an account (database, caches, offline files).
    public static func deleteLocalData(_ id: AccountID) {
        for url in [AppPaths.accountDirectory(id), AppPaths.previews(id), AppPaths.originals(id)] {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
