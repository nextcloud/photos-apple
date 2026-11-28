// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import Photos
import PhotosModel
import PhotosNetworking
import Synchronization

// Free up space on this device (SPEC §7.18.8, §22.1): which of the device's photos and videos may be removed because
// they are safely on the server, which stay and why, and the removal itself (PhotoKit asks the user; Recently Deleted).
//
// Nothing here ever deletes on the server. An asset is only offered when the user's keep options let it go, every file
// the backup keeps of it is recorded as uploaded or found on the server, and the server lists each of those files right
// now with exactly the device's size (and the recorded file id). Right before the removal the check runs again, and where
// the server keeps a checksum of a file (the backup sends `OC-Checksum` with its uploads) the device's data is hashed and
// has to match it.

// MARK: - Options

/// How long new photos and videos stay on the device whatever the backup says.
public enum FreeUpKeepPeriod: String, Codable, Sendable, CaseIterable, Identifiable {
    case none, week, month, threeMonths, sixMonths, year

    public var id: String { rawValue }

    /// The oldest creation date that is still kept; nil when age keeps nothing. A month is 30 days, as before round 12.
    public func cutoff(now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .none: nil
        case .week: calendar.date(byAdding: .day, value: -7, to: now)
        case .month: calendar.date(byAdding: .day, value: -30, to: now)
        case .threeMonths: calendar.date(byAdding: .month, value: -3, to: now)
        case .sixMonths: calendar.date(byAdding: .month, value: -6, to: now)
        case .year: calendar.date(byAdding: .year, value: -1, to: now)
        }
    }
}

/// What the user keeps on the device when freeing up space (a preference of this device).
public struct FreeUpOptions: Codable, Hashable, Sendable {
    /// Photos and videos taken in this period stay.
    public var keepRecent: FreeUpKeepPeriod = .month
    /// Favourites stay.
    public var keepFavorites = true
    /// Photos hidden in the Photos app stay.
    public var keepHidden = true

    public init(keepRecent: FreeUpKeepPeriod = .month, keepFavorites: Bool = true, keepHidden: Bool = true) {
        self.keepRecent = keepRecent
        self.keepFavorites = keepFavorites
        self.keepHidden = keepHidden
    }

    /// Options a stored value does not have keep their default; an unknown period falls back to a month.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = FreeUpOptions()
        keepRecent = (try? values.decodeIfPresent(FreeUpKeepPeriod.self, forKey: .keepRecent)) ?? defaults.keepRecent
        keepFavorites = try values.decodeIfPresent(Bool.self, forKey: .keepFavorites) ?? defaults.keepFavorites
        keepHidden = try values.decodeIfPresent(Bool.self, forKey: .keepHidden) ?? defaults.keepHidden
    }
}

// MARK: - Results

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

/// Why a backed-up photo stays on the device. In the order the rules are applied: each photo is counted once, for the
/// first reason that holds.
public enum FreeUpKeepReason: String, Sendable, CaseIterable, Hashable, Comparable {
    /// Not part of the user's own library: an item of an iCloud shared album, or synced from a computer. Never removed.
    case notInLibrary
    /// Hidden in the Photos app, and the user keeps hidden photos.
    case hidden
    /// A favourite, and the user keeps favourites.
    case favorite
    /// Taken in the period the user keeps.
    case recent
    /// Edited on this device, and that edit is not on the server: the backup keeps originals only, or the photo was
    /// edited again after its edit was backed up. Never removed.
    case editNotBackedUp
    /// A file the backup keeps of it (original, RAW, Live Photo motion, edited version) is not on the server, or it has
    /// a file the backup never uploads (the edited motion of a Live Photo).
    case incomplete
    /// The server does not list its files right now with the device's size, file id or checksum.
    case notVerified

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// A count of photos and videos and their size on the device.
public struct FreeUpTally: Sendable, Hashable {
    public var count = 0
    public var bytes: Int64 = 0

    public init(count: Int = 0, bytes: Int64 = 0) {
        self.count = count
        self.bytes = bytes
    }

    mutating func add(_ bytes: Int64) {
        count += 1
        self.bytes += bytes
    }
}

/// What a check found: the photos that may be removed (oldest first) and those that stay, by reason.
public struct FreeUpPlan: Sendable, Equatable {
    public var candidates: [FreeUpCandidate] = []
    public var kept: [FreeUpKeepReason: FreeUpTally] = [:]

