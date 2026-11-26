// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import GRDB
import OSLog
import Photos
import PhotosModel
import PhotosNetworking
import PhotosStore

extension BackupEngine {
    // MARK: Ledger

    struct LedgerKey: Hashable {
        var localIdentifier: String
        var kind: String
    }

    func loadLedger() throws -> [LedgerKey: BackupLedgerEntry] {
        try database.writer.read { db in
            var map: [LedgerKey: BackupLedgerEntry] = [:]
            for entry in try BackupLedgerEntry.fetchAll(db) {
                map[LedgerKey(localIdentifier: entry.localIdentifier, kind: entry.resourceKind)] = entry
            }
            return map
        }
    }

    func ledgerEntries(of localIdentifier: String) throws -> [BackupLedgerEntry] {
        try database.writer.read { db in try BackupLedgerEntry.filter(Column("localIdentifier") == localIdentifier).fetchAll(db) }
    }

    /// Writes what a scan learnt, in one transaction:
    /// - `pending`: entries for new resources (with the resource, so later passes need not read it again);
    /// - `touched`: the new modification date of assets whose resources are all on the server;
    /// - `refreshed`: the resource of an entry that waits, as the library says it now (`modified`: the server is asked again);
    /// - `reopened`: a new edit of something on the server, which waits now;
    /// - `filesMatched`: resources the Files app uploaded.
    func prepareLedger(
        pending: [BackupResource], touched: [BackupResource], refreshed: [(resource: BackupResource, modified: Bool)] = [],
        reopened: [BackupResource] = [], filesMatched: [BackupResource] = []
    ) throws {
        guard !pending.isEmpty || !touched.isEmpty || !refreshed.isEmpty || !reopened.isEmpty || !filesMatched.isEmpty else { return }
        let updatedAt = now().timeIntervalSince1970
        let encoder = JSONEncoder()
        try database.writer.write { db in
            for resource in pending {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO backupAsset(localIdentifier, resourceKind, state, attempts, assetCreatedAt, assetModifiedAt, updatedAt, resource)
                        VALUES (?, ?, ?, 0, ?, ?, ?, ?)
                        """,
                    arguments: [
                        resource.localIdentifier, resource.kind.rawValue, BackupItemState.pending.rawValue,
                        resource.createdAt.timeIntervalSince1970, resource.modifiedAt?.timeIntervalSince1970, updatedAt,
                        resource.json(encoder),
                    ])
            }
            for resource in touched {
                try db.execute(
                    sql: "UPDATE backupAsset SET assetModifiedAt = ? WHERE localIdentifier = ? AND resourceKind = ?",
                    arguments: [resource.modifiedAt?.timeIntervalSince1970, resource.localIdentifier, resource.kind.rawValue])
            }
            for (resource, modified) in refreshed {
                try db.execute(
                    sql: """
                        UPDATE backupAsset SET resource = ?, assetCreatedAt = ?, assetModifiedAt = ?,
                            checkedAt = CASE WHEN ? THEN NULL ELSE checkedAt END
                        WHERE localIdentifier = ? AND resourceKind = ?
                        """,
                    arguments: [
                        resource.json(encoder), resource.createdAt.timeIntervalSince1970, resource.modifiedAt?.timeIntervalSince1970,
                        modified, resource.localIdentifier, resource.kind.rawValue,
                    ])
            }
            for resource in reopened {
                // What is known about the copy on the server stays: the new edit replaces it (`BackupPolicy.action`).
                try db.execute(
                    sql: """
                        UPDATE backupAsset SET state = ?, resource = ?, assetCreatedAt = ?, assetModifiedAt = ?, checkedAt = NULL,
                            attempts = 0, lastError = NULL, updatedAt = ?
                        WHERE localIdentifier = ? AND resourceKind = ?
                        """,
                    arguments: [
                        BackupItemState.pending.rawValue, resource.json(encoder), resource.createdAt.timeIntervalSince1970,
                        resource.modifiedAt?.timeIntervalSince1970, updatedAt, resource.localIdentifier, resource.kind.rawValue,
                    ])
            }
            for resource in filesMatched {
                try Self.record(db, resource, state: .matched, matchedBy: .filesLedger, updatedAt: updatedAt, encoder: encoder)
            }
        }
    }

    func record(
        _ resource: BackupResource, state: BackupItemState, matchedBy: MatchReason? = nil, serverPath: String? = nil,
        serverFileId: FileID? = nil,
        error: String? = nil
    ) throws {
        let updatedAt = now().timeIntervalSince1970
        try database.writer.write { db in
            try Self.record(
                db, resource, state: state, matchedBy: matchedBy, serverPath: serverPath, serverFileId: serverFileId, error: error,
                updatedAt: updatedAt, encoder: JSONEncoder())
        }
    }

    /// Writes the result of one reconciliation batch in one transaction: the matches, and for the others that the
    /// server was asked now (`checkedAt`), so the next passes upload them without asking again.
    func recordCheck(matches: [Match], notFound: [BackupResource]) throws {
        guard !matches.isEmpty || !notFound.isEmpty else { return }
        let updatedAt = now().timeIntervalSince1970
        let encoder = JSONEncoder()
        try database.writer.write { db in
            for match in matches {
                try Self.record(
                    db, match.resource, state: .matched, matchedBy: match.reason, serverPath: match.candidate.path,
                    serverFileId: match.candidate.fileId, updatedAt: updatedAt, encoder: encoder)
            }
            for resource in notFound {
                try db.execute(
                    sql: "UPDATE backupAsset SET checkedAt = ? WHERE localIdentifier = ? AND resourceKind = ?",
                    arguments: [updatedAt, resource.localIdentifier, resource.kind.rawValue])
            }
        }
    }

    private static func record(
        _ db: Database, _ resource: BackupResource, state: BackupItemState, matchedBy: MatchReason? = nil, serverPath: String? = nil,
        serverFileId: FileID? = nil, error: String? = nil, updatedAt: Double, encoder: JSONEncoder
    ) throws {
        let previous = try BackupLedgerEntry.fetchOne(
            db, key: ["localIdentifier": resource.localIdentifier, "resourceKind": resource.kind.rawValue])
        // A failure keeps what is known about the copy on the server; a success starts the retry count again.
        let failed = state == .failed
        let complete = state == .uploaded || state == .matched
        var entry = BackupLedgerEntry(
            localIdentifier: resource.localIdentifier, resourceKind: resource.kind.rawValue,
            fingerprint: failed ? previous?.fingerprint : resource.sizeFingerprint, state: state.rawValue,
            serverPath: serverPath ?? previous?.serverPath, serverFileId: serverFileId ?? previous?.serverFileId, serverEtag: nil,
            matchedBy: matchedBy?.rawValue ?? previous?.matchedBy, attempts: failed ? (previous?.attempts ?? 0) + 1 : 0,
            lastError: error, assetCreatedAt: resource.createdAt.timeIntervalSince1970,
            assetModifiedAt: resource.modifiedAt?.timeIntervalSince1970, updatedAt: updatedAt)
        // What still waits keeps its resource and when the server was asked about it.
        if !complete {
            entry.resource = resource.json(encoder)
            entry.checkedAt = previous?.checkedAt
        }
        try entry.upsert(db)
    }

    /// The counts of the status are those of the ledger: what failed stays "failed" (and not "up to date") until it is
    /// uploaded, also across passes that do not touch it because it waits for its next attempt.
    func refreshCounts() throws {
        let (counts, lastFailure, pendingBytes) = try database.writer.read { db in
            let counts = try Row.fetchAll(db, sql: "SELECT state, count(*) AS n FROM backupAsset GROUP BY state").reduce(
                into: [String: Int]()
            ) {
                $0[$1["state"]] = $1["n"]
            }
            let lastFailure = try String.fetchOne(
                db, sql: "SELECT lastError FROM backupAsset WHERE state = ? AND lastError IS NOT NULL ORDER BY updatedAt DESC LIMIT 1",
                arguments: [BackupItemState.failed.rawValue])
            // The stored resources say how large they are (`BackupResource.byteSize`), for "1.2 GB left" (SPEC §15.4).
            let bytes = try Int64.fetchOne(
                db, sql: "SELECT sum(json_extract(resource, '$.byteSize')) FROM backupAsset WHERE state = ? AND resource IS NOT NULL",
                arguments: [BackupItemState.pending.rawValue])
            return (counts, lastFailure, bytes ?? 0)
        }
        status.uploaded = counts[BackupItemState.uploaded.rawValue] ?? 0
        status.matched = counts[BackupItemState.matched.rawValue] ?? 0
        status.failed = counts[BackupItemState.failed.rawValue] ?? 0
        status.pending = counts[BackupItemState.pending.rawValue] ?? 0
        status.skipped = counts[BackupItemState.skipped.rawValue] ?? 0
        status.lastFailure = lastFailure
        status.pendingBytes = pendingBytes
    }

    /// Removes entries of resources that are no longer there to upload (the photo was deleted on the device, the options
    /// no longer select it, an edit was reverted), and returns their keys. They were never uploaded, and nothing would
    /// ever change them again: the backup could not become "up to date". Entries of what is on the server stay.
    ///
    /// - Parameters:
    ///   - checked: the assets the scan looked at; nil: the whole library.
    ///   - seen: the assets of those that are there and selected.
    ///   - read: the assets whose resources were read; `found` are their resources.
    @discardableResult
    func removeStaleEntries(
        ledger: [LedgerKey: BackupLedgerEntry], checked: Set<String>?, seen: Set<String>, read: Set<String>, found: Set<LedgerKey>
    ) throws -> Set<LedgerKey> {
        let handedOver = Set(journal?.handedOverResources.map { LedgerKey($0) } ?? [])
            .union(UploadJobJournal.claims(at: uploadJobs).keys)
        var stale = Set<LedgerKey>()
        for (key, entry) in ledger where !BackupPolicy.isComplete(entry) && !handedOver.contains(key) {
            let id = key.localIdentifier
            let gone = !seen.contains(id) && (checked?.contains(id) ?? true)
            if gone || (read.contains(id) && !found.contains(key)) { stale.insert(key) }
        }
        guard !stale.isEmpty else { return [] }
        try database.writer.write { db in
            for key in stale {
                try db.execute(
                    sql: "DELETE FROM backupAsset WHERE localIdentifier = ? AND resourceKind = ?",
                    arguments: [key.localIdentifier, key.kind])
            }
        }
        return stale
    }

    /// Ledger entries for the details list.
    public func entries(limit: Int = 500) throws -> [BackupLedgerEntry] {
        try database.writer.read { db in try BackupLedgerEntry.order(Column("updatedAt").desc).limit(limit).fetchAll(db) }
    }

    /// Lets the user force-upload a resource that was matched (SPEC §7.18.4): the next run uploads it without asking the
    /// matcher again (which would only find the same server file once more).
    public func forgetMatch(localIdentifier: String, kind: String) throws {
        let updatedAt = now().timeIntervalSince1970
        try database.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE backupAsset SET state = ?, matchedBy = ?, attempts = 0, lastError = NULL, updatedAt = ?
                    WHERE localIdentifier = ? AND resourceKind = ?
                    """,
                arguments: [BackupItemState.pending.rawValue, MatchReason.user.rawValue, updatedAt, localIdentifier, kind])
        }
    }

    public func reset() throws {
        try database.writer.write { db in try db.execute(sql: "DELETE FROM backupAsset") }
        try database.setSyncValue(Self.scanSignatureKey, nil)
        try database.setSyncValue(Self.scanStateKey, nil)
        cancelBackgroundUploads()
        resume = nil
        status = BackupStatus()
    }
}

extension BackupEngine.LedgerKey {
    init(_ resource: BackupResource) {
        self.init(localIdentifier: resource.localIdentifier, kind: resource.kind.rawValue)
    }
}
