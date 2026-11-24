// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import Synchronization
import Testing

@testable import PhotosModel
@testable import PhotosNetworking
@testable import PhotosStore

// MARK: Feature detection

/// What detection does when the Photos settings cannot be read, and where the `.nomedia` folders come from.
@Suite struct BootstrapDetectionTests {
    /// The settings a previous detection found: not the defaults.
    func cached(from server: RecordedServer) async throws -> ServerFeatures {
        var cached = try await server.detector.detect()
        cached.userConfig.photosSourceFolders = ["/Bilder", "/Familie"]
        cached.userConfig.photosLocation = "/Bilder"
        cached.nomediaPaths = ["/Bilder/Privat"]
        cached.imageMimeTypes = ["image/jpeg"]
        cached.videoMimeTypes = ["video/mp4"]
        return cached
    }

    func failPhotosPage(_ server: RecordedServer, with response: RecordedServer.Response) {
        server.override("GET /index.php/apps/photos/", with: response)
        server.override("GET /index.php/apps/photos", with: response)
    }

    /// A Photos page that fails must not turn the timeline folders into `/Photos`: the sync engine would rebuild the
    /// index for folders the user never chose.
    @Test(arguments: [RecordedServer.Response.status(500, "<html>error</html>"), .failure(.timedOut), .status(200, "<html>login</html>")])
    func failedBootstrapKeepsTheCachedSettings(failure: RecordedServer.Response) async throws {
        let server = RecordedServer("stock-master")
        let cached = try await cached(from: server)
        failPhotosPage(server, with: failure)
        server.override("SEARCH /remote.php/dav/", with: .status(500, ""))

        let features = try await server.detector.detect(cached: cached)
        #expect(features.userConfig.photosSourceFolders == ["/Bilder", "/Familie"])
        #expect(features.userConfig.photosLocation == "/Bilder")
        #expect(features.imageMimeTypes == ["image/jpeg"])
        #expect(features.videoMimeTypes == ["video/mp4"])
        #expect(features.nomediaPaths == ["/Bilder/Privat"])
        // Values of features that were not found this time do not come along.
        #expect(features.userConfig.smartAlbums == nil)
        #expect(features.enabled.isSuperset(of: StockServerDetectionTests.core))
    }

    /// 404: there is no Photos page, so there are no settings; defaults are right, whatever was cached.
    @Test func absentPhotosPageMeansDefaults() async throws {
        let server = RecordedServer("stock-master")
        let cached = try await cached(from: server)
        failPhotosPage(server, with: RecordedServer.notFound)
        let features = try await server.detector.detect(cached: cached)
        #expect(features.userConfig.photosSourceFolders == ["/Photos"])
        #expect(features.imageMimeTypes == MimeTypes.defaultImages)
    }

    /// With the config API the page is not read, so the `.nomedia` folders come from a files SEARCH.
    @Test func nomediaFoldersAreSearchedWhenTheConfigAPIIsUsed() async throws {
        let server = RecordedServer("stock-master")
        server.override(
            "GET /ocs/v2.php/cloud/capabilities",
            with: .status(
                200,
                #"{"ocs":{"meta":{"status":"ok","statuscode":200,"message":"OK"},"data":{"version":{"major":36,"string":"36.0.0"},"capabilities":{"photos":{"version":"9.1.0","features":["config-api"]}}}}}"#
            ))
        server.override(
            "GET /ocs/v2.php/apps/photos/api/v1/config",
            with: .status(
                200,
                #"{"ocs":{"meta":{"status":"ok","statuscode":200,"message":"OK"},"data":{"photosSourceFolders":"[\"/Bilder\"]","photosLocation":"/Bilder"}}}"#
            ))
        func entry(_ path: String) -> String {
            "<d:response><d:href>/remote.php/dav/files/admin\(path)</d:href><d:propstat><d:prop><oc:fileid>7</oc:fileid><oc:size>0</oc:size></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
        }
        server.override(
            "SEARCH /remote.php/dav/",
            with: .status(
                207,
                FakeDAVServer.multistatus(
                    entry("/Bilder/Privat/.nomedia") + entry("/Bilder/Scans/.noimage") + entry("/Bilder/not-this/photo.jpg"))))

        let features = try await server.detector.detect()
        #expect(features.userConfig.photosSourceFolders == ["/Bilder"])
        #expect(features.nomediaPaths == ["/Bilder/Privat", "/Bilder/Scans"])
        #expect(!server.lines.contains { $0.hasPrefix("GET /index.php/apps/photos") })
        let search = try #require(zip(server.lines, server.bodies).first { $0.0.hasPrefix("SEARCH") }?.1)
        #expect(search.contains(".nomedia") && search.contains(".noimage"))

        // No such files (or a server that answers 404): nothing is excluded, and nothing fails.
        server.override("SEARCH /remote.php/dav/", with: RecordedServer.notFound)
        #expect(try await server.detector.detect(cached: features).nomediaPaths == [])
        // The SEARCH failed: what was known stays.
        server.override("SEARCH /remote.php/dav/", with: .failure(.timedOut))
        #expect(try await server.detector.detect(cached: features).nomediaPaths == ["/Bilder/Privat", "/Bilder/Scans"])
    }

