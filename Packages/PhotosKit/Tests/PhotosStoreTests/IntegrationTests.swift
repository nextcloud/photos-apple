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

/// Album, link and upload round trip. Creates and deletes its own test album and file.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PHOTOS_IT_SERVER"] != nil))
struct IntegrationWriteTests {
    let base = IntegrationTests()

    @Test func albumLinkAndUploadRoundTrip() async throws {
        let api = base.api
        let name = "Photos iOS test \(Int(Date().timeIntervalSince1970))"
        try await api.createAlbum(name: name, location: "Testville")
        var album = Album(kind: .own, name: name)
        do {
            // Add the newest own photo.
            let features = try await FeatureDetector(dav: api.dav, ocs: api.ocs).detect()
            let page = try await api.indexPage(
                sourceFolders: features.userConfig.photosSourceFolders, mimeTypes: MimeTypes.defaultImages, properties: DAVProp.mediaIndex,
                before: nil, limit: 5)
            let photo = try #require(page.items.first { $0.isOwnStorage && $0.blurhash != nil })
            try await api.addToAlbum(album, userPath: photo.path)
            try await api.addToAlbum(album, userPath: photo.path)  // 409 counts as success
            let children = try await api.albumContent(album)
            #expect(children.map(\.item.fileId) == [photo.fileId])

            // Public link and anonymous access.
            album = try #require(
                try await api.setCollaborators([Collaborator(id: "", label: "Public link", type: .publicLink)], of: album, extended: false))
            let token = try #require(album.publicLink?.id)
            #expect(token.count == 32)
            let link = api.publicAlbumLink(token: token)
            let parsed = try #require(PublicAlbumAPI.parse(link: link.absoluteString))
            let publicAPI = PublicAlbumAPI(http: base.http, serverURL: parsed.serverURL, token: parsed.token, userAgent: "tests")
            #expect(try await publicAPI.album().title == name)
            #expect(try await publicAPI.content().count == 1)
            #expect(try await publicAPI.preview(fileId: photo.fileId, size: 256).count > 100)

            // Upload (chunked, with a tiny chunk size) into a test folder, then delete it.
            let file = FileManager.default.temporaryDirectory.appending(path: "photos-ios-test.jpg")
            let (original, _) = try await api.dav.download(api.connection.filesURL(photo.path))
            try? FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: original, to: file)
            var uploader = Uploader(dav: api.dav)
            uploader.chunkThreshold = 100_000
            uploader.chunkSize = 100_000
            let uploaded = try await uploader.upload(
                file: file, fileName: "photos-ios-test.jpg", folder: "/Photos iOS test upload",
                capturedAt: Date(timeIntervalSince1970: 1_700_000_000))
            #expect(uploaded.fileId > 0)
            let second = try await uploader.upload(
                file: file, fileName: "photos-ios-test.jpg", folder: "/Photos iOS test upload", capturedAt: nil)
            #expect(second.path.hasSuffix("photos-ios-test (2).jpg"))
            try await api.dav.delete(api.connection.filesURL("/Photos iOS test upload"))
        } catch {
            try? await api.deleteAlbum(album)
            throw error
        }
        try await api.deleteAlbum(album)
        #expect(try await api.listAlbums(.own, extended: false).contains { $0.name == name } == false)
    }
}

/// Read-only checks of M4/M5 endpoints.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PHOTOS_IT_SERVER"] != nil))
struct IntegrationReadTests {
    let base = IntegrationTests()

    @Test func trashTagsAndFolders() async throws {
        let api = base.api
        _ = try await api.trash(mimeTypes: MimeTypes.defaultImages + MimeTypes.defaultVideos)
        let tags = try await api.tagsInUse()
        if let tag = tags.first { _ = try await api.tagContent(tag.id) }
        let root = try await api.folder("/", mimeTypes: MimeTypes.defaultImages, nomedia: [])
        #expect(root.folders.contains { $0.name == "Photos" })
        _ = try await api.sharedWithYou()
    }
}
