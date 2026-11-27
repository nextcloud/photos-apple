// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import PhotosModel
import PhotosNetworking

/// The folder tree the targeted walk compares with (SPEC §22.4.2). Tables of their own, like the full walk's: a walk
/// never writes `media` just to remember where it is.
enum FolderTree {
    static func migrate(_ db: Database) throws {
        // The folders below the timeline's roots as the index last agreed with them, with their recursive ETags. A NULL
        // ETag: list it again (a listing below it failed).
        try db.create(table: "syncFolder") { t in
            t.primaryKey("path", .text)
            t.column("etag", .text)
        }
        // The folder tree read when a full walk began; it becomes `syncFolder` when that walk is through.
        try db.create(table: "syncFolderSnapshot") { t in
            t.primaryKey("path", .text)
            t.column("etag", .text).notNull()
        }
        // A targeted walk under way: the folders it still has to list, with the ETag the listing above them showed.
        try db.create(table: "syncFolderQueue") { t in
            t.primaryKey("path", .text)
            t.column("etag", .text)
        }
        // Rows a targeted walk found missing so far; removed (through the mass-delete guard) when the walk is through.
        try db.create(table: "syncFolderMissing") { t in t.primaryKey("fileId", .integer) }
    }
}

extension SyncEngine.Key {
    /// The roots (`|`-separated) the stored folder tree (`syncFolder`) belongs to; nil while there is none.
    static let folderTree = "folderTree"
    /// The roots of the full walk the snapshot (`syncFolderSnapshot`) was taken for.
    static let folderSnapshot = "folderSnapshot"
    /// A targeted walk is under way: its roots. The folders still to list are in `syncFolderQueue`.
    static let targetedWalk = "targetedWalk"
    /// "1" when a listing of the targeted walk under way failed: the walk owes another one.
    static let targetedIncomplete = "targetedIncomplete"
    /// When the last full walk (`reconcile(folders:roots:)`) was through.
    static let lastFullReconcile = "lastFullReconcile"
}

extension SyncEngine {
    /// How a due reconciliation finds deletes and moves (SPEC §22.4.2).
    enum Walk: Equatable {
        /// Everything, by modification time (`reconcile(folders:roots:)`): also what changes no ETag (place, caption).
        case full
        /// Only the folders whose recursive ETag changed (`targetedReconcile(roots:)`).
        case targeted
    }

    /// The longest time without a full walk: the safety net for what changes no ETag (late place or caption of older
    /// photos, storages that do not tell their parents about changes).
    static let fullWalkInterval: TimeInterval = 24 * 3600

    /// A targeted walk can run: a folder tree for these roots is stored, no full walk is under way, no removal waits for
    /// its confirming listing, and the last full walk is less than a day ago.
    func canWalkTargeted(folders: [String], now: Double = Date().timeIntervalSince1970) throws -> Bool {
        let key = folders.joined(separator: "|")
        guard !folders.isEmpty, try database.syncValue(Key.folderTree) == key, try database.syncValue(Key.reconcileWalk) == nil
        else { return false }
        if let suspectedAt = try database.syncValue(Key.suspectedMassDelete).flatMap(Double.init),
            now - suspectedAt >= massDeleteConfirmationDelay
        {
            // The confirming listing must look at every suspect, also those in folders that did not change since.
            return false
        }
        return now - (try lastFullWalk()) < Self.fullWalkInterval
    }

    /// When the last full walk was through (before round 12 every walk was one).
    func lastFullWalk() throws -> Double {
        try (database.syncValue(Key.lastFullReconcile) ?? database.syncValue(Key.lastReconcile)).flatMap(Double.init) ?? 0
    }

    /// Which walk a due reconciliation makes. "Sync now" and pull-to-refresh without a changed ETag look at everything.
    func walk(for request: ReconcileRequest, folders: [String], owed: Bool) throws -> Walk {
        if request == .now || (request == .refresh && !owed) { return .full }
        return try canWalkTargeted(folders: folders) ? .targeted : .full
    }

    // MARK: Snapshot of the folder tree (full walk)

