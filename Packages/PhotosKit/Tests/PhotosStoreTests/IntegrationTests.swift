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

/// Changes made elsewhere reach the local index. Creates and deletes its own folder and file.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PHOTOS_IT_SERVER"] != nil))
struct IntegrationSyncTests {
    let base = IntegrationTests()

    @Test func favouriteMoveAndDeleteMadeElsewhereArrive() async throws {
        let api = base.api
        let features = try await FeatureDetector(dav: api.dav, ocs: api.ocs).detect()
        let root = try #require(features.userConfig.photosSourceFolders.first)
        let folder = (root == "/" ? "" : root) + "/photos-ios-sync-test-\(Int(Date().timeIntervalSince1970))"
        let path = folder + "/a.jpg"
        try await api.dav.mkcol(api.connection.filesURL(folder))
        do {
            // The MIME type comes from the extension; the content does not matter for the index.
            _ = try await api.dav.put(api.connection.filesURL(path), data: Data([0xFF, 0xD8, 0xFF, 0xD9]))
            let database = try AccountDatabase.temporary()
            // Moves and deletes only show up in a reconciliation, which the app runs at most every 10 minutes unless
            // asked to; here every sync may reconcile.
            let engine = SyncEngine(api: api, database: database, features: features, reconcileInterval: 0)
            let library = LibraryStore(database: database)
            await engine.sync()
            let fileId = try #require(
                try await database.writer.read { db in
                    try FileID.fetchOne(db, sql: "SELECT fileId FROM media WHERE path = ?", arguments: [path])
                })
            #expect(try library.item(fileId)?.isFavorite == false)

            // A favourite set by another client changes neither the file's nor the root's ETag.
            let rootBefore = try await api.folderETag(root)
            let fileBefore = try await api.folderETag(path)
            try await api.setFavorite(userPath: path, true)
            let rootAfter = try await api.folderETag(root)
            let fileAfter = try await api.folderETag(path)
            print("favourite: root etag \(rootBefore ?? "-") -> \(rootAfter ?? "-"), file etag \(fileBefore ?? "-") -> \(fileAfter ?? "-")")
            #expect(fileBefore == fileAfter)
            await engine.sync()
            #expect(try library.item(fileId)?.isFavorite == true)
            try await api.setFavorite(userPath: path, false)
            await engine.sync()
            #expect(try library.item(fileId)?.isFavorite == false)

            // Moved by another client: same file id, new path.
            let moved = folder + "/b.jpg"
            try await api.move(userPath: path, to: moved)
            await engine.sync()
            #expect(try library.item(fileId)?.path == moved)

            // Deleted by another client.
            try await api.delete(userPath: moved)
            await engine.sync()
            #expect(try library.item(fileId) == nil)
        } catch {
            try? await api.dav.delete(api.connection.filesURL(folder))
            throw error
        }
        try await api.dav.delete(api.connection.filesURL(folder))
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

/// Detection matches what the server really offers, on stock and on extended servers alike: every feature found works,
/// and the API of every feature not found is really absent. Read-only except for its own test file.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PHOTOS_IT_SERVER"] != nil))
struct IntegrationFeatureTests {
    let base = IntegrationTests()

    @Test func detectionMatchesTheServer() async throws {
        let api = base.api
        let features = try await FeatureDetector(dav: api.dav, ocs: api.ocs).detect()
        print(
            "server \(features.fingerprint ?? "-"): \(features.hasExtendedFeatures ? "extended" : "standard") Photos,",
            features.enabled.filter { $0.origin != .core }.map(\.rawValue).sorted())

        // Timeline day counts.
        if features.has(.timelineDays) {
            #expect(try await !api.timelineDays().isEmpty)
        } else {
            await #expect(throws: NetworkError.notFound) { try await api.timelineDays() }
        }

        // Album properties: present when detected, a 404 propstat (not an error) when not.
        let albums = try await api.dav.propfind(
            api.albumsHomeURL(.own), depth: 1, properties: DAVProp.album + DAVProp.albumExtended)
        if let album = albums.dropFirst().first {
            #expect((album.properties[DAVProp.cover] != nil) == features.has(.albumCover))
            #expect((album.properties[DAVProp.albumDescription] != nil) == features.has(.albumDescription))
            #expect((album.properties[DAVProp.albumId] != nil) == features.has(.albumComments))
            if !features.has(.albumCover) { #expect(album.missing.contains(DAVProp.cover)) }
            if features.has(.albumComments), let id = album.int(DAVProp.albumId) {
                _ = try await api.comments(albumId: id)
            }
        }

        // Places by country.
        let places = try await api.listPlaces(withCountry: true)
        if !features.has(.placeCountry) { #expect(places.allSatisfy { $0.countryCode == nil }) }

        // Companion APIs are only called when announced; on a server without them they are absent.
        if !features.has(.recognizeKeyAPI) {
            await #expect(throws: NetworkError.notFound) {
                let _: JSONValue = try await api.ocs.request("GET", "ocs/v2.php/apps/photos/api/v1/recognize/key")
            }
        }
        // Extended config keys are refused by a server without them (no value is changed: the key is unknown there).
        if !features.has(.configAPI) && !features.has(.onThisDayNotifications) {
            await #expect(throws: (any Error).self) { try await api.setUserConfig(.onThisDayNotifications, value: "true") }
        }
    }

    /// Capture time and location editing (`MetadataPropPatchPlugin`, Nextcloud ≥ 35) on a file of the test's own.
    @Test func metadataEditRoundTrip() async throws {
        let api = base.api
        let features = try await FeatureDetector(dav: api.dav, ocs: api.ocs).detect()
        guard features.has(.metadataEdit) else {
            print("skipped: the server cannot edit capture time and location")
            return
        }
        let page = try await api.indexPage(
            sourceFolders: features.userConfig.photosSourceFolders, mimeTypes: ["image/jpeg"], properties: DAVProp.mediaIndex,
            before: nil, limit: 5)
        let photo = try #require(page.items.first { $0.isOwnStorage })
        let folder = "/Photos iOS metadata test \(Int(Date().timeIntervalSince1970))"
        let path = folder + "/edit.jpg"
        try await api.dav.mkcol(api.connection.filesURL(folder))
        do {
            let (original, _) = try await api.dav.download(api.connection.filesURL(photo.path))
            defer { try? FileManager.default.removeItem(at: original) }
            _ = try await api.dav.put(api.connection.filesURL(path), data: try Data(contentsOf: original))
            let captured = Date(timeIntervalSince1970: 1_600_000_000)
            try await api.setMetadata(userPath: path, capturedAt: captured, latitude: 48.137, longitude: 11.575)
            let fileId = try #require(
                try await api.dav.propfind(api.connection.filesURL(path), depth: 0, properties: [DAVProp.fileId]).first?.int64(
                    DAVProp.fileId))
            let item = try #require(try await api.items(fileIds: [fileId], properties: DAVProp.mediaIndex).first)
            #expect(item.capturedAt == captured)
            #expect(abs((item.latitude ?? 0) - 48.137) < 0.001 && abs((item.longitude ?? 0) - 11.575) < 0.001)
        } catch {
            try? await api.dav.delete(api.connection.filesURL(folder))
            throw error
        }
        try await api.dav.delete(api.connection.filesURL(folder))
    }
}
