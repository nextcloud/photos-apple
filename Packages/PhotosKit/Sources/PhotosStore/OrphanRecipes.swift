// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import PhotosModel
import PhotosNetworking

/// Edit recipes of photos that are gone for good (SPEC §22.5.3).
///
/// A recipe stays when its photo is deleted, so that restoring it from the trash bin brings its edit back (§16.3.1).
/// After a completed full reconcile the recipes are looked at (at most once a day) and one is removed only when all of
/// this holds:
/// 1. its photo is not in the library's index,
/// 2. the server knows no file with its file id anywhere in the user's files (a SEARCH over the whole tree, so a photo
///    moved out of the timeline folders, into a shared or a group folder keeps its recipe),
/// 3. the file id is not in the trash bin (also not inside a trashed folder),
/// 4. and this was already so at a look at least `grace` (30 days) earlier.
/// Every look must prove that it can see: the SEARCH includes a file id the index has (the canary) and must find it;
/// any error, an unreadable trash bin or a missing canary skips the round and removes nothing.
public enum OrphanRecipes {
    /// How long a recipe must have been seen orphaned (at two looks) before it is removed.
    public static let grace: TimeInterval = 30 * 86_400
    /// The shortest time between two looks.
    public static let interval: TimeInterval = 86_400

    /// Why a look removed nothing.
    public enum Failure: Error, Equatable {
        /// The SEARCH did not find the canary: it cannot be trusted to tell what is gone.
        case canaryMissing
        /// The trash bin holds more folders than one look reads.
        case trashTooLarge
    }

    /// What one look decided.
    public struct Plan: Equatable, Sendable {
        /// Recipes to remove now.
        public var remove: Set<FileID> = []
        /// Recipes seen orphaned, with the time they were first seen so (kept for the next look).
        public var marks: [FileID: Date] = [:]

        public init(remove: Set<FileID> = [], marks: [FileID: Date] = [:]) {
            self.remove = remove
            self.marks = marks
        }
    }

    /// The decision of one look. `candidates` are the recipes whose photo is not in the index; `existing` and `trashed`
    /// what the server said about them; `marks` the previous look's.
    public static func plan(
        candidates: Set<FileID>, existing: Set<FileID>, trashed: Set<FileID>, marks: [FileID: Date], now: Date, grace: TimeInterval = grace
    ) -> Plan {
        var plan = Plan()
        for fileId in candidates where !existing.contains(fileId) && !trashed.contains(fileId) {
            let since = marks[fileId] ?? now
            if now.timeIntervalSince(since) >= grace {
                plan.remove.insert(fileId)
            } else {
                plan.marks[fileId] = since
            }
        }
        return plan
    }
}

/// What the server knows about some file ids (`OrphanRecipes`); a protocol so the rules can be tested without a server.
public protocol OrphanRecipeProbe: Sendable {
    /// Which of `fileIds` are files the user can reach anywhere in their files. Throws when it cannot tell.
    func existing(_ fileIds: [FileID]) async throws -> Set<FileID>
    /// Every file id in the user's trash bin, also inside trashed folders. Throws when it cannot tell.
    func trashed() async throws -> Set<FileID>
}

/// The probe against Nextcloud: SEARCH by file id over the user's whole tree, and the trash bin's listing.
public struct ServerOrphanProbe: OrphanRecipeProbe {
    public let api: PhotosAPI
    /// A file id the index has, put into every SEARCH; when the answer lacks it, the SEARCH is not trusted.
    public let canary: FileID
    /// The most trashed folders a look reads when the server does not list the trash bin in depth.
    public static let trashFolderLimit = 300

    public init(api: PhotosAPI, canary: FileID) {
        self.api = api
        self.canary = canary
    }

    public func existing(_ fileIds: [FileID]) async throws -> Set<FileID> {
        var found: Set<FileID> = []
        let connection = api.dav.connection
        // One place in each SEARCH is the canary's.
        for chunk in fileIds.chunked(PhotosAPI.cameraDetailsBatch - 1) {
            let ids = Array(chunk) + [canary]
            let search = DAVSearch(
                select: [DAVProp.fileId], scopes: [DAVSearch.Scope(href: connection.filesHref("/"))],
                condition: .or(ids.map { .eq(DAVProp.fileId, String($0)) }), limit: ids.count + 10)
            var answer: Set<FileID> = []
            for resource in try await api.dav.search(search, timeout: 120) {
                if let fileId = resource.int64(DAVProp.fileId) { answer.insert(fileId) }
            }
            guard answer.contains(canary) else { throw OrphanRecipes.Failure.canaryMissing }
            found.formUnion(answer.intersection(chunk))
        }
        return found
    }

    public func trashed() async throws -> Set<FileID> {
        let root = api.dav.connection.davURL("trashbin/\(api.dav.connection.userId)/trash/")
        do {
            let listing = try await api.dav.propfind(
                root, depth: DAVClient.infiniteDepth, properties: [DAVProp.fileId, DAVProp.resourceType])
            return Set(listing.compactMap { $0.int64(DAVProp.fileId) })
        } catch NetworkError.notFound {
            // No trash bin (the app is disabled): deleted files are gone at once.
            return []
        } catch {
            // Not listed in depth: folder by folder.
        }
        var result: Set<FileID> = []
        var folders = [root]
        var read = 0
        while let folder = folders.popLast() {
            read += 1
            guard read <= Self.trashFolderLimit else { throw OrphanRecipes.Failure.trashTooLarge }
            let listing = try await api.dav.propfind(folder, depth: 1, properties: [DAVProp.fileId, DAVProp.resourceType])
            for resource in listing.dropFirst() {
                if let fileId = resource.int64(DAVProp.fileId) { result.insert(fileId) }
                if resource.isCollection, let url = URL(string: resource.rawHref, relativeTo: folder)?.absoluteURL { folders.append(url) }
            }
        }
        return result
    }
}

extension LibraryStore {
    /// Which of `fileIds` the index has.
    public func indexedFileIds(among fileIds: Set<FileID>) throws -> Set<FileID> {
        guard !fileIds.isEmpty else { return [] }
        return try database.writer.read { db in
            var result: Set<FileID> = []
            for chunk in Array(fileIds).chunked(500) {
                let list = chunk.map { String($0) }.joined(separator: ",")
                result.formUnion(try FileID.fetchAll(db, sql: "SELECT fileId FROM media WHERE fileId IN (\(list))"))
            }
            return result
        }
    }

    /// A file of the user's own that the index has, for `ServerOrphanProbe`'s canary: the most recently changed one.
    public func canaryFileId() throws -> FileID? {
        try database.writer.read { db in
            try FileID.fetchOne(db, sql: "SELECT fileId FROM media ORDER BY modifiedAt DESC LIMIT 1")
        }
    }
}

extension SyncEngine {
    /// `action` runs at the end of every completed full reconcile (the orphaned edit recipes, SPEC §22.5.3).
    public func setAfterFullReconcile(_ action: (@Sendable () async -> Void)?) {
        afterFullReconcile = action
    }
}