    /// A stock server lists the folders in its page; detection sends no SEARCH there.
    @Test func stockServerIsNotSearched() async throws {
        let server = RecordedServer("stock-master")
        let features = try await server.detector.detect()
        #expect(features.nomediaPaths == [])
        #expect(!server.lines.contains { $0.hasPrefix("SEARCH") })
    }
}

// MARK: Sync

/// Paging, the mass-delete guard, the reconcile throttle and the index rebuild of the sync engine.
@Suite struct SyncSafetyTests {
    let server = FakeDAVServer()
    let database: AccountDatabase
    let library: LibraryStore
    let features = ServerFeatures(serverVersion: ServerVersion(major: 36))

    init() throws {
        database = try AccountDatabase.temporary()
        library = LibraryStore(database: database)
    }

    func engine(reconcileInterval: TimeInterval = 0, confirmationDelay: TimeInterval = 0) -> SyncEngine {
        SyncEngine(
            api: server.api, database: database, features: features, reconcileInterval: reconcileInterval,
            massDeleteConfirmationDelay: confirmationDelay)
    }

    func file(_ id: FileID, _ path: String? = nil, time: Double, mime: String = "image/jpeg") -> FakeDAVServer.File {
        FakeDAVServer.File(id: id, path: path ?? "/Photos/\(id).jpg", etag: "e\(id)", modified: time, captured: time, mime: mime)
    }

    /// Files `1...count`, the higher the id the newer.
    func fill(_ count: Int) {
        server.state.withLock { state in
            for id in 1...FileID(count) { state.files[id] = file(id, time: 1000 + Double(id) * 10) }
            FakeDAVServer.bumpRoot(&state)
        }
    }

    func remove(_ ids: ClosedRange<FileID>) {
        server.state.withLock { state in
            for id in ids { state.files[id] = nil }
            FakeDAVServer.bumpRoot(&state)
        }
    }

    func ids() throws -> [FileID] { try library.gridItems(.all).map(\.fileId).sorted() }

    // MARK: Paging (3)

    /// A full page in which the parser skips an entry is not the last page.
    @Test func pageWithSkippedEntriesIsNotTheLastOne() async throws {
        server.put(
            file(1, time: 5000), file(2, "/Photos/notes.pdf", time: 4000, mime: "application/pdf"), file(3, time: 3000),
            file(4, time: 2000))
        for order in [PhotosAPI.IndexOrder.modified, .captureTime] {
            var cursor: Double?
            var found: [FileID] = []
            var pages = 0
            while pages < 10 {
                let page = try await server.api.indexPage(
                    sourceFolders: ["/Photos"], mimeTypes: ["image/jpeg"], properties: DAVProp.mediaIndex, order: order, before: cursor,
                    limit: 2)
                found += page.items.map(\.fileId)
                pages += 1
                guard let next = page.next else { break }
                cursor = next
            }
            #expect(found == [1, 3, 4], "\(order)")
            #expect(pages < 10)
        }
    }

    /// The whole library arrives, and the reconciliation that follows removes nothing it merely did not get to.
    @Test func librarySpanningPagesWithSkippedEntriesSyncsCompletely() async throws {
        fill(2100)
        // The newest entry of the first page is something the app does not show.
        server.put(file(9000, "/Photos/readme.pdf", time: 90_000, mime: "application/pdf"))
        let engine = engine()
        await engine.sync()
        #expect(try library.count() == 2100)
        // Again, now as a reconciliation over a complete index.
        await engine.sync(forceReconcile: true)
        #expect(try library.count() == 2100)
        #expect(try library.item(1) != nil)
    }

    // MARK: Mass-delete guard (3)

    @Test func suspiciousRule() {
        #expect(!SyncEngine.isSuspiciousRemoval(removed: 20, known: 20))  // tiny index
        #expect(!SyncEngine.isSuspiciousRemoval(removed: 15, known: 30))  // half
        #expect(SyncEngine.isSuspiciousRemoval(removed: 16, known: 30))
        #expect(SyncEngine.isSuspiciousRemoval(removed: 1000, known: 1000))
        #expect(!SyncEngine.isSuspiciousRemoval(removed: 400, known: 1000))
    }

