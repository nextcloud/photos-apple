// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import Testing

@testable import PhotosModel
@testable import PhotosNetworking
@testable import PhotosStore

/// Orphaned edit recipes (SPEC §22.5.3): the rules, the hook after a full reconcile, and the index lookups.
@Suite(.serialized, .timeLimit(.minutes(1))) struct OrphanRecipesStoreTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func onlyRecipesGoneEverywhereForThirtyDaysAreRemoved() {
        let day: TimeInterval = 86_400
        // 1 moved (the server has it), 2 in the trash bin, 3 newly gone, 4 gone for 31 days, 5 gone for 29 days.
        let plan = OrphanRecipes.plan(
            candidates: [1, 2, 3, 4, 5], existing: [1], trashed: [2],
            marks: [4: t0.addingTimeInterval(-31 * day), 5: t0.addingTimeInterval(-29 * day), 9: t0.addingTimeInterval(-40 * day)],
            now: t0)
        #expect(plan.remove == [4])
        #expect(plan.marks == [3: t0, 5: t0.addingTimeInterval(-29 * day)])
        // A recipe whose photo came back (restored, found again) loses its mark: 9 is not a candidate any more.
        #expect(plan.marks[9] == nil)
    }

    @Test func theHookRunsAfterACompletedFullReconcileOnly() async throws {
        let server = FakeDAVServer()
        let database = try AccountDatabase.temporary()
        let engine = SyncEngine(
            api: server.api, database: database, features: ServerFeatures(serverVersion: ServerVersion(major: 36)), reconcileInterval: 3600)
        server.put(FakeDAVServer.File(id: 1, path: "/Photos/a.jpg", etag: "e1", modified: 1000, captured: 1000))
        let runs = Mutex(0)
        await engine.setAfterFullReconcile { runs.withLock { $0 += 1 } }
        await engine.sync()  // the first sync and the reconcile that follows it
        #expect(await eventually { runs.withLock { $0 } == 1 })
        await engine.sync()  // not due: no walk
        try await Task.sleep(for: .milliseconds(100))
        #expect(runs.withLock { $0 } == 1)
        await engine.sync(forceReconcile: true)
        #expect(await eventually { runs.withLock { $0 } == 2 })
    }

    @Test func indexLookups() throws {
        let database = try AccountDatabase.temporary()
        let library = LibraryStore(database: database)
        #expect(try library.canaryFileId() == nil)
        try library.upsert([
            MediaItem(fileId: 5, path: "/Photos/a.jpg", name: "a.jpg", mimeType: "image/jpeg", kind: .image, etag: "a", modifiedAt: t0),
            MediaItem(
                fileId: 6, path: "/Photos/b.jpg", name: "b.jpg", mimeType: "image/jpeg", kind: .image, etag: "b",
                modifiedAt: t0.addingTimeInterval(10)),
        ])
        // 7 is a photo of an album shared with the user: not in the user's files, but known.
        let collections = CollectionStore(database: database)
        let album = Album(kind: .shared, name: "From Bob")
        try collections.upsertAlbum(album)
        try database.writer.write { db in
            try db.execute(
                sql: "INSERT INTO albumItem(albumId, fileId, childName, origin, position) VALUES (?, 7, 'x.jpg', 'user', 0)",
                arguments: [album.id])
        }
        #expect(try library.knownFileIds(among: [5, 7, 8]) == [5, 7])
        #expect(try library.knownFileIds(among: []) == [])
        #expect(try library.canaryFileId() == 6)
    }

    func eventually(_ condition: @Sendable () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}

/// `ServerOrphanProbe` against a real server: a file moved elsewhere is found, a trashed one (also inside a trashed
/// folder) is in the trash listing, and the canary guards the SEARCH. Runs only when PHOTOS_IT_SERVER, PHOTOS_IT_USER and
/// PHOTOS_IT_PASSWORD are set; works in a folder `r12-tidy-orphans-…` of its own and removes it and its trash entries.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PHOTOS_IT_SERVER"] != nil), .timeLimit(.minutes(2)))
struct OrphanProbeIntegrationTests {
    let dav: DAVClient
    let api: PhotosAPI
    let folder = "/r12-tidy-orphans-\(UUID().uuidString.prefix(8))"

