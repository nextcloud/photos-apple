// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import Testing

@testable import PhotosCore
@testable import PhotosModel
@testable import PhotosNetworking
@testable import PhotosStore

func multistatus(_ responses: String) -> String {
    "<?xml version=\"1.0\"?><d:multistatus xmlns:d=\"DAV:\" xmlns:oc=\"http://owncloud.org/ns\" xmlns:nc=\"http://nextcloud.org/ns\">\(responses)</d:multistatus>"
}

/// Offline originals are only removed when the server said their album no longer contains them.
@Suite struct OfflineRemovalTests {
    let sandbox = Sandbox()
    let server = StubServer()
    let albumPath = "/remote.php/dav/photos/alice/albums/Holiday/"

    func makeServices() throws -> AccountServices {
        try AccountServices(
            account: makeAccount("alice", server: server.url.absoluteString), appPassword: "password", http: server.http(),
            features: ServerFeatures(serverVersion: ServerVersion(major: 33)), userAgent: "tests", layout: sandbox.layout,
            onUnauthorized: {})
    }

    /// A pinned album with one photo, downloaded.
    func downloadedAlbum(in services: AccountServices, etag: String = "abc") async throws -> (OfflineManager, Album, MediaItem) {
        let album = Album(kind: .own, name: "Holiday")
        let item = MediaItem(fileId: 11, path: "/Photos/beach.jpg", mimeType: "image/jpeg", etag: etag)
        try services.collections.upsertAlbum(album)
        try services.library.upsert([item])
        try await services.database.writer.write { db in
            try db.execute(
                sql:
                    "INSERT INTO albumItem(albumId, fileId, childName, origin, ownerPath, position) VALUES (?, 11, '11-beach.jpg', 'user', ?, 1)",
                arguments: [album.id, item.path])
            try db.execute(
                sql: "INSERT INTO offlinePin(id, title, createdAt) VALUES (?, 'Holiday', 0)",
                arguments: [OfflineManager.pinId(album: album)])
        }
        server.set { $0.downloads["/remote.php/dav/files/alice/Photos/beach.jpg"] = Data("original".utf8) }
        let offline = OfflineManager(services: services, wifiOnly: { false })
        await offline.setNetwork(NetworkConditions())
        await offline.syncPins()
        #expect(offline.localFile(fileId: item.fileId, etag: item.etag) != nil)
        return (offline, album, item)
    }

    /// The album as the server lists it: only the collection itself, no photos.
    func serverSaysAlbumIsEmpty() {
        let body = multistatus(
            "<d:response><d:href>\(albumPath)</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
        )
        let path = albumPath
        server.set {
            $0.responses["PROPFIND \(path)"] = StubServer.Stub(status: 207, body: body)
            $0.responses["PROPFIND \(String(path.dropLast()))"] = StubServer.Stub(status: 207, body: body)
        }
    }

    /// The index was rebuilt, the album list is not loaded, the server is not reachable: the rows are missing here,
    /// which says nothing about the album.
    @Test(arguments: ["DELETE FROM album", "DELETE FROM albumItem", "DELETE FROM media; DELETE FROM albumItem; DELETE FROM album"])
    func missingLocalRowsDoNotRemoveOfflineFiles(sql: String) async throws {
        defer { sandbox.remove() }
        let services = try makeServices()
        let (offline, _, item) = try await downloadedAlbum(in: services)
        let file = try #require(offline.localFile(fileId: item.fileId, etag: item.etag))

        try await services.database.writer.write { db in try db.execute(sql: sql) }
        await offline.syncPins()

        #expect(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
        #expect(offline.localFile(fileId: item.fileId, etag: item.etag) != nil)
        await offline.shutdown()
        await services.shutdown(closeDatabase: true)
    }

    /// A change of the timeline folders rebuilds the index; the offline album and its files stay.
    @Test func sourceFolderChangeKeepsOfflineFiles() async throws {
        defer { sandbox.remove() }
        let services = try makeServices()
        let (offline, album, item) = try await downloadedAlbum(in: services)
        try services.database.setSyncValue("sourceFolders", "/Photos|/.archive")

        var changed = ServerFeatures(serverVersion: ServerVersion(major: 33))
        changed.userConfig.photosSourceFolders = ["/Pictures"]
        await services.sync.updateFeatures(changed)
        await services.sync.sync()
        #expect(try services.library.item(item.fileId) == nil)  // the index was rebuilt
        await offline.syncPins()

        #expect(try services.collections.album(id: album.id) != nil)
        #expect(offline.localFile(fileId: item.fileId, etag: item.etag) != nil)
        #expect(try await offline.pins().first?.fileCount == 1)
        await offline.shutdown()
        await services.shutdown(closeDatabase: true)
    }

