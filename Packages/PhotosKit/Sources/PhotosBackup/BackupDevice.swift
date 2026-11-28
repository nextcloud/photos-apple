// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import Photos
import PhotosModel

// What the backup knows about the photos on this device, for the screens around it: the first-run count ("X already on
// your server, Y to upload", SPEC §7.18.1), the photos that are not backed up yet, and the ones that may be removed from
// the device (SPEC §7.18.8, §22.1: `DeviceFreeUp.swift`). Read-only on the ledger; nothing here changes how the engine
// backs up.

/// How many photos and videos of the ledger are on the server and how many still wait (counted per asset, not per
/// resource: a Live Photo is one).
public struct BackupAssetCounts: Sendable, Equatable {
    /// Every resource is uploaded or was found on the server.
    public var onServer = 0
    /// At least one resource still waits or failed.
    public var toUpload = 0

    public init(onServer: Int = 0, toUpload: Int = 0) {
        self.onServer = onServer
        self.toUpload = toUpload
    }
}

/// A photo or video of this device that is not (completely) on the server yet.
public struct NotBackedUpAsset: Sendable, Hashable, Identifiable {
    public enum Reason: Sendable, Hashable {
        /// Waiting for its upload, or not looked at by the backup yet.
        case waiting
        /// Its upload failed; the message says why, when known.
        case failed(String?)
        /// The original is only in iCloud and "Download originals from iCloud" is off.
        case onlyInICloud
    }

    public var localIdentifier: String
    public var reason: Reason
    public var id: String { localIdentifier }

    public init(localIdentifier: String, reason: Reason) {
        self.localIdentifier = localIdentifier
        self.reason = reason
    }
}

// MARK: - Ledger reads

extension BackupEngine {
    /// All ledger entries, grouped by asset.
    public func ledgerByAsset() throws -> [String: [BackupLedgerEntry]] {
        try database.writer.read { db in
            Dictionary(grouping: try BackupLedgerEntry.fetchAll(db), by: \.localIdentifier)
        }
    }

    /// Per-asset counts of the ledger.
    public func assetCounts() throws -> BackupAssetCounts {
        try database.writer.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT
                      COALESCE(SUM(CASE WHEN todo = 0 AND skipped = 0 THEN 1 ELSE 0 END), 0) AS onServer,
                      COALESCE(SUM(CASE WHEN todo > 0 THEN 1 ELSE 0 END), 0) AS toUpload
                    FROM (
                      SELECT localIdentifier,
                        SUM(state IN (?, ?)) AS todo,
                        SUM(state = ?) AS skipped
                      FROM backupAsset GROUP BY localIdentifier
                    )
                    """,
                arguments: [BackupItemState.pending.rawValue, BackupItemState.failed.rawValue, BackupItemState.skipped.rawValue])
            return BackupAssetCounts(onServer: row?["onServer"] ?? 0, toUpload: row?["toUpload"] ?? 0)
        }
    }
}

// MARK: - Not backed up (round-3 item 37)

public enum BackupDeviceState {
    /// The resource is on the server: uploaded, or found there.
    static func isComplete(_ entry: BackupLedgerEntry) -> Bool {
        entry.state == BackupItemState.uploaded.rawValue || entry.state == BackupItemState.matched.rawValue
    }

    /// True when every resource the ledger has of an asset is on the server, and it has at least one.
    static func isBackedUp(_ entries: [BackupLedgerEntry]) -> Bool {
        !entries.isEmpty && entries.allSatisfy(isComplete)
    }

    /// The device's photos (newest first) that are not on the server yet, with why. An asset the ledger doesn't know
    /// yet is waiting: the next pass looks at it.
    static func notBackedUp(_ localIdentifiers: [String], ledger: [String: [BackupLedgerEntry]]) -> [NotBackedUpAsset] {
        localIdentifiers.compactMap { id in
            let entries = ledger[id] ?? []
            if isBackedUp(entries) { return nil }
            if let failed = entries.first(where: { $0.state == BackupItemState.failed.rawValue }) {
                return NotBackedUpAsset(localIdentifier: id, reason: .failed(failed.lastError))
            }
            let open = entries.filter { !isComplete($0) }
            if !open.isEmpty, open.allSatisfy({ $0.state == BackupItemState.skipped.rawValue }) {
                return NotBackedUpAsset(localIdentifier: id, reason: .onlyInICloud)
            }
            return NotBackedUpAsset(localIdentifier: id, reason: .waiting)
        }
    }

    /// The photos and videos of the device the backup options select that are not on the server yet, newest first.
    public static func notBackedUp(settings: BackupSettings, ledger: [String: [BackupLedgerEntry]]) -> [NotBackedUpAsset] {
        let result = PHAsset.fetchAssets(with: PhotoLibrarySource.fetchOptions(settings, newestFirst: true))
        var ids: [String] = []
        ids.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in ids.append(asset.localIdentifier) }
        return notBackedUp(ids, ledger: ledger)
    }
}

extension PhotoLibrarySource {
    /// The same selection as `assets(_:)` for the whole library, as fetch options (album selections are not applied).
    static func fetchOptions(_ settings: BackupSettings, newestFirst: Bool) -> PHFetchOptions {
        let options = PHFetchOptions()
        var types: [Int] = []
        if settings.photos { types.append(PHAssetMediaType.image.rawValue) }
        if settings.videos { types.append(PHAssetMediaType.video.rawValue) }
        var predicates = [NSPredicate(format: "mediaType IN %@", types)]
        if let since = settings.since { predicates.append(NSPredicate(format: "creationDate >= %@", since as NSDate)) }
        options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: !newestFirst)]
        options.includeAssetSourceTypes = [.typeUserLibrary]
        options.includeHiddenAssets = settings.includeHidden
        return options
    }

    /// How many photos and videos the backup options select: a count from PhotoKit, without reading the assets.
    public static func count(_ settings: BackupSettings) -> Int {
        guard settings.photos || settings.videos else { return 0 }
        if !settings.albumIdentifiers.isEmpty { return PhotoLibrarySource().assets(settings).count }
        return PHAsset.fetchAssets(with: fetchOptions(settings, newestFirst: false)).count
    }
}

// MARK: - The Files app (round-3 item 33)

extension FilesAppLedger {
    /// The Files app left something here to read: its auto-upload database or its settings. Without either, there is
    /// nothing to ask about it (SPEC §7.18.1 asks only when it is installed and configured).
    public static var hasData: Bool {
        guard isAvailable, let container else { return false }
        let database = container.appending(path: "Library/Application Support/Nextcloud/nextcloud.sqlite")
        if FileManager.default.fileExists(atPath: database.path(percentEncoded: false)) { return true }
        guard let defaults = UserDefaults(suiteName: group) else { return false }
        return defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("Preferences_") }
    }
}