    init() {
        let env = ProcessInfo.processInfo.environment
        let user = env["PHOTOS_IT_USER"] ?? "admin"
        let connection = ServerConnection(
            serverURL: URL(string: env["PHOTOS_IT_SERVER"] ?? "http://localhost")!, userId: user, loginName: user,
            appPassword: env["PHOTOS_IT_PASSWORD"] ?? "", userAgent: "Mozilla/5.0 (macOS) Nextcloud-Photos/tests")
        let http = HTTPClient(trustStore: TrustStore(directory: nil))
        dav = DAVClient(http: http, connection: connection)
        api = PhotosAPI(dav: dav, ocs: OCSClient(http: http, connection: connection))
    }

    func fileId(_ path: String) async throws -> FileID {
        try #require(
            try await dav.propfind(dav.connection.filesURL(path), depth: 0, properties: [DAVProp.fileId]).first?.int64(DAVProp.fileId))
    }

    func upload(_ path: String) async throws -> FileID {
        _ = try await dav.put(
            dav.connection.filesURL(path), data: Data("orphan test \(path)".utf8), headers: ["Content-Type": "text/plain"])
        return try await fileId(path)
    }

    @Test func movedFilesAreFoundAndTrashedOnesAreInTheTrash() async throws {
        try await dav.mkcolRecursive(userPath: "\(folder)/inner")
        try await dav.mkcolRecursive(userPath: "\(folder)/moved")
        let canary = try await fileId(folder)
        let kept = try await upload("\(folder)/kept.txt")
        let moved = try await upload("\(folder)/moved.txt")
        let trashed = try await upload("\(folder)/trashed.txt")
        let inner = try await upload("\(folder)/inner/nested.txt")
        try await dav.move(dav.connection.filesURL("\(folder)/moved.txt"), to: dav.connection.filesURL("\(folder)/moved/elsewhere.txt"))
        try await dav.delete(dav.connection.filesURL("\(folder)/trashed.txt"))
        try await dav.delete(dav.connection.filesURL("\(folder)/inner"))
        let probe = ServerOrphanProbe(api: api, canary: canary)
        let existing = try await probe.existing([kept, moved, trashed, inner, 999_999_999])
        #expect(existing == [kept, moved])
        let inTrash = try await probe.trashed()
        #expect(inTrash.contains(trashed))
        #expect(inTrash.contains(inner))
        #expect(!inTrash.contains(kept))
        // A canary that does not exist: the SEARCH is not trusted.
        await #expect(throws: OrphanRecipes.Failure.canaryMissing) {
            _ = try await ServerOrphanProbe(api: api, canary: 999_999_998).existing([kept])
        }
        // Clean up: the folder, then this test's entries in the trash bin (never the trash bin itself).
        try await dav.delete(dav.connection.filesURL(folder))
        for item in try await api.trash(mimeTypes: nil) + trashedFolders() where item.originalLocation.hasPrefix(String(folder.dropFirst()))
        {
            try? await api.deletePermanently(item)
        }
    }

    /// Folders in the trash bin (`trash(mimeTypes:)` lists files only).
    func trashedFolders() async throws -> [TrashedItem] {
        let listing = try await dav.propfind(
            dav.connection.davURL("trashbin/\(dav.connection.userId)/trash/"), depth: 1,
            properties: [DAVProp.fileId, DAVProp.trashbinOriginalLocation, DAVProp.resourceType])
        return listing.dropFirst().filter(\.isCollection).compactMap { resource in
            guard let fileId = resource.int64(DAVProp.fileId) else { return nil }
            let name = resource.href.split(separator: "/").last.map(String.init) ?? ""
            return TrashedItem(
                trashName: name, fileId: fileId, originalName: name,
                originalLocation: resource.string(DAVProp.trashbinOriginalLocation) ?? "", deletedAt: nil, mimeType: "", size: 0)
        }
    }
}
