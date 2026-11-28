// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import Synchronization
import Testing

@testable import PhotosModel
@testable import PhotosNetworking
@testable import PhotosStore

/// The targeted walk (SPEC §22.4.2): only folders whose recursive ETag changed are listed, and what it finds is what a
/// walk through the whole library finds.
@Suite(.serialized, .timeLimit(.minutes(2))) struct TargetedSyncTests {
    let server = FakeDAVServer()
    let database: AccountDatabase
    let library: LibraryStore
    let features = ServerFeatures(serverVersion: ServerVersion(major: 36))

    init() throws {
        database = try AccountDatabase.temporary()
        library = LibraryStore(database: database)
    }

    func engine(reconcileInterval: TimeInterval = 600, confirmationDelay: TimeInterval = 0) -> SyncEngine {
        SyncEngine(
            api: server.api, database: database, features: features, reconcileInterval: reconcileInterval,
            massDeleteConfirmationDelay: confirmationDelay)
    }

    func file(_ id: FileID, _ path: String, time: Double = 1000) -> FakeDAVServer.File {
        FakeDAVServer.File(id: id, path: path, etag: "e\(id)", modified: time + Double(id), captured: time + Double(id))
    }

    /// Two years of months with three photos each, and a few at the top.
    func fillMonths() {
        server.state.withLock { state in
            var id: FileID = 1
            for year in [2023, 2024] {
                for month in 1...12 {
                    for n in 0..<3 {
                        state.files[id] = file(id, String(format: "/Photos/%d/%02d/IMG_%d.jpg", year, month, n))
                        id += 1
                    }
                }
            }
            for n in 0..<3 {
                state.files[id] = file(id, "/Photos/top-\(n).jpg")
                id += 1
            }
            FakeDAVServer.bumpRoot(&state)
        }
    }

    func ids() throws -> [FileID] { try library.gridItems(.all).map(\.fileId).sorted() }

    /// The server's timeline as the index should have it: file id → path and ETag.
    func serverIndex() -> [FileID: [String]] {
        server.state.withLock { state in
            Dictionary(uniqueKeysWithValues: state.files.values.filter { $0.mime == "image/jpeg" }.map { ($0.id, [$0.path, $0.etag]) })
        }
    }

    func localIndex() throws -> [FileID: [String]] {
        try database.writer.read { db in
            Dictionary(
                uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT fileId, path, etag FROM media").map { row in
                    (row[0] as FileID, [row[1] as String, row[2] as String])
                })
        }
    }

    var listedFolders: [String] { server.requests(.listing).map(\.path) }

    /// A launch after the first sync: the walk the initial sync owes is a full one; it stores the folder tree.
    func firstLaunch(_ engine: SyncEngine) async throws {
        await engine.sync(reconcile: .opened)
        #expect(!server.requests(.indexByModified).isEmpty)
        #expect(server.requests(.folders).count == 1)
        #expect(try database.syncValue(SyncEngine.Key.folderTree) == "/Photos")
        server.clearRequests()
    }

    // MARK: What is listed

    /// A delete in one month lists the root, the year and that month: three folders of 27, no walk through the library.
    @Test func onlyTheFoldersAboveAChangeAreListed() async throws {
        fillMonths()
        let engine = engine()
        try await firstLaunch(engine)

        server.delete(40)  // /Photos/2024/02/IMG_0.jpg
        await engine.sync(reconcile: .opened)
        #expect(try library.item(40) == nil)
        #expect(try library.count() == 74)
        #expect(listedFolders.sorted() == ["/Photos", "/Photos/2024", "/Photos/2024/02"])
        #expect(server.requests(.indexByModified).isEmpty)
        // The one missing row is asked for by id before it goes (`verifyGone`); nothing else is fetched.
        let fetched: [[FileID]] = server.requests.compactMap { if case .byIds(let ids) = $0.kind { ids } else { nil } }
        #expect(fetched == [[40]])
        // Favourites still arrive (they change no ETag).
        #expect(server.requests(.favorites).count == 1)

        // Nothing changed since: the root's ETag is the stored one, nothing is listed.
        server.clearRequests()
        await engine.sync(reconcile: .opened)
        #expect(listedFolders.isEmpty)
    }

    /// Moves between months, a renamed and a removed folder, an edit and new photos in a new folder, all at once.
    @Test func movesRenamesAndRemovedFoldersArrive() async throws {
        fillMonths()
        let engine = engine()
        try await firstLaunch(engine)

        server.state.withLock { state in
            state.files[2]?.path = "/Photos/2024/12/moved.jpg"  // from 2023/01
            for (id, file) in state.files where file.path.hasPrefix("/Photos/2023/05/") {
                state.files[id]?.path = file.path.replacingOccurrences(of: "/2023/05/", with: "/2023/Mai/")
            }
            state.files = state.files.filter { !$0.value.path.hasPrefix("/Photos/2024/07/") }
            state.files[60]?.etag = "edited"  // 2024/08
            state.files[100] = file(100, "/Photos/New/a.jpg")
            state.files[101] = file(101, "/Photos/New/Deeper/b.jpg")
            FakeDAVServer.bumpRoot(&state)
        }
        await engine.sync(reconcile: .opened)
        #expect(try localIndex() == serverIndex())
        #expect(server.requests(.indexByModified).isEmpty)
        // 2024/09–11 and 2023/02–04, 06–12 did not change and were not listed.
        #expect(!listedFolders.contains("/Photos/2024/09"))
        #expect(listedFolders.contains("/Photos/2024/08"))
        #expect(!listedFolders.contains("/Photos/2023/02"))
        #expect(listedFolders.contains("/Photos/New/Deeper"))
    }

    /// Folder names with letters of several code points (a flag, a decomposed umlaut) are cut where SQLite cuts them.
    @Test func foldersWithAnyNameAreFollowed() async throws {
        let flag = "/Photos/Reise 🇩🇪 Mu\u{0308}nchen"
        server.state.withLock { state in
            state.files[1] = file(1, flag + "/a.jpg")
            state.files[2] = file(2, flag + "/Tag 1/b.jpg")
            state.files[3] = file(3, "/Photos/Ä/c.jpg")
            FakeDAVServer.bumpRoot(&state)
        }
        let engine = engine()
        try await firstLaunch(engine)
        server.state.withLock { state in
            state.files[1] = nil
            state.files[2]?.path = "/Photos/Ä/b.jpg"
            FakeDAVServer.bumpRoot(&state)
        }
        await engine.sync(reconcile: .opened)
        #expect(try localIndex() == serverIndex())
    }

    /// Random changes, round after round, always end in the index a full walk would give.
    @Test func randomChangesMatchTheServerEveryTime() async throws {
        let engine = engine(reconcileInterval: 0)
        var generator = SystemRandomNumberGenerator()
        let seed = UInt64.random(in: 0..<UInt64.max, using: &generator)
        var random = SplitMix(state: seed)
        let folders = ["/Photos", "/Photos/A", "/Photos/A/x", "/Photos/A/y", "/Photos/B", "/Photos/B/x", "/Photos/C/z/deep"]
        server.state.withLock { state in
            for id in FileID(1)...120 { state.files[id] = file(id, "\(folders[Int(id) % folders.count])/\(id).jpg") }
            FakeDAVServer.bumpRoot(&state)
        }
        try await firstLaunch(engine)
        var nextId: FileID = 1000
        var listings = 0
        for round in 0..<40 {
            server.state.withLock { state in
                for _ in 0..<(1 + random.int(4)) {
                    let existing = state.files.keys.sorted()
                    guard !existing.isEmpty else { break }
                    let some = existing[random.int(existing.count)]
                    switch random.int(7) {
                    case 0:
                        nextId += 1
                        state.files[nextId] = file(nextId, "\(folders[random.int(folders.count)])/n\(nextId).jpg", time: 5000)
                    case 1: state.files[some] = nil
                    case 2: state.files[some]?.path = "\(folders[random.int(folders.count)])/m\(some).jpg"
                    case 3: state.files[some]?.etag = "e\(some)-\(round)"
                    case 4:
                        // A folder renamed: everything below it moves.
                        let from = folders[1 + random.int(folders.count - 1)]
                        let to = from + "-r\(round)"
                        for (id, file) in state.files where file.path.hasPrefix(from + "/") {
                            state.files[id]?.path = to + file.path.dropFirst(from.count)
                        }
                    case 5:
                        // A small folder removed (renamed folders included).
                        let paths = Set(state.files.values.map { ($0.path as NSString).deletingLastPathComponent }).sorted()
                        let folder = paths[random.int(paths.count)]
                        if folder != "/Photos", state.files.values.filter({ $0.path.hasPrefix(folder + "/") }).count <= 12 {
                            state.files = state.files.filter { !$0.value.path.hasPrefix(folder + "/") }
                        }
                    default:
                        // Something that is not in the timeline.
                        nextId += 1
                        var other = file(nextId, "\(folders[random.int(folders.count)])/notes\(nextId).pdf")
                        other.mime = "application/pdf"
                        state.files[nextId] = other
                    }
                }
                FakeDAVServer.bumpRoot(&state)
            }
            await engine.sync(reconcile: .opened)
            #expect(try localIndex() == serverIndex(), "seed \(seed), round \(round)")
            #expect(server.requests(.indexByModified).isEmpty, "seed \(seed), round \(round)")
            listings += server.requests(.listing).count
            server.clearRequests()
        }
        #expect(try database.syncValue(SyncEngine.Key.suspectedMassDelete) == nil)
        print("PERF random targeted walks: \(listings) listings in 40 rounds (seed \(seed))")
    }

    // MARK: Interruptions and failures

    /// A targeted walk cut off half-way goes on from its queue: the folders it listed are not listed again.
    @Test func interruptedWalkResumesFromItsQueue() async throws {
        fillMonths()
        let engine = engine()
        try await firstLaunch(engine)
        server.delete(5)  // 2023/02
        server.delete(70)  // 2024/12
        server.gate.withLock {
            $0 = { request in
                if request.kind == .listing, request.path == "/Photos/2024" { try? await Task.sleep(for: .seconds(60)) }
            }
        }
        let task = Task { await engine.sync(reconcile: .opened) }
        #expect(await eventually { listedFolders.contains("/Photos/2024") })
        task.cancel()
        await task.value
        server.gate.withLock { $0 = nil }
        #expect(try database.syncValue(SyncEngine.Key.targetedWalk) == "/Photos")
        #expect(try library.count() == 75)

        server.clearRequests()
        await engine.sync()  // any next sync goes on
        #expect(!listedFolders.contains("/Photos"))
        #expect(listedFolders.contains("/Photos/2024"))
        #expect(try library.item(5) == nil)
        #expect(try library.item(70) == nil)
        #expect(try library.count() == 73)
        #expect(try database.syncValue(SyncEngine.Key.targetedWalk) == nil)
        #expect(try await database.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncFolderQueue") } == 0)
    }

    /// A folder that cannot be listed (an external storage that is not there) loses nothing, and is listed again by the
    /// next walk, also though its parents did not change any more.
    @Test func folderThatCannotBeListedIsListedAgain() async throws {
        server.state.withLock { state in
            for id in FileID(1)...5 { state.files[id] = file(id, "/Photos/Ext/\(id).jpg") }
            for id in FileID(6)...10 { state.files[id] = file(id, "/Photos/Own/\(id).jpg") }
            FakeDAVServer.bumpRoot(&state)
        }
        let engine = engine()
        try await firstLaunch(engine)
        server.state.withLock { state in
            state.unavailable = ["/Photos/Ext"]
            state.files[1] = nil
            state.files[6] = nil
            FakeDAVServer.bumpRoot(&state)
        }
        await engine.sync(reconcile: .opened)
        #expect(try ids() == [1, 2, 3, 4, 5, 7, 8, 9, 10])
        #expect(try database.syncValue(SyncEngine.Key.reconcileOwed) == "1")

        // Back, and nothing changed since: the walk the failure owes lists it, and finds the delete.
        server.state.withLock { $0.unavailable = [] }
        server.clearRequests()
        await engine.sync(reconcile: .opened)
        #expect(listedFolders.contains("/Photos/Ext"))
        #expect(try ids() == [2, 3, 4, 5, 7, 8, 9, 10])
        #expect(try database.syncValue(SyncEngine.Key.reconcileOwed) == nil)
    }

    /// Most of the library gone from one folder: kept until a full walk confirms, also while targeted walks go on.
    @Test func massRemovalWaitsForTheConfirmingFullWalk() async throws {
        server.state.withLock { state in
            for id in FileID(1)...30 { state.files[id] = file(id, "/Photos/Trip/\(id).jpg") }
            for id in FileID(31)...40 { state.files[id] = file(id, "/Photos/Home/\(id).jpg") }
            FakeDAVServer.bumpRoot(&state)
        }
        let engine = engine(confirmationDelay: 3600)
        try await firstLaunch(engine)
        server.state.withLock { state in
            for id in FileID(1)...25 { state.files[id] = nil }
            FakeDAVServer.bumpRoot(&state)
        }
        await engine.sync(reconcile: .opened)
        #expect(try library.count() == 40)
        #expect(try database.syncValue(SyncEngine.Key.suspectedMassDelete) != nil)

        // Another change before the confirmation is due: a targeted walk, which keeps the suspects.
        server.delete(40)
        server.clearRequests()
        await engine.sync(reconcile: .opened)
        #expect(try library.item(40) == nil)
        #expect(try library.count() == 39)
        #expect(server.requests(.indexByModified).isEmpty)
        #expect(try database.syncValue(SyncEngine.Key.suspectedMassDelete) != nil)

        // An hour later: the confirming walk is a full one.
        try database.setSyncValue(SyncEngine.Key.suspectedMassDelete, String(Date().timeIntervalSince1970 - 3601))
        server.clearRequests()
        await engine.sync(reconcile: .opened)
        #expect(!server.requests(.indexByModified).isEmpty)
        #expect(try ids() == Array(26...39))
    }

    // MARK: Full walks

    /// What changes no ETag (a place filled in late) still arrives with the daily full walk.
    @Test func fullWalkStillRunsOnceADay() async throws {
        fillMonths()
        let engine = engine()
        try await firstLaunch(engine)
        server.setMetadata(10, place: "Lisboa", caption: nil)
        await engine.sync(reconcile: .opened)
        #expect(try library.item(10)?.place == nil)

        try database.setSyncValue(SyncEngine.Key.lastFullReconcile, String(Date().timeIntervalSince1970 - 25 * 3600))
        server.clearRequests()
        await engine.sync(reconcile: .opened)
        #expect(!server.requests(.indexByModified).isEmpty)
        #expect(try library.item(10)?.place == "Lisboa")
        // "Sync now" is a full walk too.
        server.clearRequests()
        await engine.sync(reconcile: .now)
        #expect(!server.requests(.indexByModified).isEmpty)
        #expect(listedFolders.isEmpty)
    }

    /// A server that does not answer the folder SEARCH gets no tree: every walk stays a full one, as before.
    @Test func withoutTheFolderSearchEveryWalkIsFull() async throws {
        fillMonths()
        server.statusOverride.withLock { $0 = { $0.kind == .folders ? 400 : nil } }
        let engine = engine()
        await engine.sync(reconcile: .opened)
        #expect(try database.syncValue(SyncEngine.Key.folderTree) == nil)
        server.delete(3)
        server.clearRequests()
        await engine.sync(reconcile: .opened)
        #expect(try library.item(3) == nil)
        #expect(!server.requests(.indexByModified).isEmpty)
        #expect(listedFolders.isEmpty)
    }

    /// A walk under way when the app is updated is a full one; the stored tree of other roots is not used.
    @Test func otherRootsMeanAFullWalk() async throws {
        fillMonths()
        let engine = engine()
        try await firstLaunch(engine)
        #expect(try await engine.canWalkTargeted(folders: ["/Photos"]))
        #expect(try await !engine.canWalkTargeted(folders: ["/Photos", "/Camera"]))
        #expect(try await engine.walk(for: .refresh, folders: ["/Photos"], owed: false) == .full)
        #expect(try await engine.walk(for: .refresh, folders: ["/Photos"], owed: true) == .targeted)
        #expect(try await engine.walk(for: .now, folders: ["/Photos"], owed: true) == .full)
    }
}

