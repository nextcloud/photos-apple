// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosModel
@testable import PhotosNetworking
@testable import PhotosStore

/// Partner sharing: a folder shared with the user is indexed with the timeline folders (SPEC SH-8).
// One at a time: run together in the CI simulator, every test of the suite ran into its time limit at once.
@Suite(.serialized, .timeLimit(.minutes(1))) struct PartnerTimelineTests {
    let server = FakeDAVServer()
    let database: AccountDatabase
    let library: LibraryStore
    let engine: SyncEngine
    let anna = PartnerFolder(path: "/Anna photos", ownerId: "anna", ownerDisplayName: "Anna")

    init() throws {
        database = try AccountDatabase.temporary()
        library = LibraryStore(database: database)
        engine = SyncEngine(
            api: server.api, database: database, features: ServerFeatures(serverVersion: ServerVersion(major: 36)), reconcileInterval: 0)
        server.state.withLock { _ = $0.folders.insert("/Anna photos") }
        server.put(
            file(1, "/Photos/a.jpg", time: 1000), file(2, "/Photos/b.jpg", time: 2000),
            file(10, "/Anna photos/x.jpg", time: 1500), file(11, "/Anna photos/2025/y.jpg", time: 2500),
            // Not in the timeline, not shared: never indexed.
            file(20, "/Documents/z.jpg", time: 3000))
    }

    func file(_ id: FileID, _ path: String, time: Double) -> FakeDAVServer.File {
        FakeDAVServer.File(id: id, path: path, etag: "e\(id)", modified: time, captured: time)
    }

    func ids() throws -> [FileID] { try library.gridItems(.all).map(\.fileId).sorted() }

    @Test func addingAPartnerFolderIndexesOnlyThatFolderWithoutRebuilding() async throws {
        await engine.sync()
        #expect(try ids() == [1, 2])
        server.clearRequests()

        try await engine.setPartnerFolders([anna])
        #expect(try ids() == [1, 2, 10, 11])
        // Only the partner folder was walked; no capture-time index of the whole library (a rebuild) ran.
        #expect(server.requests(.indexByCapture).isEmpty)
        let walked = server.requests(.indexByModified).map(\.body)
        #expect(!walked.isEmpty)
        #expect(walked.allSatisfy { $0.contains("/files/alice/Anna photos") && !$0.contains("/files/alice/Photos<") })
        #expect(PartnerSettings.load(database).folders == [anna])

        // The next sync keeps both, and a new partner photo arrives with the usual delta sync.
        server.put(file(12, "/Anna photos/new.jpg", time: 4000))
        await engine.sync()
        #expect(try ids() == [1, 2, 10, 11, 12])
        #expect(server.requests(.indexByCapture).isEmpty, "no rebuild: partner folders are not part of the folder key")
    }

    @Test func removingAPartnerFolderRemovesItsPhotosOnly() async throws {
        await engine.sync()
        try await engine.setPartnerFolders([anna])
        #expect(try ids() == [1, 2, 10, 11])

        try await engine.setPartnerFolders([])
        #expect(try ids() == [1, 2])
        await engine.sync(forceReconcile: true)
        #expect(try ids() == [1, 2], "a reconciliation does not bring them back")
    }

    @Test func aPartnerFolderInsideTheTimelineFoldersOnlyChangesTheBadge() async throws {
        server.state.withLock { _ = $0.folders.insert("/Photos/Shared by Ben") }
        server.put(file(30, "/Photos/Shared by Ben/p.jpg", time: 1200))
        await engine.sync()
        #expect(try ids() == [1, 2, 30])
        server.clearRequests()

        let ben = PartnerFolder(path: "/Photos/Shared by Ben", ownerId: "ben", ownerDisplayName: "Ben")
        try await engine.setPartnerFolders([ben])
        #expect(server.requests.isEmpty, "already indexed: nothing to fetch")
        try await engine.setPartnerFolders([])
        #expect(try ids() == [1, 2, 30], "still a timeline folder: nothing is removed")
    }

    @Test func partnerPathsMatchFoldersAndBelow() {
        let paths = PartnerPaths()
        #expect(!paths.contains(directory: "/Anna photos"))
        paths.set(["/Anna photos"])
        #expect(paths.contains(directory: "/Anna photos"))
        #expect(paths.contains(directory: "/Anna photos/2025"))
        #expect(!paths.contains(directory: "/Anna photos 2"))
        #expect(!paths.contains(directory: "/Photos"))
        let settings = PartnerSettings(folders: [anna])
        #expect(settings.partner(containing: "/Anna photos/2025/y.jpg") == anna)
        #expect(settings.partner(containing: "/Photos/a.jpg") == nil)
    }

    @Test func settingsSurviveInTheAccountDatabase() throws {
        var settings = PartnerSettings(folders: [anna], showInTimeline: false)
        try settings.save(database)
        #expect(PartnerSettings.load(database) == settings)
        settings.showInTimeline = true
        try settings.save(database)
        #expect(PartnerSettings.load(database).showInTimeline)
    }
}