    public init(candidates: [FreeUpCandidate] = [], kept: [FreeUpKeepReason: FreeUpTally] = [:]) {
        self.candidates = candidates
        self.kept = kept
    }

    /// What removing the candidates frees.
    public var bytes: Int64 { candidates.reduce(0) { $0 + $1.byteSize } }

    /// Photos that stay, over all reasons.
    public var keptCount: Int { kept.values.reduce(0) { $0 + $1.count } }
}

/// How far a check has come.
public enum FreeUpProgress: Sendable, Equatable {
    /// Listing the server's folders (`done` of `total`).
    case listing(done: Int, total: Int)
    /// Comparing the device's files with the server's checksums (`done` of `total` photos).
    case hashing(done: Int, total: Int)
}

/// A quick estimate of what free up would offer, from the ledger and the device's library without asking the server
/// (the account menu and the Backup screen, SPEC §22.1). The free-up screen checks with the server before it offers
/// anything.
public struct FreeUpEstimate: Sendable, Equatable {
    public var count: Int
    public var bytes: Int64

    public init(count: Int, bytes: Int64) {
        self.count = count
        self.bytes = bytes
    }

    /// Below this the offer is not worth a line in the account menu or a card on the Backup screen.
    public static let offerThreshold: Int64 = 100_000_000

    public var isWorthOffering: Bool { count > 0 && bytes >= Self.offerThreshold }
}

// MARK: - The server's side

/// A checksum algorithm the server may keep for a file (`oc:checksums`), strongest first.
public enum ChecksumAlgorithm: String, Sendable, CaseIterable, Hashable {
    case sha256 = "SHA256"
    case sha1 = "SHA1"
    case md5 = "MD5"
}

/// Size, id and checksums of a file on the server, as listed right before the device copy may be removed.
public struct ServerFileInfo: Sendable, Hashable {
    public var fileId: Int64?
    public var size: Int64
    /// Lowercase hex digests by algorithm (only those the app can compute; Adler-32 is left out).
    public var checksums: [ChecksumAlgorithm: String]

    public init(fileId: Int64?, size: Int64, checksums: [ChecksumAlgorithm: String] = [:]) {
        self.fileId = fileId
        self.size = size
        self.checksums = checksums
    }

    /// The strongest checksum the server keeps for the file.
    public var preferredChecksum: (algorithm: ChecksumAlgorithm, digest: String)? {
        for algorithm in ChecksumAlgorithm.allCases {
            if let digest = checksums[algorithm] { return (algorithm, digest) }
        }
        return nil
    }

    /// Reads `oc:checksum` values: `SHA1:… MD5:… ADLER32:…`, one or several per value, separated by spaces.
    public static func parseChecksums(_ values: [String]) -> [ChecksumAlgorithm: String] {
        var result: [ChecksumAlgorithm: String] = [:]
        for token in values.flatMap({ $0.split(whereSeparator: \.isWhitespace) }) {
            guard let colon = token.firstIndex(of: ":") else { continue }
            let name = token[..<colon].uppercased()
            let digest = token[token.index(after: colon)...].lowercased()
            guard let algorithm = ChecksumAlgorithm(rawValue: name), !digest.isEmpty, digest.allSatisfy(\.isHexDigit) else { continue }
            result[algorithm] = digest
        }
        return result
    }
}

/// Lists the files of a server folder (path → size, id and checksums). A folder that doesn't exist has no files.
public protocol ServerFileListing: Sendable {
    func files(in folder: String) async throws -> [String: ServerFileInfo]
}

/// The real server: one `PROPFIND` (depth 1) per folder.
public struct DAVServerFileListing: ServerFileListing {
    let dav: DAVClient

    static let checksums = QName(XMLNamespace.oc, "checksums")
    static let checksum = QName(XMLNamespace.oc, "checksum")

    public init(api: PhotosAPI) {
        dav = api.dav
    }

