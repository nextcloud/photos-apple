// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import PhotosModel
import PhotosStore
import Synchronization

// The Library's device layer (SPEC §21.1): the photos and videos of this device that backup covers and that are not on
// the server yet, with their real capture date, merged into the timeline next to the server's photos. Pure parts here
// (unit-tested); PhotoKit is read in `DeviceLibraryReader`, the layer is kept current by `DeviceLayerModel`.

/// What the backup's ledger says about one asset of the device, over all its resources (original, edit, Live Photo
/// motion, RAW).
public enum DeviceLedgerState: Sendable, Hashable {
    /// Every resource is on the server: uploaded by this app (the server answered with the file) or found there by the
    /// backup's duplicate check. Only this counts as backed up.
    case backedUp
    /// Not on the server yet: waiting for its upload, or not looked at by the backup yet.
    case waiting
    /// An upload failed and waits for its next attempt; the message says why, when known.
    case failed(String?)
    /// Its original is only in iCloud and "Download originals from iCloud" is off.
    case onlyInICloud

    /// The state of an asset from the ledger's entries of its resources. No entry at all is `waiting`: the next pass
    /// looks at it.
    public static func of(_ entries: [BackupLedgerEntry]) -> DeviceLedgerState {
        if BackupDeviceState.isBackedUp(entries) { return .backedUp }
        if let failed = entries.first(where: { $0.state == BackupItemState.failed.rawValue }) { return .failed(failed.lastError) }
        let open = entries.filter { !BackupDeviceState.isComplete($0) }
        if !open.isEmpty, open.allSatisfy({ $0.state == BackupItemState.skipped.rawValue }) { return .onlyInICloud }
        return .waiting
    }
}

/// Reads the ledger per asset, aggregated in SQL (one row per asset, not per resource; 100 000 assets in a few tens of
/// milliseconds).
public enum DeviceLedger {
    public static func load(_ database: AccountDatabase) throws -> [String: DeviceLedgerState] {
        try database.writer.read { db in try load(db) }
    }

    static func load(_ db: Database) throws -> [String: DeviceLedgerState] {
        let complete = [BackupItemState.uploaded.rawValue, BackupItemState.matched.rawValue]
        let rows = try Row.fetchCursor(
            db,
            sql: """
                SELECT localIdentifier,
                  COUNT(*) AS total,
                  SUM(state IN (?, ?)) AS done,
                  SUM(state = ?) AS failed,
                  SUM(state = ?) AS skipped,
                  MAX(CASE WHEN state = ? THEN lastError END) AS error
                FROM backupAsset GROUP BY localIdentifier
                """,
            arguments: [
                complete[0], complete[1], BackupItemState.failed.rawValue, BackupItemState.skipped.rawValue,
                BackupItemState.failed.rawValue,
            ])
        var result: [String: DeviceLedgerState] = [:]
        while let row = try rows.next() {
            let total: Int = row["total"]
            let done: Int = row["done"]
            let failed: Int = row["failed"]
            let skipped: Int = row["skipped"]
            let state: DeviceLedgerState =
                if done == total {
                    .backedUp
                } else if failed > 0 {
                    .failed(row["error"])
                } else if skipped > 0, skipped == total - done {
                    .onlyInICloud
                } else {
                    .waiting
                }
            result[row["localIdentifier"]] = state
        }
        return result
    }
}

/// One photo or video of the device as PhotoKit describes it: what the timeline needs, nothing read from its files.
public struct DeviceLibraryItem: Sendable, Hashable {
    public var localIdentifier: String
    public var createdAt: Date
    public var isVideo: Bool
    public var isFavorite: Bool
    public var isLivePhoto: Bool
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Seconds; 0 for photos.
    public var duration: Double
    /// PhotoKit's `burstIdentifier` of a burst's frame; nil otherwise.
    public var burstIdentifier: String?

    public init(
        localIdentifier: String, createdAt: Date, isVideo: Bool = false, isFavorite: Bool = false, isLivePhoto: Bool = false,
        pixelWidth: Int = 0, pixelHeight: Int = 0, duration: Double = 0, burstIdentifier: String? = nil
    ) {
        self.burstIdentifier = burstIdentifier
        self.localIdentifier = localIdentifier
        self.createdAt = createdAt
        self.isVideo = isVideo
        self.isFavorite = isFavorite
        self.isLivePhoto = isLivePhoto
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
    }
}