/// A real received share in the timeline (PHOTOS_IT_SERVER/USER/PASSWORD, an admin account): creates a partner account
/// that shares a folder with two photos, adds it, removes it, and deletes the partner account again.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PHOTOS_IT_SERVER"] != nil))
struct PartnerTimelineIntegrationTests {
    @Test func receivedShareIsIndexedWithTheTimeline() async throws {
        let env = ProcessInfo.processInfo.environment
        let server = URL(string: env["PHOTOS_IT_SERVER"]!)!
        let user = env["PHOTOS_IT_USER"] ?? "admin"
        let http = HTTPClient(trustStore: TrustStore(directory: nil))
        func api(_ user: String, _ password: String) -> PhotosAPI {
            let connection = ServerConnection(serverURL: server, userId: user, loginName: user, appPassword: password, userAgent: "tests")
            return PhotosAPI(dav: DAVClient(http: http, connection: connection), ocs: OCSClient(http: http, connection: connection))
        }
        let admin = api(user, env["PHOTOS_IT_PASSWORD"] ?? "")
        let partnerId = "r3-E3-it-\(UUID().uuidString.prefix(6).lowercased())"
        let password = "Partner-\(UUID().uuidString)"
        _ = try await admin.ocs.raw("POST", "ocs/v2.php/cloud/users", form: ["userid": partnerId, "password": password])
        defer { Task { _ = try? await admin.ocs.raw("DELETE", "ocs/v2.php/cloud/users/\(partnerId)") } }

        let partner = api(partnerId, password)
        let folder = "/r3-E3 partner photos"
        try await partner.dav.mkcol(partner.connection.filesURL(folder))
        for index in 1...2 {
            _ = try await partner.dav.put(
                partner.connection.filesURL("\(folder)/p\(index).jpg"), data: Data((0..<2000).map { _ in UInt8.random(in: 0...255) }),
                headers: ["X-OC-MTime": String(1_700_000_000 + index)])
        }
        _ = try await partner.sharing.createShare(path: folder, kind: .user, shareWith: user)
        let received = try await admin.sharing.sharedWithMe().first { $0.ownerId == partnerId }
        let share = try #require(received)
        #expect(share.isFolder)

        let database = try AccountDatabase.temporary()
        let library = LibraryStore(database: database)
        let engine = SyncEngine(api: admin, database: database, features: ServerFeatures(serverVersion: ServerVersion(major: 33)))
        await engine.sync()
        let before = try library.count()
        #expect(before > 0)

        let path = share.path.isEmpty ? share.target : share.path
        try await engine.setPartnerFolders([PartnerFolder(path: path, ownerId: partnerId, ownerDisplayName: share.ownerDisplayName)])
        let partnerItems = try library.gridItems(.all).filter { $0.directory == path }
        #expect(partnerItems.count == 2)
        #expect(try library.count() == before + 2)
        // Syncing again keeps them (the share is one of the indexed folders now).
        await engine.sync(forceReconcile: true)
        #expect(try library.gridItems(.all).filter { $0.directory == path }.count == 2)

        try await engine.setPartnerFolders([])
        #expect(try library.count() == before)
        _ = try await admin.ocs.raw("DELETE", "ocs/v2.php/cloud/users/\(partnerId)")
    }
}
