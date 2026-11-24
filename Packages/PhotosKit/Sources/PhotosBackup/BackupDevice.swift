// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import Photos
import PhotosModel
import PhotosNetworking

// What the backup knows about the photos on this device, for the screens around it: the first-run count ("X already on
// your server, Y to upload", SPEC §7.18.1), the photos that are not backed up yet, and the ones that may be removed from
// the device (SPEC §7.18.8). Read-only on the ledger; nothing here changes how the engine backs up.

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

/// A photo or video that may be removed from this device: each of its files is on the server with the same size.
public struct FreeUpCandidate: Sendable, Hashable, Identifiable {
    public var localIdentifier: String
    /// What removing it frees on the device (all its PhotoKit resources).
    public var byteSize: Int64
    public var createdAt: Date?
    public var id: String { localIdentifier }

    public init(localIdentifier: String, byteSize: Int64, createdAt: Date?) {
        self.localIdentifier = localIdentifier
        self.byteSize = byteSize
        self.createdAt = createdAt
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

// MARK: - Free up space on the device (SPEC §7.18.8, round-3 item 36)

/// Size and id of a file on the server, as listed right before the device copy may be removed.
public struct ServerFileInfo: Sendable, Hashable {
    public var fileId: Int64?
    public var size: Int64

    public init(fileId: Int64?, size: Int64) {
        self.fileId = fileId
        self.size = size
    }
}

/// Lists the files of a server folder (path → size and id). A folder that doesn't exist has no files.
public protocol ServerFileListing: Sendable {
    func files(in folder: String) async throws -> [String: ServerFileInfo]
}

/// The real server: one `PROPFIND` (depth 1) per folder.
public struct DAVServerFileListing: ServerFileListing {
    let dav: DAVClient

    public init(api: PhotosAPI) {
        dav = api.dav
    }

    public func files(in folder: String) async throws -> [String: ServerFileInfo] {
        let path = BackupFolder.normalized(folder)
        let resources: [DAVResource]
        do {
            resources = try await dav.propfind(
                dav.connection.filesURL(path == "/" ? "/" : path + "/"), depth: 1,
                properties: [DAVProp.fileId, DAVProp.size, DAVProp.contentLength, DAVProp.resourceType])
        } catch NetworkError.notFound {
            return [:]
        }
        var files: [String: ServerFileInfo] = [:]
        for resource in resources where !resource.isCollection {
            guard let userPath = dav.connection.userPath(fromHref: resource.href),
                let size = resource.int64(DAVProp.contentLength) ?? resource.int64(DAVProp.size)
            else { continue }
            files[BackupFolder.normalized(userPath)] = ServerFileInfo(fileId: resource.int64(DAVProp.fileId), size: size)
        }
        return files
    }
}

/// Which device photos may be removed because they are safely on the server (SPEC §7.18.8).
///
/// Only an asset whose every file the backup would keep (original, edited version, RAW, Live Photo motion) is on the
/// server, recorded in the ledger as uploaded or found there, **and** listed by the server right now with exactly the
/// size of the device's file (and the same file id, when both are known). Anything else is never offered: a file
/// converted to JPEG for the backup, a match by name only, a Files-app record without a server path, an edit of a Live
/// Photo's motion. Photos taken in the last 30 days are only offered when the user asks.
public enum DeviceCleanup {
    public static let recentPeriod: TimeInterval = 30 * 86_400

    /// One device asset as far as the check needs it.
    struct LocalAsset: Sendable {
        var localIdentifier: String
        var createdAt: Date?
        /// The files that must be on the server.
        var required: [Resource]
        /// What removing the asset frees.
        var totalSize: Int64
        /// The asset has something the backup never uploads (the edited motion of a Live Photo).
        var hasUnbackedResource = false

        struct Resource: Sendable {
            var kind: BackupResourceKind
            var byteSize: Int64?
        }
    }

    /// Assets of the ledger whose every entry is complete and has a server path: the only ones worth a closer look.
    static func ledgerCandidates(_ ledger: [String: [BackupLedgerEntry]]) -> [String] {
        ledger.compactMap { id, entries in
            BackupDeviceState.isBackedUp(entries) && entries.allSatisfy({ $0.serverPath != nil }) ? id : nil
        }
        .sorted()
    }

    /// The asset's files are each on the server with the same size (see the type's description).
    static func isVerified(_ asset: LocalAsset, entries: [BackupLedgerEntry], server: [String: ServerFileInfo]) -> Bool {
        guard !asset.required.isEmpty, !asset.hasUnbackedResource else { return false }
        return asset.required.allSatisfy { resource in
            guard let entry = entries.first(where: { $0.resourceKind == resource.kind.rawValue }), BackupDeviceState.isComplete(entry),
                let path = entry.serverPath, let localSize = resource.byteSize, localSize > 0,
                let file = server[BackupFolder.normalized(path)], file.size == localSize
            else { return false }
            if let recorded = entry.serverFileId, let listed = file.fileId, recorded != listed { return false }
            return true
        }
    }

    /// Old enough to be offered without asking.
    static func isOldEnough(_ createdAt: Date?, now: Date) -> Bool {
        guard let createdAt else { return false }
        return now.timeIntervalSince(createdAt) >= recentPeriod
    }

    /// The folders whose listing the check needs.
    static func folders(of entries: [BackupLedgerEntry]) -> Set<String> {
        Set(entries.compactMap { $0.serverPath.map { (BackupFolder.normalized($0) as NSString).deletingLastPathComponent } })
    }

    /// Verifies local assets against the server's listing. `progress` gets the number of folders checked and their total.
    static func verify(
        _ assets: [LocalAsset], ledger: [String: [BackupLedgerEntry]], listing: any ServerFileListing,
        progress: @Sendable (Int, Int) -> Void
    ) async throws -> [FreeUpCandidate] {
        let folders = folders(of: assets.flatMap { ledger[$0.localIdentifier] ?? [] }).sorted()
        var server: [String: ServerFileInfo] = [:]
        for (index, folder) in folders.enumerated() {
            try Task.checkCancellation()
            server.merge(try await listing.files(in: folder)) { $1 }
            progress(index + 1, folders.count)
        }
        return assets.compactMap { asset in
            guard isVerified(asset, entries: ledger[asset.localIdentifier] ?? [], server: server) else { return nil }
            return FreeUpCandidate(localIdentifier: asset.localIdentifier, byteSize: asset.totalSize, createdAt: asset.createdAt)
        }
    }

    /// The device's photos that may be removed, oldest first.
    ///
    /// - Parameters:
    ///   - settings: the backup options; which files of an asset must be on the server does not depend on them (always
    ///     the original, an edited version, a RAW file and a Live Photo's motion), only which assets are looked at.
    ///   - includeRecent: also photos from the last 30 days.
    ///   - progress: folders checked on the server, of how many.
    public static func candidates(
        ledger: [String: [BackupLedgerEntry]], settings: BackupSettings, listing: any ServerFileListing, includeRecent: Bool,
        now: Date = Date(), progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> [FreeUpCandidate] {
        let ids = ledgerCandidates(ledger)
        var assets: [LocalAsset] = []
        for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
            try Task.checkCancellation()
            PHAsset.fetchAssets(withLocalIdentifiers: chunk, options: nil).enumerateObjects { asset, _, _ in
                guard includeRecent || isOldEnough(asset.creationDate, now: now) else { return }
                assets.append(localAsset(asset, settings: settings))
            }
        }
        return try await verify(assets, ledger: ledger, listing: listing, progress: progress)
            .sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
    }

    /// Checks the given candidates against the server again (right before they are removed) and returns the ones that
    /// are still verified.
    public static func recheck(
        _ candidates: [FreeUpCandidate], ledger: [String: [BackupLedgerEntry]], settings: BackupSettings, listing: any ServerFileListing
    ) async throws -> [FreeUpCandidate] {
        var assets: [LocalAsset] = []
        let ids = candidates.map(\.localIdentifier)
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in
            assets.append(localAsset(asset, settings: settings))
        }
        return try await verify(assets, ledger: ledger, listing: listing, progress: { _, _ in })
    }

    /// What has to be on the server for an asset: the resources the backup uploads with originals and edits, Live
    /// Photos and RAW files all included (`PhotoLibrarySource.select`).
    static func localAsset(_ asset: PHAsset, settings: BackupSettings) -> LocalAsset {
        var all = settings
        all.edits = .originalAndEdited
        all.livePhotos = true
        let resources = PHAssetResource.assetResources(for: asset)
        let info = BackupAssetInfo(
            localIdentifier: asset.localIdentifier, isVideo: asset.mediaType == .video,
            isLivePhoto: asset.mediaSubtypes.contains(.photoLive), createdAt: asset.creationDate ?? Date(),
            modifiedAt: asset.modificationDate, pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight)
        let described = resources.map { resource in
            BackupAssetInfo.Resource(
                type: resource.type, name: resource.originalFilename, uniformTypeIdentifier: resource.uniformTypeIdentifier,
                byteSize: PhotoLibrarySource.byteSize(of: resource))
        }
        let required = PhotoLibrarySource.select(info, resources: described, settings: all).map {
            LocalAsset.Resource(kind: $0.resource.kind, byteSize: $0.resource.byteSize)
        }
        return LocalAsset(
            localIdentifier: asset.localIdentifier, createdAt: asset.creationDate, required: required,
            totalSize: described.reduce(0) { $0 + ($1.byteSize ?? 0) },
            hasUnbackedResource: resources.contains { $0.type == .fullSizePairedVideo })
    }

    /// Removes the assets from the device's photo library. The system asks the user to confirm; they go to Recently
    /// Deleted. Returns how many were removed (0 when the user declined).
    public static func remove(_ candidates: [FreeUpCandidate]) async throws -> Int {
        let ids = candidates.map(\.localIdentifier)
        guard !ids.isEmpty else { return 0 }
        let count = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).count
        guard count > 0 else { return 0 }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil))
            }
        } catch let error as PHPhotosError where error.code == .userCancelled {
            return 0
        }
        return count
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