    public func files(in folder: String) async throws -> [String: ServerFileInfo] {
        let path = BackupFolder.normalized(folder)
        let resources: [DAVResource]
        do {
            resources = try await dav.propfind(
                dav.connection.filesURL(path == "/" ? "/" : path + "/"), depth: 1,
                properties: [DAVProp.fileId, DAVProp.size, DAVProp.contentLength, DAVProp.resourceType, Self.checksums])
        } catch NetworkError.notFound {
            return [:]
        }
        var files: [String: ServerFileInfo] = [:]
        for resource in resources where !resource.isCollection {
            guard let userPath = dav.connection.userPath(fromHref: resource.href),
                let size = resource.int64(DAVProp.contentLength) ?? resource.int64(DAVProp.size)
            else { continue }
            let node = resource.node(Self.checksums)
            let values = (node?.children(Self.checksum).map(\.value) ?? []) + [node?.value ?? ""]
            files[BackupFolder.normalized(userPath)] = ServerFileInfo(
                fileId: resource.int64(DAVProp.fileId), size: size, checksums: ServerFileInfo.parseChecksums(values))
        }
        return files
    }
}

// MARK: - The device's side

/// One file of a device asset, for hashing.
public struct DeviceResourceReference: Sendable, Hashable {
    public var localIdentifier: String
    public var kind: BackupResourceKind
    /// Its position in `PHAssetResource.assetResources(for:)` when it was read.
    public var index: Int?
}

/// Computes the checksum of a file of a device asset.
public protocol ResourceDigesting: Sendable {
    /// Lowercase hex; nil when the data is not on the device (only in iCloud) or cannot be read.
    func digest(of resource: DeviceResourceReference, algorithm: ChecksumAlgorithm) async throws -> String?
}

/// Hashes PhotoKit resources as they stream in. Nothing is downloaded from iCloud: such files are checked by size only.
public struct PhotoKitResourceDigester: ResourceDigesting {
    public init() {}

    public func digest(of resource: DeviceResourceReference, algorithm: ChecksumAlgorithm) async throws -> String? {
        try Task.checkCancellation()
        guard let index = resource.index,
            let asset = PHAsset.fetchAssets(withLocalIdentifiers: [resource.localIdentifier], options: nil).firstObject
        else { return nil }
        let resources = PHAssetResource.assetResources(for: asset)
        guard resources.indices.contains(index) else { return nil }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        let state = StreamingDigest(algorithm)
        return await withCheckedContinuation { continuation in
            PHAssetResourceManager.default().requestData(
                for: resources[index], options: options, dataReceivedHandler: { data in state.update(data) },
                completionHandler: { error in continuation.resume(returning: error == nil ? state.finish() : nil) })
        }
    }
}

/// An incremental hash that PhotoKit's handlers (on a queue of their own, one after the other) feed.
final class StreamingDigest: Sendable {
    private enum Hash {
        case sha256(SHA256)
        case sha1(Insecure.SHA1)
        case md5(Insecure.MD5)
    }

    private let hash: Mutex<Hash>

    init(_ algorithm: ChecksumAlgorithm) {
        switch algorithm {
        case .sha256: hash = Mutex(.sha256(SHA256()))
        case .sha1: hash = Mutex(.sha1(Insecure.SHA1()))
        case .md5: hash = Mutex(.md5(Insecure.MD5()))
        }
    }

    func update(_ data: Data) {
        hash.withLock { hash in
            switch hash {
            case .sha256(var h):
                h.update(data: data)
                hash = .sha256(h)
            case .sha1(var h):
                h.update(data: data)
                hash = .sha1(h)
            case .md5(var h):
                h.update(data: data)
                hash = .md5(h)
            }
        }
    }

    func finish() -> String {
        hash.withLock { hash in
            switch hash {
            case .sha256(let h): Self.hex(h.finalize())
            case .sha1(let h): Self.hex(h.finalize())
            case .md5(let h): Self.hex(h.finalize())
            }
        }
    }

    private static func hex(_ digest: some Sequence<UInt8>) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The digest of data in memory (tests).
    static func digest(_ data: Data, _ algorithm: ChecksumAlgorithm) -> String {
        let state = StreamingDigest(algorithm)
        state.update(data)
        return state.finish()
    }
}

// MARK: - The rules

/// Which device photos may be removed because they are safely on the server (SPEC §7.18.8, §22.1).
///
/// Only an asset whose every file the backup would keep (original, edited version, RAW, Live Photo motion) is on the
/// server, recorded in the ledger as uploaded or found there, **and** listed by the server right now with exactly the
/// size of the device's file (and the same file id, when both are known). Anything else is never offered: a file
/// converted to JPEG for the backup, a match by name only, a Files-app record without a server path, an edit of a Live
/// Photo's motion, an edit made after the backup, an item of a shared album. Favourites, hidden photos and recent photos
/// stay as the user chooses (`FreeUpOptions`).
public enum DeviceCleanup {
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
        var isFavorite = false
        var isHidden = false
        /// Part of the user's own library (not an iCloud shared album's item, not synced from a computer).
        var isInUserLibrary = true
        /// The user edited it on a device (`PHAsset.adjustmentsState == .userAdjusted`).
        var isUserEdited = false
        /// When it was last edited.
        var editedAt: Date?

