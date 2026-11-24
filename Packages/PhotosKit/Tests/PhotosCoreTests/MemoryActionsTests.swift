// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosCore
@testable import PhotosDomain
@testable import PhotosModel
@testable import PhotosNetworking
@testable import PhotosStore

/// "Save as album" of a memory (SPEC ME-4), through the session against a stub server.
@MainActor
@Suite struct MemoryActionsTests {
    let sandbox = Sandbox()
    let server = StubServer()

    func makeSession() async throws -> (AppModel, SessionModel) {
        let account = makeAccount("alice", server: server.url.absoluteString)
        try sandbox.keychain.set("password", for: Keychain.passwordKey(account.id.rawValue))
        try AccountRegistry(accounts: [account], activeAccountID: account.id).save(to: sandbox.layout.accountsFile)
        let suite = "photos-core-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let app = AppModel(
            appVersion: "1.0", layout: sandbox.layout, keychain: sandbox.keychain, defaults: defaults,
            httpConfiguration: server.configuration)
        let session = try #require(app.session)
        await session.syncNow()
        return (app, session)
    }

    func item(_ id: FileID, mount: String = "") -> MediaItem {
        MediaItem(fileId: id, path: "/Photos/Trip/\(id).jpg", mimeType: "image/jpeg", etag: "e\(id)", mountType: mount)
    }

    @Test func savesTheOwnPhotosOfAMemoryAsANamedAlbum() async throws {
        defer { sandbox.remove() }
        let (app, session) = try await makeSession()
        let services = try #require(session.services)
        try services.library.upsert([item(1), item(2), item(3, mount: "shared")])
        // An album of that name exists already: the new one gets a number.
        try services.collections.upsertAlbum(Album(kind: .own, name: "Lisbon & Porto"))
        let album = "/remote.php/dav/photos/alice/albums/Lisbon & Porto (2)"
        server.set {
            $0.responses["MKCOL \(album)/"] = .init(status: 201, body: "")
            $0.responses["PROPPATCH \(album)/"] = .init(status: 207, body: "")
            $0.responses["COPY /remote.php/dav/files/alice/Photos/Trip/1.jpg"] = .init(status: 201, body: "")
            $0.responses["COPY /remote.php/dav/files/alice/Photos/Trip/2.jpg"] = .init(status: 201, body: "")
        }
        let memory = Memory(
            id: "trip-1", kind: .trip, title: "Lisbon & Porto", start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 86_400), cover: 1, items: [1, 2, 3])

        let result = try await session.saveAsAlbum(memory)
        #expect(result.album.name == "Lisbon & Porto (2)")
        #expect(result.added == 2 && result.skipped == 1)
        // The trip's places are the album's location.
        #expect(server.lines(containing: "/albums/").first == "MKCOL \(album)/")
        #expect(server.requests.contains { $0.method == "PROPPATCH" && $0.body.contains("Lisbon &amp; Porto") })
        // The photos go through the outbox: only the user's own, the shared folder's one is left out.
        #expect(await eventually { server.lines(containing: "/Photos/Trip/").count >= 2 })
        let copies = Set(server.lines(containing: "/Photos/Trip/"))
        #expect(copies == ["COPY /remote.php/dav/files/alice/Photos/Trip/1.jpg", "COPY /remote.php/dav/files/alice/Photos/Trip/2.jpg"])
        await app.session?.shutdown(closeDatabase: true)
    }

    @Test func aMemoryWithoutOwnPhotosIsNotSaved() async throws {
        defer { sandbox.remove() }
        let (app, session) = try await makeSession()
        let services = try #require(session.services)
        try services.library.upsert([item(3, mount: "shared")])
        let memory = Memory(
            id: "years-1", kind: .yearsAgo(1), title: "1 year ago", start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 0), cover: 3, items: [3])
        await #expect(throws: NetworkError.self) { try await session.saveAsAlbum(memory) }
        #expect(server.lines(containing: "/albums/").isEmpty)
        await app.session?.shutdown(closeDatabase: true)
    }
}
