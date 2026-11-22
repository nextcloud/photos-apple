// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import Testing

@testable import PhotosModel
@testable import PhotosNetworking
@testable import PhotosStore

/// Runs only when PHOTOS_IT_SERVER, PHOTOS_IT_USER and PHOTOS_IT_PASSWORD are set (an app password or, on test servers, the password).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PHOTOS_IT_SERVER"] != nil))
struct IntegrationTests {
    let connection: ServerConnection
    let http = HTTPClient(trustStore: TrustStore(directory: nil))

    init() {
        let env = ProcessInfo.processInfo.environment
        let user = env["PHOTOS_IT_USER"] ?? "admin"
        connection = ServerConnection(
            serverURL: URL(string: env["PHOTOS_IT_SERVER"] ?? "")!, userId: user, loginName: user,
            appPassword: env["PHOTOS_IT_PASSWORD"] ?? "",
            userAgent: "Mozilla/5.0 (macOS) Nextcloud-Photos/tests")
    }

    var api: PhotosAPI {
        PhotosAPI(dav: DAVClient(http: http, connection: connection), ocs: OCSClient(http: http, connection: connection))
    }

    @Test func detectsFeaturesAndSyncsLibrary() async throws {
        let features = try await FeatureDetector(dav: api.dav, ocs: api.ocs).detect()
        print("features:", features.enabled.sorted().map(\.rawValue), "source folders:", features.userConfig.photosSourceFolders)
        #expect(features.has(.photosDAV))
        #expect(features.serverVersion.major >= 33)

        let database = try AccountDatabase.temporary()
        let engine = SyncEngine(api: api, database: database, features: features)
        let started = Date()
        await engine.sync()
        let library = LibraryStore(database: database)
        let count = try library.count()
        print("indexed \(count) items in \(Date().timeIntervalSince(started)) s")
        #expect(count > 0)
        let visible = try library.gridItems(.all)
        #expect(!visible.isEmpty)
        #expect(visible.map(\.timestamp) == visible.map(\.timestamp).sorted(by: >))

        // A second sync with no changes is cheap and keeps the count.
        await engine.sync()
        #expect(try library.count() == count)

        try await engine.refreshAlbums()
        let albums = try CollectionStore(database: database).albums(.own)
        print("albums:", albums.map { "\($0.title) (\($0.itemCount))" })
        if let album = albums.first(where: { $0.itemCount > 0 }) {
            print("album content:", album.name)
            try await engine.refreshAlbumContent(album)
            #expect(try CollectionStore(database: database).albumItems(albumId: album.id).count == album.itemCount)
        }
        print("places")
        try await engine.refreshPlaces()
        print("places:", try await database.writer.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM place") } ?? 0)

        // A preview of the newest item.
        if let first = visible.first(where: { $0.kind == .image && $0.blurhash != nil }) {
            print("preview", first.fileId, first.mimeType)
            let data = try await api.preview(fileId: first.fileId, size: 256)
            #expect(data.count > 100)
        }
    }
}