        struct Resource: Sendable {
            var kind: BackupResourceKind
            var byteSize: Int64?
            /// Its position among the asset's PhotoKit resources (for hashing).
            var index: Int? = nil
        }
    }

    /// Assets of the ledger whose every entry is complete and has a server path: the only ones worth a closer look.
    static func ledgerCandidates(_ ledger: [String: [BackupLedgerEntry]]) -> [String] {
        ledger.compactMap { id, entries in
            BackupDeviceState.isBackedUp(entries) && entries.allSatisfy({ $0.serverPath != nil }) ? id : nil
        }
        .sorted()
    }

    /// Taken in the period the user keeps. An asset without a date counts as recent unless the user keeps nothing for
    /// its age.
    static func isRecent(_ createdAt: Date?, period: FreeUpKeepPeriod, now: Date) -> Bool {
        guard let cutoff = period.cutoff(now: now) else { return false }
        guard let createdAt else { return true }
        return createdAt > cutoff
    }

    /// The edit the device has is on the server: its edited version is recorded as uploaded or found there, and that
    /// record is not older than the edit (an edit made after the backup is not on the server yet).
    static func isEditBackedUp(_ asset: LocalAsset, entries: [BackupLedgerEntry]) -> Bool {
        guard let edited = asset.required.first(where: { $0.kind == .edited || $0.kind == .editedVideo }),
            let entry = entries.first(where: { $0.resourceKind == edited.kind.rawValue }), BackupDeviceState.isComplete(entry)
        else { return false }
        if let editedAt = asset.editedAt, entry.updatedAt + 1 < editedAt.timeIntervalSince1970 { return false }
        return true
    }

    /// Why the asset stays, before the server is asked; nil when only the server's listing decides.
    static func keepReason(_ asset: LocalAsset, entries: [BackupLedgerEntry], options: FreeUpOptions, now: Date) -> FreeUpKeepReason? {
        if !asset.isInUserLibrary { return .notInLibrary }
        if asset.isHidden, options.keepHidden { return .hidden }
        if asset.isFavorite, options.keepFavorites { return .favorite }
        if isRecent(asset.createdAt, period: options.keepRecent, now: now) { return .recent }
        if asset.isUserEdited, !isEditBackedUp(asset, entries: entries) { return .editNotBackedUp }
        let recorded = asset.required.allSatisfy { resource in
            entries.contains { $0.resourceKind == resource.kind.rawValue && BackupDeviceState.isComplete($0) && $0.serverPath != nil }
        }
        if asset.required.isEmpty || asset.hasUnbackedResource || !recorded { return .incomplete }
        return nil
    }

    /// The asset's files are each on the server with the same size (and recorded file id).
    static func isVerified(_ asset: LocalAsset, entries: [BackupLedgerEntry], server: [String: ServerFileInfo]) -> Bool {
        guard !asset.required.isEmpty, !asset.hasUnbackedResource else { return false }
        return asset.required.allSatisfy { resource in
            guard let file = serverFile(of: resource, entries: entries, server: server), let localSize = resource.byteSize, localSize > 0,
                file.size == localSize
            else { return false }
            return true
        }
    }

    /// The server's listing of a resource's file, when the ledger has it as complete and the recorded id (if any) is the
    /// listed one.
    static func serverFile(of resource: LocalAsset.Resource, entries: [BackupLedgerEntry], server: [String: ServerFileInfo])
        -> ServerFileInfo?
    {
        guard let entry = entries.first(where: { $0.resourceKind == resource.kind.rawValue }), BackupDeviceState.isComplete(entry),
            let path = entry.serverPath, let file = server[BackupFolder.normalized(path)]
        else { return nil }
        if let recorded = entry.serverFileId, let listed = file.fileId, recorded != listed { return nil }
        return file
    }