/// A device photo the Library shows: not on the server yet.
public struct DeviceAsset: Sendable, Hashable, Identifiable {
    /// `DeviceMediaID.id(for:)` of the local identifier.
    public var id: FileID
    public var item: DeviceLibraryItem
    public var badge: DeviceBackupBadge
    /// Why its upload failed, when it did.
    public var failure: String?
    /// The backup has not looked at it yet: the ledger has no entry for it.
    public var isUnchecked = false

    public var localIdentifier: String { item.localIdentifier }
}

/// The device layer at one moment: what the Library shows of the device and the counts of the backup summary.
public struct DeviceLayerSnapshot: Sendable, Equatable {
    /// Not backed up, newest first.
    public private(set) var assets: [DeviceAsset]
    /// How many photos and videos backup covers on this device (its options select them).
    public private(set) var covered: Int
    /// Of those, how many are on the server (`DeviceLedgerState.backedUp`).
    public private(set) var backedUp: Int
    /// Of the others, how many are being uploaded now.
    public private(set) var uploading: Int
    /// Of the others, how many failed.
    public private(set) var failed: Int
    private var index: [FileID: Int]

    public static let empty = DeviceLayerSnapshot(assets: [], covered: 0, backedUp: 0)

    init(assets: [DeviceAsset], covered: Int, backedUp: Int) {
        self.assets = assets
        self.covered = covered
        self.backedUp = backedUp
        uploading = assets.count { $0.badge == .uploading }
        failed = assets.count { $0.badge == .failed }
        var index: [FileID: Int] = [:]
        index.reserveCapacity(assets.count)
        for (position, asset) in assets.enumerated() { index[asset.id] = position }
        self.index = index
    }

    /// Photos and videos of the device that are not on the server.
    public var notBackedUp: Int { assets.count }

    public subscript(id: FileID) -> DeviceAsset? { index[id].map { assets[$0] } }

    public func contains(_ id: FileID) -> Bool { index[id] != nil }

    /// Local identifiers of the given ids that are device photos of this snapshot, in the given order.
    public func localIdentifiers(of ids: [FileID]) -> [String] {
        ids.compactMap { self[$0]?.localIdentifier }
    }
}

public enum DeviceLayerBuilder {
    /// The snapshot from what PhotoKit lists (the assets backup covers) and what the ledger says.
    ///
    /// - Parameters:
    ///   - library: the device's photos and videos that backup covers, in any order.
    ///   - ledger: `DeviceLedger.load`.
    ///   - inFlight: local identifiers whose upload runs now (`BackupStatus.uploadingIdentifiers`).
    public static func build(library: [DeviceLibraryItem], ledger: [String: DeviceLedgerState], inFlight: Set<String>)
        -> DeviceLayerSnapshot
    {
        var assets: [DeviceAsset] = []
        var backedUp = 0
        var seen = Set<FileID>()
        for item in library {
            let known = ledger[item.localIdentifier]
            let state = known ?? .waiting
            let badge: DeviceBackupBadge
            var failure: String?
            switch state {
            case .backedUp:
                backedUp += 1
                continue
            case .waiting: badge = .waiting
            case .failed(let message):
                badge = .failed
                failure = message
            case .onlyInICloud: badge = .onlyInICloud
            }
            let id = DeviceMediaID.id(for: item.localIdentifier)
            // A collision of two identifiers (about one in two billion): the second is left out, never mixed up.
            guard seen.insert(id).inserted else { continue }
            assets.append(
                DeviceAsset(
                    id: id, item: item, badge: inFlight.contains(item.localIdentifier) ? .uploading : badge, failure: failure,
                    isUnchecked: known == nil))
        }
        assets.sort { lhs, rhs in
            lhs.item.createdAt != rhs.item.createdAt ? lhs.item.createdAt > rhs.item.createdAt : lhs.id > rhs.id
        }
        return DeviceLayerSnapshot(assets: assets, covered: library.count, backedUp: backedUp)
    }
}

/// The local identifiers of the device photos the app has shown, by their id, for the parts that only get the id (the
/// image pipeline, the viewer). Written by whoever builds a snapshot.
public final class DeviceAssetDirectory: Sendable {
    public static let shared = DeviceAssetDirectory()

    private let identifiers = Mutex<[FileID: String]>([:])

    public init() {}

    public func register(_ snapshot: DeviceLayerSnapshot) {
        identifiers.withLock { map in
            for asset in snapshot.assets { map[asset.id] = asset.localIdentifier }
        }
    }

    public func localIdentifier(of id: FileID) -> String? {
        identifiers.withLock { $0[id] }
    }
}
