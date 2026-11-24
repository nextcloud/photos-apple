// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosModel
@testable import PhotosNetworking
@testable import PhotosStore

/// Album titles in search (SPEC SR-3) against a real server: an own album, and an album another user shares with the
/// test user, whose photo is not in the test user's files. Creates its own folder, albums and a second user
/// (`r4-discover-…`) and removes them again. Runs only with PHOTOS_IT_SERVER (and PHOTOS_IT_USER / PHOTOS_IT_PASSWORD
/// of an admin, which may create users).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PHOTOS_IT_SERVER"] != nil), .timeLimit(.minutes(5)))
struct AlbumSearchIntegrationTests {
    let base = IntegrationTests()

    /// OCS user provisioning as the admin.
    func provisioning(_ method: String, _ path: String, form: [String: String] = [:]) async throws -> Int {
        var request = URLRequest(url: base.connection.serverURL.appending(path: "ocs/v2.php/cloud/users" + path))
        request.httpMethod = method
        let credentials = Data("\(base.connection.loginName):\(base.connection.appPassword)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        request.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        if !form.isEmpty {
            var components = URLComponents()
            components.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
            request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    @Test func ownAndSharedAlbumTitlesAreFound() async throws {
        let api = base.api
        let me = base.connection.userId
        let features = try await FeatureDetector(dav: api.dav, ocs: api.ocs).detect()
        let root = try #require(features.userConfig.photosSourceFolders.first)
        let stamp = Int(Date().timeIntervalSince1970)
        let folder = (root == "/" ? "" : root) + "/r4-discover-\(stamp)"
        let own = Album(kind: .own, name: "r4-discover Hawaii \(stamp)")
        let friend = "r4-discover-anna-\(stamp)"
        let friendPassword = "R4-discover-\(UUID().uuidString)"
        let friendConnection = ServerConnection(
            serverURL: base.connection.serverURL, userId: friend, loginName: friend, appPassword: friendPassword,
            userAgent: base.connection.userAgent)
        let friendAPI = PhotosAPI(
            dav: DAVClient(http: base.http, connection: friendConnection), ocs: OCSClient(http: base.http, connection: friendConnection))
        let sharedName = "r4-discover Family \(stamp)"
        func cleanUp() async {
            try? await api.deleteAlbum(own)
            try? await friendAPI.deleteAlbum(Album(kind: .own, name: sharedName))
            try? await api.dav.delete(api.connection.filesURL(folder))
            _ = try? await provisioning("DELETE", "/\(friend)")
            let trash = api.connection.davURL("trashbin/\(me)/trash/")
            let entries = (try? await api.dav.propfind(trash, depth: 1, properties: [DAVProp.trashbinOriginalLocation])) ?? []
            for entry in entries.dropFirst()
            where entry.string(DAVProp.trashbinOriginalLocation)?.contains("r4-discover-\(stamp)") == true {
                try? await api.dav.delete(trash.appending(path: entry.lastPathComponent))
            }
        }
        do {
            try await api.dav.mkcol(api.connection.filesURL(folder))
            for name in ["a.jpg", "b.jpg"] {
                _ = try await api.dav.put(api.connection.filesURL(folder + "/" + name), data: Data([0xFF, 0xD8, 0xFF, 0xD9]))
            }
            try await api.createAlbum(name: own.name)
            try await api.addToAlbum(own, userPath: folder + "/a.jpg")

            // Another user shares an album with one of their photos.
            #expect(try await provisioning("POST", "", form: ["userid": friend, "password": friendPassword]) == 200)
            _ = try await friendAPI.dav.put(friendAPI.connection.filesURL("/r4-discover-beach.jpg"), data: Data([0xFF, 0xD8, 0xFF, 0xD9]))
            try await friendAPI.createAlbum(name: sharedName)
            let sharedAlbum = Album(kind: .own, name: sharedName)
            try await friendAPI.addToAlbum(sharedAlbum, userPath: "/r4-discover-beach.jpg")
            _ = try await friendAPI.setCollaborators([Collaborator(id: me, label: me, type: .user)], of: sharedAlbum, extended: false)

            let database = try AccountDatabase.temporary()
            let engine = SyncEngine(api: api, database: database, features: features)
            let library = LibraryStore(database: database)
            let collections = CollectionStore(database: database)
            await engine.sync()
            let indexed = try await database.writer.read { db in
                try MediaItem.filter(sql: "path LIKE ?", arguments: [folder + "/%"]).order(sql: "path").fetchAll(db)
            }
            #expect(indexed.map(\.name) == ["a.jpg", "b.jpg"])
            try await engine.refreshAlbums()
            let ownStored = try #require(try collections.albums(.own).first { $0.name == own.name })
            try await engine.refreshAlbumContent(ownStored)
            let shared = try #require(try collections.albums(.shared).first { $0.title == sharedName })
            try await engine.refreshAlbumContent(shared)

            // The own album's title finds its photo (and only that one).
            let hawaii = try await library.search(LibrarySearch(texts: ["hawaii \(stamp)"])).map(\.fileId)
            #expect(hawaii == indexed.filter { $0.name == "a.jpg" }.map(\.fileId))
            // The shared album's title finds the other user's photo, which is only known as the album's child.
            let family = try await library.search(LibrarySearch(texts: ["family \(stamp)"]))
            #expect(family.count == 1)
            let found = try #require(try await library.fetchItems(family.map(\.fileId)).values.first)
            #expect(found.isCollectionChild && found.name.contains("beach"))
            #expect(try await library.search(LibrarySearch(albumIds: [shared.id])).map(\.fileId) == family.map(\.fileId))
            print("album search: own \(hawaii), shared \(family.map(\.fileId))")
        } catch {
            await cleanUp()
            throw error
        }
        await cleanUp()
    }
}