    /// The device's data matches every checksum the server keeps of the asset's files. A file without a checksum on the
    /// server, or whose data is not on the device, was checked by size.
    static func checksumsMatch(
        _ asset: LocalAsset, entries: [BackupLedgerEntry], server: [String: ServerFileInfo], digester: any ResourceDigesting
    ) async throws -> Bool {
        for resource in asset.required {
            guard let file = serverFile(of: resource, entries: entries, server: server), let expected = file.preferredChecksum else {
                continue
            }
            let reference = DeviceResourceReference(localIdentifier: asset.localIdentifier, kind: resource.kind, index: resource.index)
            guard let digest = try await digester.digest(of: reference, algorithm: expected.algorithm) else { continue }
            if digest.lowercased() != expected.digest { return false }
        }
        return true
    }

    /// The folders whose listing the check needs.
    static func folders(of entries: [BackupLedgerEntry]) -> Set<String> {
        Set(entries.compactMap { $0.serverPath.map { (BackupFolder.normalized($0) as NSString).deletingLastPathComponent } })
    }

    /// Applies the rules to local assets: the keep options and the ledger first, then the server's listing of the folders
    /// of what is left, then (with a digester) the checksums.
    ///
    /// - Parameter progress: folders listed; with a digester then assets hashed.
    static func plan(
        _ assets: [LocalAsset], ledger: [String: [BackupLedgerEntry]], options: FreeUpOptions, listing: any ServerFileListing,
        digester: (any ResourceDigesting)? = nil, now: Date, progress: @Sendable (FreeUpProgress) -> Void = { _ in }
    ) async throws -> FreeUpPlan {
        var plan = FreeUpPlan()
        var open: [LocalAsset] = []
        for asset in assets {
            if let reason = keepReason(asset, entries: ledger[asset.localIdentifier] ?? [], options: options, now: now) {
                plan.kept[reason, default: FreeUpTally()].add(asset.totalSize)
            } else {
                open.append(asset)
            }
        }
        let folders = folders(of: open.flatMap { ledger[$0.localIdentifier] ?? [] }).sorted()
        var server: [String: ServerFileInfo] = [:]
        for (index, folder) in folders.enumerated() {
            try Task.checkCancellation()
            server.merge(try await listing.files(in: folder)) { $1 }
            progress(.listing(done: index + 1, total: folders.count))
        }
        var verified: [LocalAsset] = []
        for asset in open {
            if isVerified(asset, entries: ledger[asset.localIdentifier] ?? [], server: server) {
                verified.append(asset)
            } else {
                plan.kept[.notVerified, default: FreeUpTally()].add(asset.totalSize)
            }
        }
        if let digester {
            var matching: [LocalAsset] = []
            for (index, asset) in verified.enumerated() {
                try Task.checkCancellation()
                if try await checksumsMatch(asset, entries: ledger[asset.localIdentifier] ?? [], server: server, digester: digester) {
                    matching.append(asset)
                } else {
                    plan.kept[.notVerified, default: FreeUpTally()].add(asset.totalSize)
                }
                progress(.hashing(done: index + 1, total: verified.count))
            }
            verified = matching
        }
        plan.candidates = verified.map {
            FreeUpCandidate(localIdentifier: $0.localIdentifier, byteSize: $0.totalSize, createdAt: $0.createdAt)
        }
        .sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
        return plan
    }

    /// The estimate from the ledger alone: the keep rules, and the sizes the ledger recorded for the files.
    static func estimate(_ assets: [LocalAsset], ledger: [String: [BackupLedgerEntry]], options: FreeUpOptions, now: Date)
        -> FreeUpEstimate
    {
        var estimate = FreeUpEstimate(count: 0, bytes: 0)
        for asset in assets where keepReason(asset, entries: ledger[asset.localIdentifier] ?? [], options: options, now: now) == nil {
            estimate.count += 1
            estimate.bytes += asset.totalSize
        }
        return estimate
    }

    /// The size a ledger entry recorded (`size:<bytes>`).
    static func recordedSize(_ entry: BackupLedgerEntry) -> Int64? {
        guard let fingerprint = entry.fingerprint, fingerprint.hasPrefix("size:") else { return nil }
        return Int64(fingerprint.dropFirst("size:".count))
    }

    // MARK: PhotoKit

