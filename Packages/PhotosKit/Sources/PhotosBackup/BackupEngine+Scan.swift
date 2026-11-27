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
    // MARK: Scan

    /// What a scan found to do.
    struct Work {
        /// Resources to upload without asking the server first: a new edit, "Upload anyway", or the server was asked
        /// about them recently (`BackupPolicy.serverCheckValidity`). Oldest first.
        var ready: [BackupResource] = []
        /// Resources the server is asked about before they are uploaded. Oldest first.
        var unchecked: [BackupResource] = []
        /// Only what changed since the last pass was looked at, and the daily look at the whole library is due.
        var fullScanDue = false
    }

    /// What the scans remember between passes (`syncState`).
    struct ScanState: Codable, Equatable {
        /// The library's change token, taken before the last scan.
        var token: Data?
        /// `BackupPolicy.scopeSignature` of the last scan: another selection of assets is a look at everything.
        var scope: String
        /// When the whole library was last looked at.
        var fullScanAt: Double
    }

    static let scanStateKey = "backup.scanState"

    func loadScanState() -> ScanState? {
        guard let json = try? database.syncValue(Self.scanStateKey) else { return nil }
        return try? JSONDecoder().decode(ScanState.self, from: Data(json.utf8))
    }

    private func saveScanState(_ state: ScanState) throws {
        try database.setSyncValue(Self.scanStateKey, String(decoding: try JSONEncoder().encode(state), as: UTF8.self))
    }

    /// Finds what has to be uploaded (SPEC §7.18.3), and records what it learnt in the ledger, so that an interrupted
    /// pass does not have to learn it again.
    ///
    /// Only the assets that changed since the last pass are looked at (the library's persistent change token), unless
    /// the selection or the options changed, the token is unknown or too old, the user asks (`retryFailed`) or
    /// `wholeLibrary`; once a day the whole library is looked at (`Work.fullScanDue`). Of the assets looked at, only
    /// those the ledger does not know completely are read (`BackupPolicy.needsScan`). What waits for its upload is taken
    /// from the ledger, which keeps the resource (`BackupLedgerEntry.resource`), without reading the library again.
    func scan(_ settings: BackupSettings, retryFailed: Bool, wholeLibrary: Bool = false) throws -> Work {
        let now = now()
        let ledger = try loadLedger()
        var byAsset: [String: [BackupLedgerEntry]] = [:]
        for entry in ledger.values { byAsset[entry.localIdentifier, default: []].append(entry) }
        // Other options select other resources of an asset, so the "nothing to do" shortcut does not hold then.
        let signature = BackupPolicy.scanSignature(settings)
        let readEverything = retryFailed || (try? database.syncValue(Self.scanSignatureKey)) != signature
        let scope = BackupPolicy.scopeSignature(settings, isLimited: library.isLimited)
        let previous = loadScanState()
        // Taken before anything is read: what changes from here on is for the next pass.
        let token = library.changeToken
        var changed: Set<String>?
        if !wholeLibrary, !readEverything, let previous, previous.scope == scope, let since = previous.token {
            changed = library.changedAssets(since: since, settings: settings)
        }
        // Entries that lack what an upload needs (written by an earlier version, "Upload anyway") have their asset read.
        let restriction = changed.map { changed in
            changed.union(byAsset.compactMap { id, entries in entries.contains { BackupPolicy.needsRead($0, now: now) } ? id : nil })
                .union(priority)
        }
        var seen = Set<String>()
        var read = Set<String>()
        let resources = library.scan(settings, assets: restriction) { localIdentifier, modifiedAt in
            seen.insert(localIdentifier)
            guard readEverything || BackupPolicy.needsScan(entries: byAsset[localIdentifier] ?? [], modifiedAt: modifiedAt, now: now)
            else { return false }
            read.insert(localIdentifier)
            return true
        }
        let stale = try removeStaleEntries(
            ledger: ledger, checked: restriction, seen: seen, read: read, found: Set(resources.map { LedgerKey($0) }))

        // What was read, and what waits in the ledger for assets that were not read.
        var candidates: [(resource: BackupResource, entry: BackupLedgerEntry?)] = resources.map { ($0, ledger[LedgerKey($0)]) }
        let decoder = JSONDecoder()
        for (key, entry) in ledger
        where !read.contains(key.localIdentifier) && !stale.contains(key) && !BackupPolicy.isComplete(entry) {
            if let resource = entry.storedResource(decoder) { candidates.append((resource, entry)) }
        }
        let filesUploaded = settings.filesAppMode == .notUsed ? [] : filesLedger(accountId)
        // Files' record stands for the photo or video itself, not for every resource of the asset.
        var filesPrimary = Set<LedgerKey>()
        if !filesUploaded.isEmpty {
            var kinds: [String: [BackupResourceKind]] = [:]
            for resource in resources { kinds[resource.localIdentifier, default: []].append(resource.kind) }
            for (id, entries) in byAsset where !read.contains(id) {
                kinds[id] = entries.compactMap { BackupResourceKind(rawValue: $0.resourceKind) }
            }
            filesPrimary = BackupPolicy.filesAppPrimary(kinds: kinds)
        }

        var work = Work()
        var unknown: [BackupResource] = []
        var touched: [BackupResource] = []
        var refreshed: [(resource: BackupResource, modified: Bool)] = []
        var reopened: [BackupResource] = []
        var filesMatched: [BackupResource] = []
        for (resource, entry) in candidates {
            let key = LedgerKey(resource)
            if let entry, !BackupPolicy.isComplete(entry), read.contains(resource.localIdentifier) {
                // The library's word is newer than the ledger's.
                refreshed.append((resource, BackupPolicy.isModified(resource.modifiedAt, since: entry.assetModifiedAt)))
            }
            // What the user asked to back up now does not wait for its next attempt.
            let retry = retryFailed || priority.contains(resource.localIdentifier)
            let action = BackupPolicy.action(
                for: resource, entry: entry, now: now, retryFailed: retry, retrySkipped: settings.downloadFromICloud)
            switch action {
            case .done, .waiting: continue
            case .touch: touched.append(resource)
            case .upload:
                // A new edit of something that is on the server: it waits now, also when this pass does not get to it.
                if let entry, BackupPolicy.isComplete(entry) { reopened.append(resource) }
                work.ready.append(resource)
            case .reconcile:
                if filesUploaded.contains(resource.localIdentifier), filesPrimary.contains(key) {
                    filesMatched.append(resource)
                    continue
                }
                if entry == nil { unknown.append(resource) }
                if let entry, !retry, !BackupPolicy.needsServerCheck(entry, modifiedAt: resource.modifiedAt, now: now) {
                    work.ready.append(resource)
                } else {
                    work.unchecked.append(resource)
                }
            }
        }
        work.ready = prioritized(work.ready.sorted(by: BackupPolicy.isOlder))
        work.unchecked = prioritized(work.unchecked.sorted(by: BackupPolicy.isOlder))
        // Everything found gets a ledger entry now: an asset without one for each of its resources is read again next time.
        try prepareLedger(pending: unknown, touched: touched, refreshed: refreshed, reopened: reopened, filesMatched: filesMatched)
        try database.setSyncValue(Self.scanSignatureKey, signature)
        try saveScanState(
            ScanState(
                token: token, scope: scope, fullScanAt: changed == nil ? now.timeIntervalSince1970 : previous?.fullScanAt ?? 0))
        if let changed {
            work.fullScanDue = now.timeIntervalSince1970 - (previous?.fullScanAt ?? 0) >= BackupPolicy.fullScanInterval
            logger.info(
                "backup: \(changed.count, privacy: .public) assets changed, \(read.count, privacy: .public) read")
        } else {
            logger.info("backup: \(seen.count, privacy: .public) assets looked at, \(read.count, privacy: .public) read")
        }
        try Task.checkCancellation()
        return work
    }
}

extension BackupEngine {
    // MARK: Back up now (SPEC §21.1)

    /// The user asked to back up these photos now (a selection in the Library): the running pass takes them first from
    /// its next round on, the next pass first of all; a failed one is tried at once.
    public func prioritize(_ localIdentifiers: Set<String>) {
        priority.formUnion(localIdentifiers)
    }

    /// `resources` with the prioritized ones first, each part in its order.
    func prioritized(_ resources: [BackupResource]) -> [BackupResource] {
        guard !priority.isEmpty else { return resources }
        let first = resources.filter { priority.contains($0.localIdentifier) }
        guard !first.isEmpty else { return resources }
        return first + resources.filter { !priority.contains($0.localIdentifier) }
    }
}