    /// Reads every folder below the roots before a full walk begins. What changes during the walk then shows up as a
    /// changed ETag at the next targeted walk instead of being missed. A server that does not answer the folder SEARCH
    /// gets no tree, and every walk stays a full one.
    func snapshotFolders(_ roots: [Root], walk: String) async throws {
        var entries: [String: String] = [:]
        do {
            for root in roots {
                try Task.checkCancellation()
                // A root without an ETag is listed again by the first targeted walk.
                if let etag = root.etag { entries[root.folder] = etag }
                for folder in try await api.folders(below: root.folder) where !folder.etag.isEmpty {
                    entries[folder.path] = folder.etag
                }
            }
        } catch let error as NetworkError where error == .offline || error == .timedOut || error == .cancelled {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.notice("sync: no folder tree (\(error.localizedDescription, privacy: .public)); walks stay full ones")
            try await database.writer.write { db in
                try db.execute(sql: "DELETE FROM syncFolderSnapshot")
                try Self.setValues([Key.folderSnapshot: nil], db: db)
            }
            return
        }
        try await database.writer.write { [entries] db in
            try db.execute(sql: "DELETE FROM syncFolderSnapshot")
            for (path, etag) in entries {
                try db.execute(sql: "INSERT INTO syncFolderSnapshot(path, etag) VALUES (?, ?)", arguments: [path, etag])
            }
            try Self.setValues([Key.folderSnapshot: walk], db: db)
        }
    }

    /// A full walk is through: its snapshot becomes the folder tree, and a targeted walk that was under way is void.
    static func finishFullWalk(walk: String, now: Double, db: Database) throws {
        let snapshot = try String.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = ?", arguments: [Key.folderSnapshot])
        try db.execute(sql: "DELETE FROM syncFolder")
        if snapshot == walk {
            try db.execute(sql: "INSERT INTO syncFolder(path, etag) SELECT path, etag FROM syncFolderSnapshot")
        }
        try db.execute(sql: "DELETE FROM syncFolderSnapshot")
        try db.execute(sql: "DELETE FROM syncFolderQueue")
        try db.execute(sql: "DELETE FROM syncFolderMissing")
        try setValues(
            [
                Key.folderTree: snapshot == walk ? walk : nil, Key.folderSnapshot: nil, Key.targetedWalk: nil, Key.targetedIncomplete: nil,
                Key.lastFullReconcile: String(now),
            ], db: db)
    }

    // MARK: Targeted walk