    /// A listing that lacks most of the library is not applied at once; the next listing decides.
    @Test func massRemovalNeedsASecondListing() async throws {
        fill(30)
        let engine = engine()
        await engine.sync()
        #expect(try library.count() == 30)

        remove(1...20)
        await engine.sync(forceReconcile: true)
        #expect(try library.count() == 30)
        #expect(try database.syncValue(SyncEngine.Key.suspectedMassDelete) != nil)

        // The files are really gone: the confirming pass (any next sync once the confirmation delay is over, the root
        // ETag need not change) removes them.
        server.clearRequests()
        await engine.sync()
        #expect(try ids() == Array(21...30))
        #expect(!server.requests(.indexByModified).isEmpty)
        #expect(try database.syncValue(SyncEngine.Key.suspectedMassDelete) == nil)
    }

    /// The server was only incomplete for a moment (a storage not mounted): nothing is lost, and ordinary deletes
    /// keep working without a second pass.
    @Test func incompleteListingCostsNothing() async throws {
        fill(30)
        let engine = engine()
        await engine.sync()
        let lost = server.state.withLock { state in state.files.filter { $0.key <= 20 } }
        remove(1...20)
        await engine.sync()
        #expect(try library.count() == 30)

        server.state.withLock { state in
            for (id, file) in lost { state.files[id] = file }
            FakeDAVServer.bumpRoot(&state)
        }
        await engine.sync()
        #expect(try library.count() == 30)
        #expect(try database.syncValue(SyncEngine.Key.suspectedMassDelete) == nil)

        remove(1...10)
        await engine.sync()
        #expect(try ids() == Array(11...30))
    }

    /// The second listing confirms only what the first one lacked too, and not before the confirmation delay.
    @Test func secondListingTooSoonRemovesNothing() async throws {
        fill(30)
        let engine = engine(confirmationDelay: 3600)
        await engine.sync()
        remove(1...20)
        await engine.sync(forceReconcile: true)
        await engine.sync(forceReconcile: true)  // seconds later: pull to refresh, the forced sync after an undo
        #expect(try library.count() == 30)
        // An ordinary sync does not even walk the library for it before the delay is over.
        server.clearRequests()
        await engine.sync()
        #expect(server.requests(.indexByModified).isEmpty)

        // An hour later the next sync confirms.
        try database.setSyncValue(SyncEngine.Key.suspectedMassDelete, String(Date().timeIntervalSince1970 - 3601))
        await engine.sync()
        #expect(try ids() == Array(21...30))
        #expect(try database.syncValue(SyncEngine.Key.suspectedMassDelete) == nil)
    }

    /// Files of a mounted storage that both listings lack are removed; those that came back stay.
    @Test func onlyWhatBothListingsLackIsRemoved() async throws {
        server.state.withLock { state in
            for id in FileID(1)...30 {
                var file = file(id, id <= 10 ? "/Photos/Share/\(id).jpg" : nil, time: 1000 + Double(id) * 10)
                if id <= 10 { file.mountType = "shared" }
                state.files[id] = file
            }
            FakeDAVServer.bumpRoot(&state)
        }
        let engine = engine()
        await engine.sync()
        #expect(try library.count() == 30)
        let shared = server.state.withLock { state in state.files.filter { $0.key <= 5 } }

        // Not many, but on mounted storage: kept until another listing agrees.
        remove(1...10)
        await engine.sync()
        #expect(try library.count() == 30)
        #expect(try database.syncValue(SyncEngine.Key.suspectedMassDelete) != nil)

        server.state.withLock { state in
            for (id, file) in shared { state.files[id] = file }
            FakeDAVServer.bumpRoot(&state)
        }
        await engine.sync()
        #expect(try ids() == Array(1...5) + Array(11...30))
        #expect(try database.syncValue(SyncEngine.Key.suspectedMassDelete) == nil)
    }

    /// An external storage that is not available makes the whole library vanish from the listings; however often that
    /// is seen, the index keeps it, and it is all there again when the storage is back.
    @Test func unavailableExternalStorageNeverEmptiesTheIndex() async throws {
        server.state.withLock { state in
            state.folders.insert("/Photos/External")
            for id in FileID(1)...30 {
                var file = file(id, "/Photos/External/\(id).jpg", time: 1000 + Double(id) * 10)
                file.mountType = "external"
                state.files[id] = file
            }
            FakeDAVServer.bumpRoot(&state)
        }
        let engine = engine()
        await engine.sync()
        #expect(try library.count() == 30)

        server.state.withLock { state in
            state.unavailable = ["/Photos/External"]
            FakeDAVServer.bumpRoot(&state)
        }
        for _ in 0..<3 { await engine.sync(forceReconcile: true) }
        #expect(try library.count() == 30)
        // The server was asked whether the files are gone, and its error kept them.
        #expect(server.requests(.propfind).contains { $0.path.hasPrefix("/Photos/External/") })

        server.state.withLock { state in
            state.unavailable = []
            FakeDAVServer.bumpRoot(&state)
        }
        await engine.sync()
        #expect(try library.count() == 30)
        #expect(try database.syncValue(SyncEngine.Key.suspectedMassDelete) == nil)

        // Files really deleted there go after the second listing.
        remove(1...3)
        await engine.sync()
        #expect(try library.count() == 30)
        await engine.sync()
        #expect(try ids() == Array(4...30))
    }