    /// Reads the ledger's complete assets from the device's library, 500 at a time.
    static func localAssets(_ ids: [String], make: (PHAsset) -> LocalAsset) throws -> [LocalAsset] {
        var assets: [LocalAsset] = []
        for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
            try Task.checkCancellation()
            var fetched: [PHAsset] = []
            PHAsset.fetchAssets(withLocalIdentifiers: chunk, options: nil).enumerateObjects { asset, _, _ in fetched.append(asset) }
            assets += fetched.map(make)
        }
        return assets
    }

    /// The device's photos that may be removed and those that stay (oldest first), checked with the server now.
    ///
    /// - Parameters:
    ///   - settings: the backup options; which files of an asset must be on the server does not depend on them (always
    ///     the original, an edited version, a RAW file and a Live Photo's motion).
    ///   - progress: folders checked on the server, of how many.
    public static func plan(
        ledger: [String: [BackupLedgerEntry]], settings: BackupSettings, options: FreeUpOptions, listing: any ServerFileListing,
        now: Date = Date(), progress: @escaping @Sendable (FreeUpProgress) -> Void = { _ in }
    ) async throws -> FreeUpPlan {
        let assets = try localAssets(ledgerCandidates(ledger)) { localAsset($0, settings: settings) }
        return try await plan(assets, ledger: ledger, options: options, listing: listing, now: now, progress: progress)
    }

    /// Checks the chosen candidates once more right before they are removed: the keep rules (a photo may have become a
    /// favourite meanwhile), the server's listing and, where the server keeps one, the checksum of each file.
    ///
    /// - Parameter progress: folders listed, then photos hashed.
    public static func recheck(
        _ candidates: [FreeUpCandidate], ledger: [String: [BackupLedgerEntry]], settings: BackupSettings, options: FreeUpOptions,
        listing: any ServerFileListing, digester: any ResourceDigesting = PhotoKitResourceDigester(), now: Date = Date(),
        progress: @escaping @Sendable (FreeUpProgress) -> Void = { _ in }
    ) async throws -> FreeUpPlan {
        let assets = try localAssets(candidates.map(\.localIdentifier)) { localAsset($0, settings: settings) }
        return try await plan(assets, ledger: ledger, options: options, listing: listing, digester: digester, now: now, progress: progress)
    }

    /// The quick estimate (no server, no file reads): PhotoKit's flags of the ledger's complete assets and the sizes the
    /// ledger recorded.
    public static func estimate(ledger: [String: [BackupLedgerEntry]], options: FreeUpOptions, now: Date = Date()) throws
        -> FreeUpEstimate
    {
        let assets = try localAssets(ledgerCandidates(ledger)) { asset in
            let entries = ledger[asset.localIdentifier] ?? []
            // The files are those the ledger has: an edit it lacks shows up through the edit rule, any other missing file
            // (and a Live Photo's edited motion) only in the real check.
            return flags(
                of: asset,
                LocalAsset(
                    localIdentifier: asset.localIdentifier, createdAt: asset.creationDate,
                    required: entries.compactMap { entry in
                        BackupResourceKind(rawValue: entry.resourceKind).map {
                            LocalAsset.Resource(kind: $0, byteSize: recordedSize(entry))
                        }
                    },
                    totalSize: entries.reduce(0) { $0 + (recordedSize($1) ?? 0) }))
        }
        return estimate(assets, ledger: ledger, options: options, now: now)
    }

    /// PhotoKit's flags that the keep rules read.
    static func flags(of asset: PHAsset, _ local: LocalAsset) -> LocalAsset {
        var local = local
        local.isFavorite = asset.isFavorite
        local.isHidden = asset.isHidden
        local.isInUserLibrary = asset.sourceType.contains(.typeUserLibrary)
        local.isUserEdited = asset.adjustmentsState == .userAdjusted
        local.editedAt = asset.adjustmentTimestamp
        return local
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
                type: resource.type, name: PhotoLibrarySource.fileName(of: resource), uniformTypeIdentifier: resource.uniformTypeIdentifier,
                byteSize: PhotoLibrarySource.byteSize(of: resource))
        }
        let required = PhotoLibrarySource.select(info, resources: described, settings: all).map {
            LocalAsset.Resource(kind: $0.resource.kind, byteSize: $0.resource.byteSize, index: $0.index)
        }
        return flags(
            of: asset,
            LocalAsset(
                localIdentifier: asset.localIdentifier, createdAt: asset.creationDate, required: required,
                totalSize: described.reduce(0) { $0 + ($1.byteSize ?? 0) },
                hasUnbackedResource: resources.contains { $0.type == .fullSizePairedVideo }))
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