    /// The photo was removed from the album on the server: its offline copy goes.
    @Test func photoRemovedFromTheAlbumOnTheServerIsRemoved() async throws {
        defer { sandbox.remove() }
        let services = try makeServices()
        let (offline, _, item) = try await downloadedAlbum(in: services)
        let file = try #require(offline.localFile(fileId: item.fileId, etag: item.etag))

        serverSaysAlbumIsEmpty()
        await offline.syncPins()

        #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
        #expect(offline.localFile(fileId: item.fileId, etag: item.etag) == nil)
        await offline.shutdown()
        await services.shutdown(closeDatabase: true)
    }

    @Test func unpinRemovesTheAlbumsFiles() async throws {
        defer { sandbox.remove() }
        let services = try makeServices()
        let (offline, album, item) = try await downloadedAlbum(in: services)
        let file = try #require(offline.localFile(fileId: item.fileId, etag: item.etag))
        try await offline.unpin(album: album)
        #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
        await offline.shutdown()
        await services.shutdown(closeDatabase: true)
    }

    /// An ETag is server input; it must not choose where the file goes.
    @Test func hostileETagStaysInsideTheOfflineFolder() async throws {
        defer { sandbox.remove() }
        let services = try makeServices()
        let (offline, _, item) = try await downloadedAlbum(in: services, etag: "../../../evil/1")
        let file = try #require(offline.localFile(fileId: item.fileId, etag: item.etag))
        #expect(file.deletingLastPathComponent().lastPathComponent == "Offline")
        #expect(!file.lastPathComponent.contains(".."))
        #expect(!sandbox.files().contains { $0.contains("evil") })
        await offline.shutdown()
        await services.shutdown(closeDatabase: true)
    }
}

/// Lists the server only stores as a whole are read again before they are written.
@MainActor
@Suite struct WholeListWriteTests {
    let sandbox = Sandbox()
    let server = StubServer()

    func smartAlbum(_ id: String) -> SmartAlbum { SmartAlbum(id: id, name: id.uppercased(), filters: AlbumFilters(places: [id])) }

    func serverHas(_ albums: [SmartAlbum]) throws {
        let list = String(decoding: try JSONEncoder().encode(albums), as: UTF8.self)
        let data = String(decoding: try JSONEncoder().encode(["smartAlbums": list]), as: UTF8.self)
        server.set {
            $0.responses["GET /ocs/v2.php/apps/photos/api/v1/config"] = StubServer.Stub(
                status: 200, body: String(decoding: StubServer.ocs(data), as: UTF8.self))
            $0.responses["PUT /index.php/apps/photos/api/v1/config/smartAlbums"] = StubServer.Stub(status: 200, body: "{}")
        }
    }

    /// The smart album ids of the last list the app wrote.
    func lastWrite() throws -> [String] {
        struct Body: Decodable { var value: String }
        let request = try #require(server.requests.last { $0.line == "PUT /index.php/apps/photos/api/v1/config/smartAlbums" })
        let body = try JSONDecoder().decode(Body.self, from: Data(request.body.utf8))
        return try JSONDecoder().decode([SmartAlbum].self, from: Data(body.value.utf8)).map(\.id)
    }

    @Test func smartAlbumsSavedElsewhereSurviveSaveAndDelete() async throws {
        defer { sandbox.remove() }
        let suite = "photos-core-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let app = AppModel(
            appVersion: "1.0", layout: sandbox.layout, keychain: sandbox.keychain, defaults: defaults,
            httpConfiguration: server.configuration)
        try await app.addAccount(
            LoginService.Credentials(serverURL: server.url, loginName: "alice", appPassword: "app-password"), askForNotifications: false)
        let session = try #require(app.session)
        #expect(await eventually { session.runningTaskCount == 0 })

        // What this device knows (an hour old) and what the server has by now.
        session.features.enabled.insert(.configAPI)
        session.features.userConfig.smartAlbums = [smartAlbum("a")]
        try serverHas([smartAlbum("a"), smartAlbum("b")])

        await session.saveSmartAlbum(smartAlbum("c"))
        #expect(try lastWrite() == ["a", "b", "c"])
        #expect(session.smartAlbums().map(\.0.id) == ["a", "b", "c"])