    /// Files a search leaves out but that are still there by path (a search that came back short) are not removed.
    @Test func filesStillThereByPathAreNotRemoved() async throws {
        fill(30)
        let engine = engine()
        await engine.sync()
        server.state.withLock { state in
            state.hiddenFromSearch = Set(1...20)
            FakeDAVServer.bumpRoot(&state)
        }
        await engine.sync()
        await engine.sync()
        await engine.sync(forceReconcile: true)
        #expect(try library.count() == 30)
        #expect(try database.syncValue(SyncEngine.Key.suspectedMassDelete) != nil)
    }

    // MARK: Throttle (8)

    /// A changed root no longer means a walk through the whole library on every sync.
    @Test func reconcileIsThrottledAndTheDeltaStillArrives() async throws {
        fill(5)
        let engine = engine(reconcileInterval: 600)
        await engine.sync()  // initial sync and its reconciliation
        #expect(try ids() == [1, 2, 3, 4, 5])
        server.clearRequests()

        let now = Date().timeIntervalSince1970
        var added = file(6, time: now)
        added.uploaded = now
        server.put(added)
        server.delete(1)
        await engine.sync()
        // New files come with the delta SEARCH; the delete waits for the reconciliation.
        #expect(try ids() == [1, 2, 3, 4, 5, 6])
        #expect(server.requests(.changed).count == 1)
        #expect(server.requests(.indexByModified).isEmpty)

        // Nothing changed since: neither a delta nor a walk.
        await engine.sync()
        #expect(server.requests(.changed).count == 1)
        #expect(server.requests(.indexByModified).isEmpty)

        // Ten minutes later the owed reconciliation runs, although the root ETag is the stored one.
        try database.setSyncValue(SyncEngine.Key.lastReconcile, String(now - 601))
        await engine.sync()
        #expect(try ids() == [2, 3, 4, 5, 6])
        #expect(!server.requests(.indexByModified).isEmpty)

        // And it is not owed any more.
        server.clearRequests()
        try database.setSyncValue(SyncEngine.Key.lastReconcile, String(now - 601))
        await engine.sync()
        #expect(server.requests(.indexByModified).isEmpty)
    }

    @Test func userRequestedSyncIsNotThrottled() async throws {
        fill(5)
        let engine = engine(reconcileInterval: 600)
        await engine.sync()
        server.delete(1)
        await engine.sync(forceReconcile: true)
        #expect(try ids() == [2, 3, 4, 5])
    }

    /// Pull to refresh does not walk the library again right after a walk; after the interval it does, even when no root
    /// ETag changed.
    @Test func pullToRefreshReconcilesOnlyAfterTheInterval() async throws {
        fill(5)
        let engine = engine(reconcileInterval: 600)
        await engine.sync()
        server.delete(1, changingRootETag: false)
        server.clearRequests()
        await engine.sync(reconcile: .refresh)
        #expect(server.requests(.indexByModified).isEmpty)
        #expect(try ids() == [1, 2, 3, 4, 5])

        try database.setSyncValue(SyncEngine.Key.lastReconcile, String(Date().timeIntervalSince1970 - 601))
        await engine.sync(reconcile: .refresh)
        #expect(try ids() == [2, 3, 4, 5])
    }

    /// While a backup uploads, the reconciliation its uploads made due waits; "Sync now" and an overdue one do not.
    @Test func reconcileWaitsWhileABackupUploads() async throws {
        fill(5)
        let engine = engine(reconcileInterval: 600)
        await engine.sync()
        let uploading = Mutex(true)
        await engine.setReconcileDeferral { uploading.withLock { $0 } }
        server.delete(1)
        try database.setSyncValue(SyncEngine.Key.lastReconcile, String(Date().timeIntervalSince1970 - 601))
        server.clearRequests()
        await engine.sync()
        #expect(server.requests(.indexByModified).isEmpty)
        #expect(try ids() == [1, 2, 3, 4, 5])

        // Overdue: a day without a reconciliation.
        try database.setSyncValue(SyncEngine.Key.lastReconcile, String(Date().timeIntervalSince1970 - 25 * 3600))
        await engine.sync()
        #expect(try ids() == [2, 3, 4, 5])

        server.delete(2)
        try database.setSyncValue(SyncEngine.Key.lastReconcile, String(Date().timeIntervalSince1970 - 601))
        await engine.sync()
        #expect(try ids() == [2, 3, 4, 5])
        uploading.withLock { $0 = false }
        await engine.sync()
        #expect(try ids() == [3, 4, 5])
    }