    /// Walks only where something changed: lists the roots whose ETag differs from the stored tree, then, top-down, every
    /// folder whose ETag in its parent's listing differs from the stored one. Unchanged folders (and all below them) are
    /// not looked at. Finds what the full walk finds by ETag: deletes, moves (both folders change), renames, edits,
    /// whole folders removed or moved.
    ///
    /// Resumable like the full walk: each folder is one transaction that stores its new ETag, queues its changed
    /// subfolders and notes the rows it lacks, so a walk cut off at any point goes on from its queue at the next sync.
    /// Nothing is removed before the walk is through, and then only through the mass-delete guard (`applyRemovals`).
    func targetedReconcile(roots: [Root]) async throws {
        let folders = roots.map(\.folder)
        let walk = folders.joined(separator: "|")
        if try database.syncValue(Key.targetedWalk) != walk {
            try await database.writer.write { db in
                try db.execute(sql: "DELETE FROM syncFolderQueue")
                try db.execute(sql: "DELETE FROM syncFolderMissing")
                for root in roots {
                    let stored = try String.fetchOne(db, sql: "SELECT etag FROM syncFolder WHERE path = ?", arguments: [root.folder])
                    if root.etag == nil || stored != root.etag {
                        try db.execute(
                            sql: "INSERT OR REPLACE INTO syncFolderQueue(path, etag) VALUES (?, ?)", arguments: [root.folder, root.etag])
                    }
                }
                try Self.setValues([Key.targetedWalk: walk, Key.targetedIncomplete: nil], db: db)
            }
        }
        publish(.reconciling(itemsChecked: 0))
        let pending = try pendingFileIds()
        var listedFolders = 0
        var checked = 0
        var refreshed = 0
        while let path = try await nextQueuedFolder() {
            try Task.checkCancellation()
            let result = try await walkFolder(path, pending: pending)
            listedFolders += 1
            checked += result.files
            refreshed += result.refreshed
            publish(.reconciling(itemsChecked: checked))
        }
        let removed = try await database.writer.read { db in
            try FileID.fetchAll(db, sql: "SELECT fileId FROM syncFolderMissing WHERE fileId IN (SELECT fileId FROM media)")
        }
        let applied = try await applyRemovals(Set(removed), known: library.count(), folders: folders, keepOtherSuspects: true)
        let incomplete = try database.syncValue(Key.targetedIncomplete) == "1"
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM syncFolderMissing")
            try Self.setValues(
                [
                    Key.targetedWalk: nil, Key.targetedIncomplete: nil, Key.lastReconcile: String(Date().timeIntervalSince1970),
                    // A folder that could not be listed is listed again by the next walk.
                    Key.reconcileOwed: incomplete ? "1" : nil,
                ], db: db)
        }
        logger.info(
            "targeted walk: \(listedFolders) folders listed, \(checked) files, \(applied) of \(removed.count) missing removed, \(refreshed) refreshed\(incomplete ? ", incomplete" : "")"
        )
    }

    func nextQueuedFolder() async throws -> String? {
        try await database.writer.read { db in try String.fetchOne(db, sql: "SELECT path FROM syncFolderQueue LIMIT 1") }
    }

    /// Lists one folder of the targeted walk and records what it found (one transaction).
    func walkFolder(_ path: String, pending: Set<FileID>) async throws -> (files: Int, refreshed: Int) {
        let listing: (etag: String?, children: [SyncFolderEntry])
        do {
            listing = try await api.listFolder(path)
        } catch let error as NetworkError where error == .offline || error == .timedOut || error == .cancelled {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch NetworkError.notFound {
            // Gone since its parent was listed: everything below it is missing (unless another listing meets it).
            try await database.writer.write { db in
                try Self.noteMissing(below: path, db: db)
                try Self.forgetFolders(below: path, includingItself: true, db: db)
                try db.execute(sql: "DELETE FROM syncFolderQueue WHERE path = ?", arguments: [path])
            }
            return (0, 0)
        } catch {
            // Not available (an external storage that is not mounted answers 503): nothing below it counts as missing;
            // it and the folders above it are listed again by the next walk.
            logger.notice("targeted walk: \(path, privacy: .private) not listed (\(error.localizedDescription, privacy: .public))")
            try await database.writer.write { db in
                try Self.invalidate(path, db: db)
                try db.execute(sql: "DELETE FROM syncFolderQueue WHERE path = ?", arguments: [path])
                try Self.setValues([Key.targetedIncomplete: "1"], db: db)
            }
            return (0, 0)
        }
        let mimeTypes = Set(self.mimeTypes)
        let files = listing.children.filter { !$0.isFolder && $0.fileId != nil && mimeTypes.contains($0.mimeType ?? "") }
        let subfolders = listing.children.filter(\.isFolder)
        // Files that are new here or differ from their row (an edit, a rename, a move into this folder): read by id, with
        // everything the index keeps. Fetched before the folder counts as done: a walk cut off here reads them again.
        let ids = files.compactMap(\.fileId)
        let stored = try await Self.listingKeys(ids, database: database)
        let toRefresh = files.filter { file in
            guard let id = file.fileId, !pending.contains(id) else { return false }
            return stored[id].map { $0.etag != file.etag || $0.path != file.path } ?? true
        }.compactMap(\.fileId)
        for chunk in toRefresh.chunked(200) {
            try Task.checkCancellation()
            try library.upsert(try await api.items(fileIds: Array(chunk), properties: indexProperties))
        }
        let own = path
        try await database.writer.write { db in
            // What this listing shows exists, wherever an earlier listing of this walk missed it.
            try Self.markListed(ids, db: db)
            // Rows of files directly in this folder that it does not list any more.
            let listed = Set(ids)
            let direct = try Self.rows(directlyIn: own, db: db)
            try Self.insertMissing(direct.filter { !listed.contains($0) }, db: db)
            // Rows below subfolders that are not there any more (deleted, moved or renamed away).
            let names = Set(subfolders.map { ($0.path as NSString).lastPathComponent })
            for name in try Self.subfolderNames(below: own, db: db) where !names.contains(name) {
                let gone = Self.child(own, name)
                try Self.noteMissing(below: gone, db: db)
                try Self.forgetFolders(below: gone, includingItself: true, db: db)
            }
            // Subfolders that are new or changed are listed next; unchanged ones (and everything below them) are not.
            for folder in subfolders {
                let stored = try String.fetchOne(db, sql: "SELECT etag FROM syncFolder WHERE path = ?", arguments: [folder.path])
                if folder.etag.isEmpty || stored != folder.etag {
                    try db.execute(
                        sql: "INSERT OR REPLACE INTO syncFolderQueue(path, etag) VALUES (?, ?)", arguments: [folder.path, folder.etag])
                }
            }
            // The ETag this listing was made at: a change after it shows up as another ETag at the next walk.
            if let etag = listing.etag, !etag.isEmpty {
                try db.execute(sql: "INSERT OR REPLACE INTO syncFolder(path, etag) VALUES (?, ?)", arguments: [own, etag])
            } else {
                try db.execute(sql: "INSERT OR REPLACE INTO syncFolder(path, etag) VALUES (?, NULL)", arguments: [own])
            }
            try db.execute(sql: "DELETE FROM syncFolderQueue WHERE path = ?", arguments: [own])
        }
        return (files.count, toRefresh.count)
    }

    /// The stored ETag and path of some rows.
    static func listingKeys(_ ids: [FileID], database: AccountDatabase) async throws -> [FileID: (etag: String, path: String)] {
        try await database.writer.read { db in
            var map: [FileID: (etag: String, path: String)] = [:]
            map.reserveCapacity(ids.count)
            for chunk in ids.chunked(500) {
                let sql = "SELECT fileId, etag, path FROM media WHERE fileId IN (\(chunk.map { String($0) }.joined(separator: ",")))"
                for row in try Row.fetchAll(db, sql: sql) { map[row[0]] = (row[1], row[2]) }
            }
            return map
        }
    }

    static func child(_ folder: String, _ name: String) -> String { folder == "/" ? "/" + name : folder + "/" + name }

    /// The bounds of the paths below `folder` for a range scan of the `media_path` index: `folder/` up to `folder0`
    /// (`0` follows `/`).
    static func range(below folder: String) -> (lower: String, upper: String) {
        folder == "/" ? ("/", "0") : (folder + "/", folder + "0")
    }

    static func rows(directlyIn folder: String, db: Database) throws -> [FileID] {
        let (lower, upper) = range(below: folder)
        return try FileID.fetchAll(
            db, sql: "SELECT fileId FROM media WHERE path >= ? AND path < ? AND instr(substr(path, ?), '/') = 0",
            arguments: [lower, upper, start(below: lower)])
    }

    /// Where the rest of a path below `lower` begins, for SQLite's `substr` (which counts code points).
    static func start(below lower: String) -> Int { lower.unicodeScalars.count + 1 }

    /// The names of the first folder level below `folder` that rows of the index or folders of the tree are in.
    static func subfolderNames(below folder: String, db: Database) throws -> [String] {
        let (lower, upper) = range(below: folder)
        let arguments: StatementArguments = [start(below: lower), lower, upper]
        let ofRows = try String.fetchAll(
            db,
            sql: """
                SELECT DISTINCT substr(rest, 1, instr(rest, '/') - 1) FROM (
                    SELECT substr(path, ?) AS rest FROM media WHERE path >= ? AND path < ?
                ) WHERE instr(rest, '/') > 0
                """,
            arguments: arguments)
        let ofFolders = try String.fetchAll(
            db,
            sql: """
                SELECT DISTINCT CASE WHEN instr(rest, '/') > 0 THEN substr(rest, 1, instr(rest, '/') - 1) ELSE rest END FROM (
                    SELECT substr(path, ?) AS rest FROM syncFolder WHERE path >= ? AND path < ?
                )
                """,
            arguments: arguments)
        return Array(Set(ofRows + ofFolders))
    }

    static func noteMissing(below folder: String, db: Database) throws {
        let (lower, upper) = range(below: folder)
        try db.execute(
            sql: "INSERT OR IGNORE INTO syncFolderMissing(fileId) SELECT fileId FROM media WHERE path >= ? AND path < ?",
            arguments: [lower, upper])
    }

    static func insertMissing(_ ids: [FileID], db: Database) throws {
        for id in ids { try db.execute(sql: "INSERT OR IGNORE INTO syncFolderMissing(fileId) VALUES (?)", arguments: [id]) }
    }

    static func markListed(_ ids: [FileID], db: Database) throws {
        for chunk in ids.chunked(500) {
            try db.execute(sql: "DELETE FROM syncFolderMissing WHERE fileId IN (\(chunk.map { String($0) }.joined(separator: ",")))")
        }
    }

    static func forgetFolders(below folder: String, includingItself: Bool, db: Database) throws {
        let (lower, upper) = range(below: folder)
        try db.execute(sql: "DELETE FROM syncFolder WHERE path >= ? AND path < ?", arguments: [lower, upper])
        try db.execute(sql: "DELETE FROM syncFolderQueue WHERE path >= ? AND path < ?", arguments: [lower, upper])
        if includingItself { try db.execute(sql: "DELETE FROM syncFolder WHERE path = ?", arguments: [folder]) }
    }

    /// A folder that could not be listed: it and every folder above it lose their stored ETag, so the next walk does not
    /// stop above it.
    static func invalidate(_ folder: String, db: Database) throws {
        var path = folder
        while true {
            try db.execute(sql: "UPDATE syncFolder SET etag = NULL WHERE path = ?", arguments: [path])
            guard path != "/", !path.isEmpty else { break }
            let parent = (path as NSString).deletingLastPathComponent
            if parent == path { break }
            path = parent
        }
    }
}