/// Nextcloud answers a SEARCH without a limit with 100 results (`FileSearchBackend`, the fake does the same): the
/// searches that must be complete ask for more.
@Suite(.serialized, .timeLimit(.minutes(2))) struct SearchLimitTests {
    let server = FakeDAVServer()
    let database: AccountDatabase
    let library: LibraryStore

    init() throws {
        database = try AccountDatabase.temporary()
        library = LibraryStore(database: database)
    }

    func engine() -> SyncEngine {
        SyncEngine(
            api: server.api, database: database, features: ServerFeatures(serverVersion: ServerVersion(major: 36)), reconcileInterval: 600)
    }

    func file(_ id: FileID, time: Double, favorite: Bool = false) -> FakeDAVServer.File {
        var file = FakeDAVServer.File(id: id, path: "/Photos/\(id).jpg", etag: "e\(id)", modified: time, captured: time)
        file.favorite = favorite
        return file
    }

    /// 150 favourites: none loses its flag at the next sync.
    @Test func moreThanAHundredFavouritesStay() async throws {
        server.state.withLock { state in
            for id in FileID(1)...200 { state.files[id] = file(id, time: 1000 + Double(id), favorite: id <= 150) }
            FakeDAVServer.bumpRoot(&state)
        }
        let engine = engine()
        await engine.sync()
        await engine.sync()  // no change: the favourites SEARCH
        #expect(try library.gridItems(.favorites).count == 150)
    }

    /// 300 photos added elsewhere arrive with the next sync's delta, not 100 of them.
    @Test func moreThanAHundredChangesArriveAtOnce() async throws {
        server.put(file(1, time: 1000))
        let engine = engine()
        await engine.sync()
        let now = Date().timeIntervalSince1970
        server.state.withLock { state in
            for id in FileID(2)...301 { state.files[id] = file(id, time: now + Double(id)) }
            FakeDAVServer.bumpRoot(&state)
        }
        await engine.sync()  // a plain sync: within the interval, no walk
        #expect(try library.count() == 301)
    }

    /// 300 files with the same modification and capture second (a folder unpacked at once) where a page ends: all
    /// indexed, and a walk through the library keeps them all.
    @Test func moreThanAHundredFilesInOneSecond() async throws {
        server.state.withLock { state in
            for id in FileID(1)...300 { state.files[id] = file(id, time: 5000) }
            for id in FileID(301)...2250 { state.files[id] = file(id, time: 6000 + Double(id)) }
            FakeDAVServer.bumpRoot(&state)
        }
        let engine = engine()
        await engine.sync()
        #expect(try library.count() == 2250)
        await engine.sync(reconcile: .now)
        #expect(try library.count() == 2250)
    }
}

/// SplitMix64, for reproducible random rounds (the seed is printed when a round fails).
struct SplitMix {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ upperBound: Int) -> Int { Int(next() % UInt64(upperBound)) }
}