    @Test func largeLibrariesAreWalkedLessOften() async throws {
        let engine = engine(reconcileInterval: 600)
        #expect(await engine.interval(forIndexOf: 1000) == 600)
        #expect(await engine.interval(forIndexOf: 150_000) == 3600)
        #expect(await self.engine(reconcileInterval: 0).interval(forIndexOf: 150_000) == 0)
    }

    // MARK: Resumable reconciliation

    /// A walk that is cut off goes on from the page it reached at the next sync instead of starting again, and does not
    /// remove a file whose modification time moved past its cursor meanwhile.
    @Test func interruptedWalkResumesWhereItStopped() async throws {
        fill(4500)
        let engine = engine()
        await engine.sync()
        #expect(try library.count() == 4500)
        server.delete(4400, changingRootETag: false)  // on the first page (newest first)
        server.delete(10, changingRootETag: false)  // on the last page

        // The second page of the walk never answers; the sync is cancelled while it waits.
        server.clearRequests()
        server.gate.withLock {
            $0 = { request in
                if request.kind == .indexByModified, request.body.contains("<d:lt>"), !request.body.contains("<d:gte>") {
                    try? await Task.sleep(for: .seconds(60))
                }
            }
        }
        let task = Task { await engine.sync(forceReconcile: true) }
        #expect(
            await eventually { server.requests(.indexByModified).contains { $0.body.contains("<d:lt>") && !$0.body.contains("<d:gte>") } })
        task.cancel()
        await task.value
        server.gate.withLock { $0 = nil }
        #expect(try database.syncValue(SyncEngine.Key.reconcileWalk) != nil)
        #expect(try database.syncValue(SyncEngine.Key.reconcileCursor) != nil)
        #expect(try library.count() == 4500)

        // Meanwhile an old file is edited: its modification time is now newer than the walk's cursor.
        server.state.withLock { state in
            state.files[20]?.modified = Date().timeIntervalSince1970
            state.files[20]?.etag = "edited"
            FakeDAVServer.bumpRoot(&state)
        }
        server.clearRequests()
        await engine.sync()
        // Resumed: no request for the first page (the one without a cursor).
        let walk = server.requests(.indexByModified).filter { !$0.body.contains("<d:gte>") }
        #expect(!walk.isEmpty)
        #expect(walk.allSatisfy { $0.body.contains("<d:lt>") })
        #expect(try library.count() == 4498)
        #expect(try library.item(4400) == nil)
        #expect(try library.item(10) == nil)
        #expect(try library.item(20)?.etag == "edited")
        #expect(try database.syncValue(SyncEngine.Key.reconcileWalk) == nil)
        #expect(try await database.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM reconcileUnseen") } == 0)
    }

    // MARK: Recent uploads (27)

    /// Recent uploads are read again when they reach a checkpoint since the last look, not on every sync, and only while
    /// their place is still unknown.
    @Test func recentUploadsAreReadAgainAtCheckpoints() async throws {
        let engine = engine()
        let now = 2_000_000_000.0
        func row(_ id: FileID, uploaded: Double, place: String? = nil) -> MediaItem {
            var item = MediaItem(
                fileId: id, path: "/Photos/\(id).jpg", mimeType: "image/jpeg", etag: "e\(id)", modifiedAt: Date(timeIntervalSince1970: 1000)
            )
            item.uploadedAt = Date(timeIntervalSince1970: uploaded)
            item.place = place
            return item
        }
        try library.upsert([
            row(1, uploaded: now - 300),  // 5 minutes old: no checkpoint reached yet
            row(2, uploaded: now - 900),  // reached 10 minutes since the last look
            row(3, uploaded: now - 7200),  // between checkpoints
            row(4, uploaded: now - 900, place: "Lisbon"),  // nothing left to arrive
            row(5, uploaded: now - 49 * 3600),  // too old
            row(6, uploaded: now - 3700),  // reached one hour
        ])
        // Never looked: all of them.
        #expect(try await engine.recentUploadsToRefresh(now: now) == [1, 2, 6, 3])
        // Looked five minutes ago: not yet again.
        try database.setSyncValue(SyncEngine.Key.recentUploadsChecked, String(now - 300))
        #expect(try await engine.recentUploadsToRefresh(now: now) == nil)
        // Ten minutes ago: those that reached a checkpoint since.
        try database.setSyncValue(SyncEngine.Key.recentUploadsChecked, String(now - 600))
        #expect(try await engine.recentUploadsToRefresh(now: now) == [2, 6])
    }

    // MARK: Index rebuild (1)

    /// Other timeline folders: the index is rebuilt, albums and their content stay.
    @Test func changedSourceFoldersKeepAlbums() async throws {
        fill(3)
        let engine = engine()
        await engine.sync()
        let album = Album(kind: .own, name: "Holiday")
        try CollectionStore(database: database).upsertAlbum(album)
        try await database.writer.write { db in
            try db.execute(
                sql:
                    "INSERT INTO albumItem(albumId, fileId, childName, origin, ownerPath, position) VALUES (?, 2, '2-2.jpg', 'user', '/Photos/2.jpg', 1)",
                arguments: [album.id])
        }

        server.state.withLock { $0.folders.insert("/Pictures") }
        server.put(file(50, "/Pictures/x.jpg", time: 9000))
        var changed = features
        changed.userConfig.photosSourceFolders = ["/Pictures"]
        await engine.updateFeatures(changed)
        await engine.sync()

        #expect(try ids() == [50])
        #expect(try CollectionStore(database: database).album(id: album.id) != nil)
        #expect(try CollectionStore(database: database).albumItems(albumId: album.id).map(\.fileId) == [2])
    }
}

