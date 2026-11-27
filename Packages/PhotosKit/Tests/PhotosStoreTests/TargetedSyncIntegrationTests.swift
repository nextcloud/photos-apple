// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import Testing

@testable import PhotosModel
@testable import PhotosNetworking
@testable import PhotosStore

/// The targeted walk against a real server (SPEC §22.4.2). Runs only with PHOTOS_IT_SERVER (see `IntegrationTests`);
/// works in a folder of its own below the first timeline folder and removes it again.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PHOTOS_IT_SERVER"] != nil))
struct TargetedSyncIntegrationTests {
    let base = IntegrationTests()

    func put(_ api: PhotosAPI, _ path: String) async throws {
        _ = try await api.dav.put(api.connection.filesURL(path), data: Data([0xFF, 0xD8, 0xFF, 0xD9]))
    }

    func indexed(_ database: AccountDatabase, below folder: String) async throws -> [String] {
        try await database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT path FROM media WHERE path LIKE ? ORDER BY path", arguments: [folder + "/%"])
        }
    }

    /// Deletes, a move, a renamed folder and a new folder made on the server arrive with a targeted walk: no full walk
    /// runs, and the server's folder ETags behave as the walk expects (every folder above a change changes).
    @Test func changesArriveWithATargetedWalk() async throws {
        let api = base.api
        let features = try await FeatureDetector(dav: api.dav, ocs: api.ocs).detect()
        let root = try #require(features.userConfig.photosSourceFolders.first)
        let folder = (root == "/" ? "" : root) + "/r12-speed-it-\(Int(Date().timeIntervalSince1970))"
        try await api.dav.mkcolRecursive(userPath: folder + "/A/B")
        try await api.dav.mkcolRecursive(userPath: folder + "/C")
        do {
            for path in ["A/a1.jpg", "A/a2.jpg", "A/B/b1.jpg", "A/B/b2.jpg", "C/c1.jpg"] { try await put(api, folder + "/" + path) }
            let database = try AccountDatabase.temporary()
            let engine = SyncEngine(api: api, database: database, features: features)
            await engine.sync(reconcile: .opened)  // the first launch: initial sync and a full walk, which stores the tree
            #expect(try await indexed(database, below: folder).count == 5)
            let tree = try database.syncValue(SyncEngine.Key.folderTree)
            #expect(tree != nil)
            let fullWalk = try database.syncValue(SyncEngine.Key.lastFullReconcile)

            // Elsewhere: a delete, a move between folders, a renamed folder, a new folder with a photo.
            let etagC = try await api.folderETag(folder + "/C")
            try await api.dav.delete(api.connection.filesURL(folder + "/A/B/b1.jpg"))
            try await api.dav.move(api.connection.filesURL(folder + "/A/a1.jpg"), to: api.connection.filesURL(folder + "/A/B/a1.jpg"))
            try await api.dav.move(api.connection.filesURL(folder + "/C"), to: api.connection.filesURL(folder + "/D"))
            try await api.dav.mkcol(api.connection.filesURL(folder + "/E"))
            try await put(api, folder + "/E/e1.jpg")
            #expect(try await api.folderETag(folder + "/D") == etagC)  // a moved folder keeps its ETag

            let started = ContinuousClock.now
            await engine.sync(reconcile: .opened)
            let elapsed = ContinuousClock.now - started
            #expect(
                try await indexed(database, below: folder) == [
                    folder + "/A/B/a1.jpg", folder + "/A/B/b2.jpg", folder + "/A/a2.jpg", folder + "/D/c1.jpg", folder + "/E/e1.jpg",
                ])
            #expect(try database.syncValue(SyncEngine.Key.lastFullReconcile) == fullWalk)
            #expect(try database.syncValue(SyncEngine.Key.targetedWalk) == nil)
            print("PERF targeted walk on \(base.connection.serverURL): \(elapsed)")

            // Nothing changed since: a launch lists nothing (the root's ETag is the stored one).
            await engine.sync(reconcile: .opened)
            #expect(try database.syncValue(SyncEngine.Key.lastFullReconcile) == fullWalk)
        } catch {
            try? await api.dav.delete(api.connection.filesURL(folder))
            throw error
        }
        try await api.dav.delete(api.connection.filesURL(folder))
    }

    /// Walk times on a large library: `PHOTOS_IT_WALK_FOLDER` names a folder below the timeline with many photos in
    /// many folders (made for the measurement), `PHOTOS_IT_WALK_DELETE` a file in it that may be deleted. Prints the
    /// initial sync, a full walk ("Sync now") and the targeted walk after the delete (`PERF` lines).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PHOTOS_IT_WALK_FOLDER"] != nil))
    func measureWalks() async throws {
        let env = ProcessInfo.processInfo.environment
        let api = base.api
        let features = try await FeatureDetector(dav: api.dav, ocs: api.ocs).detect()
        let database = try AccountDatabase.temporary()
        let engine = SyncEngine(api: api, database: database, features: features)
        var started = ContinuousClock.now
        await engine.sync()
        let count = try LibraryStore(database: database).count()
        print("PERF walk: initial sync and first full walk of \(count) items: \(ContinuousClock.now - started)")
        started = ContinuousClock.now
        await engine.sync(reconcile: .now)
        print("PERF walk: full walk (Sync now) of \(count) items: \(ContinuousClock.now - started)")
        started = ContinuousClock.now
        await engine.sync(reconcile: .opened)
        print("PERF walk: launch without changes: \(ContinuousClock.now - started)")
        if let victim = env["PHOTOS_IT_WALK_DELETE"] {
            try await api.dav.delete(api.connection.filesURL(victim))
            started = ContinuousClock.now
            await engine.sync(reconcile: .opened)
            print("PERF walk: launch after one delete (targeted walk): \(ContinuousClock.now - started)")
            #expect(try LibraryStore(database: database).count() == count - 1)
            started = ContinuousClock.now
            await engine.sync(reconcile: .now)
            print("PERF walk: full walk of \(count - 1) items for comparison: \(ContinuousClock.now - started)")
        }
    }
}