        // Saving an album that exists replaces it.
        var renamed = smartAlbum("b")
        renamed.name = "Renamed"
        try serverHas([smartAlbum("a"), smartAlbum("b"), smartAlbum("c")])
        await session.saveSmartAlbum(renamed)
        #expect(try lastWrite() == ["a", "b", "c"])
        #expect(session.features.userConfig.smartAlbums?.first { $0.id == "b" }?.name == "Renamed")

        try serverHas([smartAlbum("a"), smartAlbum("b"), smartAlbum("c"), smartAlbum("d")])
        await session.deleteSmartAlbum(smartAlbum("a"))
        #expect(try lastWrite() == ["b", "c", "d"])
        await session.shutdown(closeDatabase: true)
    }

    @Test func collaboratorsAddedElsewhereSurvive() async throws {
        defer { sandbox.remove() }
        let services = try AccountServices(
            account: makeAccount("alice", server: server.url.absoluteString), appPassword: "password", http: server.http(),
            features: ServerFeatures(serverVersion: ServerVersion(major: 33)), userAgent: "tests", layout: sandbox.layout,
            onUnauthorized: {})
        func entry(_ id: String, type: Int = 0) -> String {
            "<nc:collaborator><id>\(id)</id><label>\(id.capitalized)</label><type>\(type)</type></nc:collaborator>"
        }
        let path = "/remote.php/dav/photos/alice/albums/Trip/"
        let body = multistatus(
            "<d:response><d:href>\(path)</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype><nc:collaborators>\(entry("bob"))\(entry("carol"))</nc:collaborators></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
        )
        server.set {
            $0.responses["PROPFIND \(path)"] = StubServer.Stub(status: 207, body: body)
            $0.responses["PROPPATCH \(path)"] = StubServer.Stub(status: 200, body: "")
        }
        let bob = Collaborator(id: "bob", label: "Bob", type: .user)
        let dave = Collaborator(id: "dave", label: "Dave", type: .user)
        // The sheet was opened when only Bob was a collaborator; Carol was added on another device since.
        let album = Album(kind: .own, name: "Trip", collaborators: [bob])

        _ = try await services.api.setCollaborators([bob, dave], of: album, extended: false)
        var written = try #require(server.requests.last { $0.method == "PROPPATCH" }).body
        #expect(written.contains("bob") && written.contains("carol") && written.contains("dave"))

        // Removing Bob removes Bob, not Carol.
        _ = try await services.api.setCollaborators([], of: album, extended: false)
        written = try #require(server.requests.last { $0.method == "PROPPATCH" }).body
        #expect(!written.contains("bob") && written.contains("carol"))
        await services.shutdown(closeDatabase: true)
    }

    @Test func collaboratorMerge() {
        let bob = Collaborator(id: "bob", label: "Bob", type: .user)
        let carol = Collaborator(id: "carol", label: "Carol", type: .user)
        let team = Collaborator(id: "bob", label: "Team Bob", type: .group)  // same id, other type
        let newLink = Collaborator(id: "", label: "Link", type: .publicLink)
        let link = Collaborator(id: String(repeating: "a", count: 32), label: "Link", type: .publicLink)
        typealias API = PhotosAPI
        // Nothing changed elsewhere: the result is what the user asked for.
        #expect(API.mergeCollaborators(base: [bob], desired: [bob, carol], current: [bob]) == [bob, carol])
        #expect(API.mergeCollaborators(base: [bob, carol], desired: [carol], current: [bob, carol]) == [carol])
        // Added elsewhere stays; removed elsewhere stays removed; added on both sides is not doubled.
        #expect(API.mergeCollaborators(base: [bob], desired: [bob, team], current: [bob, carol]) == [bob, carol, team])
        #expect(API.mergeCollaborators(base: [bob, carol], desired: [bob, carol, team], current: [bob]) == [bob, team])
        #expect(API.mergeCollaborators(base: [], desired: [carol], current: [carol]) == [carol])
        // One public link per album: adding one where the server already has one keeps the server's token.
        #expect(API.mergeCollaborators(base: [], desired: [newLink], current: []) == [newLink])
        #expect(API.mergeCollaborators(base: [], desired: [newLink], current: [link]) == [link])
        #expect(API.mergeCollaborators(base: [link], desired: [], current: [link, bob]) == [bob])
    }
}