// MARK: Outbox

/// Queued operations follow the file (4, 6), locked files are retried, and operations that will never run give the
/// local row back (5).
///
/// The tests wait for the outbox (`waitUntilIdle`) instead of polling against the clock, and retry at once where a retry
/// is wanted: the other tests of the bundle run in parallel and can keep these waiting for many seconds. The time limit only stops a hang.
@Suite(.timeLimit(.minutes(5))) struct OutboxSafetyTests {
    let server = FakeDAVServer()
    let database: AccountDatabase
    let library: LibraryStore
    let engine: SyncEngine

    init() throws {
        database = try AccountDatabase.temporary()
        library = LibraryStore(database: database)
        engine = SyncEngine(
            api: server.api, database: database, features: ServerFeatures(serverVersion: ServerVersion(major: 36)), reconcileInterval: 0)
        for (id, path) in [(FileID(1), "/Photos/a.jpg"), (2, "/Photos/b.jpg")] {
            server.put(FakeDAVServer.File(id: id, path: path, etag: "e\(id)", modified: 1000, captured: 1000))
            try library.upsert([MediaItem(fileId: id, path: path, mimeType: "image/jpeg", etag: "e\(id)")])
        }
    }

    /// - Parameter restoring: failed and discarded operations read their rows again at once (as the app does).
    func outbox(retryDelay: TimeInterval = 3600, restoring: Bool = true) -> Outbox {
        let engine = self.engine
        guard restoring else { return Outbox(api: server.api, database: database, retryDelay: { _ in retryDelay }) }
        return Outbox(
            api: server.api, database: database, retryDelay: { _ in retryDelay }, restore: { _ = try? await engine.restoreRows() })
    }

    /// Queues the operations while offline (as the user taps), then lets them run.
    func run(_ operations: [PendingOperation], elsewhere: () -> Void = {}) async throws -> Outbox {
        let outbox = outbox()
        server.setOffline(true)
        try await outbox.enqueue(operations)
        await outbox.waitUntilIdle()
        #expect(try await outbox.nextRetryDate() != nil)
        elsewhere()
        server.setOffline(false)
        server.clearRequests()
        await outbox.kickNow()
        await outbox.waitUntilIdle()
        #expect(try await outbox.pendingCount() == 0)
        return outbox
    }

    let archived = "/.archive/Photos/a.jpg"

    // MARK: Paths (4)

    @Test func archiveThenUnarchive() async throws {
        let outbox = try await run([.archive(fileId: 1, path: "/Photos/a.jpg"), .unarchive(fileId: 1, path: "/Photos/a.jpg")])
        #expect(try await outbox.failedOperations().isEmpty)
        #expect(server.requests(.move).map(\.path) == ["/Photos/a.jpg", archived])
        #expect(server.file(1)?.path == "/Photos/a.jpg")
        #expect(try library.item(1)?.path == "/Photos/a.jpg")
        #expect(try library.item(1)?.isArchived == false)
    }

    @Test func archiveThenDelete() async throws {
        let outbox = try await run([.archive(fileId: 1, path: "/Photos/a.jpg"), .delete(fileId: 1, path: "/Photos/a.jpg")])
        #expect(try await outbox.failedOperations().isEmpty)
        #expect(server.requests(.delete).map(\.path) == [archived])
        #expect(server.file(1) == nil)  // not left behind in the archive
        #expect(try library.item(1) == nil)
    }

    @Test func archiveThenFavourite() async throws {
        let outbox = try await run([
            .archive(fileId: 1, path: "/Photos/a.jpg"), .favorite(fileId: 1, path: "/Photos/a.jpg", value: true),
        ])
        #expect(try await outbox.failedOperations().isEmpty)
        // The queued favourite was rewritten when the move completed: one request, to the right place.
        #expect(server.requests(.proppatch).map(\.path) == [archived])
        #expect(server.file(1)?.favorite == true)
        #expect(server.file(1)?.path == archived)
        #expect(try library.item(1)?.path == archived)
    }

    /// The file was moved on another device while the favourite waited: the operation finds it by its id.
    @Test func favouriteFollowsAFileMovedElsewhere() async throws {
        let outbox = try await run([.favorite(fileId: 1, path: "/Photos/a.jpg", value: true)]) {
            server.move(1, to: "/Photos/2026/a.jpg")
        }
        #expect(try await outbox.failedOperations().isEmpty)
        #expect(server.file(1)?.favorite == true)
    }

    // MARK: Reused paths (6)

    /// The queued delete addresses file 1. By the time it runs, another file has that path.
    @Test func queuedDeleteDoesNotHitAnotherFileAtTheSamePath() async throws {
        let outbox = try await run([.delete(fileId: 1, path: "/Photos/a.jpg")]) {
            server.move(1, to: "/Photos/renamed.jpg")
            server.put(FakeDAVServer.File(id: 9, path: "/Photos/a.jpg", etag: "e9", modified: 2000, captured: 2000))
        }
        #expect(try await outbox.failedOperations().isEmpty)
        #expect(server.file(9) != nil)
        #expect(server.file(1) == nil)
        #expect(server.requests(.delete).map(\.path) == ["/Photos/renamed.jpg"])
    }

    @Test func queuedDeleteOfAFileDeletedElsewhereLeavesItsSuccessorAlone() async throws {
        let outbox = try await run([.delete(fileId: 1, path: "/Photos/a.jpg")]) {
            server.delete(1)
            server.put(FakeDAVServer.File(id: 9, path: "/Photos/a.jpg", etag: "e9", modified: 2000, captured: 2000))
        }
        #expect(try await outbox.failedOperations().isEmpty)
        #expect(server.file(9) != nil)
        #expect(server.requests(.delete).isEmpty)
        // One lookup by id is all it cost.
        #expect(server.requests.count == 1)
    }

    @Test func queuedArchiveDoesNotMoveAnotherFileAtTheSamePath() async throws {
        let outbox = try await run([.archive(fileId: 1, path: "/Photos/a.jpg")]) {
            server.move(1, to: "/Photos/renamed.jpg")
            server.put(FakeDAVServer.File(id: 9, path: "/Photos/a.jpg", etag: "e9", modified: 2000, captured: 2000))
        }
        #expect(try await outbox.failedOperations().isEmpty)
        #expect(server.file(9)?.path == "/Photos/a.jpg")
        #expect(server.file(1)?.path == "/.archive/Photos/renamed.jpg")
        #expect(try library.item(1)?.path == "/.archive/Photos/renamed.jpg")
    }

    // MARK: Locked (5)

    @Test func lockedFileIsRetried() async throws {
        #expect(NetworkError.locked.isTransient)
        let refusals = Mutex(2)
        server.statusOverride.withLock {
            $0 = { request in
                guard request.kind == .delete else { return nil }
                return refusals.withLock { left in
                    left -= 1
                    return left >= 0 ? 423 : nil
                }
            }
        }
        let outbox = outbox(retryDelay: 0)
        try await outbox.enqueue([.delete(fileId: 1, path: "/Photos/a.jpg")])
        await outbox.waitUntilIdle()
        #expect(try await outbox.pendingCount() == 0)
        #expect(try await outbox.failedOperations().isEmpty)
        #expect(server.file(1) == nil)
        #expect(server.requests(.delete).count == 3)
    }

    /// Not for ever: the operations behind it wait.
    @Test func lockedFileIsGivenUpEventually() async throws {
        #expect(Outbox.shouldRetry(.locked, attempts: 0))
        #expect(Outbox.shouldRetry(.locked, attempts: Outbox.maxLockedAttempts - 2))
        #expect(!Outbox.shouldRetry(.locked, attempts: Outbox.maxLockedAttempts - 1))
        #expect(Outbox.shouldRetry(.offline, attempts: 1000))
        #expect(!Outbox.shouldRetry(.forbidden(message: nil), attempts: 0))

        server.statusOverride.withLock { $0 = { $0.kind == .delete ? 423 : nil } }
        let outbox = outbox(retryDelay: 0)
        try await outbox.enqueue([.delete(fileId: 1, path: "/Photos/a.jpg"), .favorite(fileId: 2, path: "/Photos/b.jpg", value: true)])
        await outbox.waitUntilIdle()
        #expect(try await outbox.pendingCount() == 0)
        #expect(try await outbox.failedOperations().map(\.operation) == [.delete(fileId: 1, path: "/Photos/a.jpg")])
        #expect(server.requests(.delete).count == Outbox.maxLockedAttempts)
        #expect(server.file(2)?.favorite == true)
        #expect(try library.item(1) != nil)  // still on the server, so it is shown again
    }

    // MARK: Failed and discarded operations (5)

    @Test func refusedDeleteBringsThePhotoBack() async throws {
        server.statusOverride.withLock { $0 = { $0.kind == .delete ? 403 : nil } }
        let outbox = outbox()
        try await outbox.enqueue([.delete(fileId: 1, path: "/Photos/a.jpg")])
        #expect(try library.item(1) == nil)  // optimistic
        await outbox.waitUntilIdle()
        #expect(try await outbox.failedOperations().count == 1)
        #expect(try library.item(1) != nil)
        #expect(try library.item(1)?.etag == "e1")

        // "Retry" applies the change again and, once the server allows it, it sticks.
        server.statusOverride.withLock { $0 = nil }
        try await outbox.retryFailed()
        #expect(try library.item(1) == nil)
        await outbox.waitUntilIdle()
        #expect(try await outbox.pendingCount() == 0)
        #expect(server.file(1) == nil)
        #expect(try library.item(1) == nil)
    }

    @Test func refusedFavouriteAndArchiveAreUndone() async throws {
        server.statusOverride.withLock { $0 = { $0.kind == .proppatch || $0.kind == .move ? 403 : nil } }
        let outbox = outbox()
        try await outbox.enqueue([.favorite(fileId: 1, path: "/Photos/a.jpg", value: true), .archive(fileId: 2, path: "/Photos/b.jpg")])
        #expect(try library.item(1)?.isFavorite == true)
        #expect(try library.item(2)?.isArchived == true)
        await outbox.waitUntilIdle()
        #expect(try await outbox.failedOperations().count == 2)
        #expect(try library.item(1)?.isFavorite == false)
        #expect(try library.item(2)?.isArchived == false)
    }

    /// Without a connection to the sync engine (or when the fetch fails) the next sync restores the row.
    @Test func nextSyncRestoresWhatCouldNotBeRestoredAtOnce() async throws {
        await engine.sync()
        server.statusOverride.withLock { $0 = { $0.kind == .delete ? 403 : nil } }
        let outbox = outbox(restoring: false)
        try await outbox.enqueue([.delete(fileId: 1, path: "/Photos/a.jpg")])
        await outbox.waitUntilIdle()
        #expect(try await outbox.failedOperations().count == 1)
        #expect(try library.item(1) == nil)

        server.clearRequests()
        await engine.sync()  // nothing changed on the server: no delta, no reconciliation
        #expect(server.requests(.indexByModified).isEmpty)
        #expect(try library.item(1) != nil)
        #expect(try database.syncValue(SyncEngine.Key.restoreFileIds) == nil)
    }

    /// A failed operation whose file is gone from the server: the row goes too.
    @Test func restoreRemovesRowsOfFilesTheServerNoLongerHas() async throws {
        try await database.writer.write { db in try SyncEngine.requestRestore([1, 2], db: db) }
        server.delete(2)
        try await engine.restoreRows()
        #expect(try library.item(1) != nil)
        #expect(try library.item(2) == nil)
    }

    @Test func discardBringsTheRowBack() async throws {
        // A failed delete as an earlier version left it: the row gone, the operation failed.
        let payload = String(decoding: try JSONEncoder().encode(PendingOperation.delete(fileId: 1, path: "/Photos/a.jpg")), as: UTF8.self)
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM media WHERE fileId = 1")
            try db.execute(
                sql: "INSERT INTO operation(kind, payload, state, createdAt) VALUES ('delete', ?, 'failed', 0)", arguments: [payload])
        }
        let outbox = outbox()
        #expect(try await outbox.failedOperations().count == 1)
        try await outbox.discardFailed()
        #expect(try await outbox.failedOperations().isEmpty)
        #expect(try library.item(1) != nil)
    }
}
