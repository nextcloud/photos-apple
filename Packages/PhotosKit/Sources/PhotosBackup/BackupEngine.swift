// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import Network
import OSLog
import Photos
import PhotosModel
import PhotosNetworking
import PhotosStore

/// Backup progress shown in the UI (SPEC §7.18.7).
public struct BackupStatus: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case idle
        case notAuthorized
        case scanning
        case reconciling(checked: Int, total: Int)
        case uploading(done: Int, total: Int, current: String)
        case paused(String)
        case upToDate
        case failed(String)
    }

    public var phase: Phase = .idle
    public var uploaded = 0
    public var matched = 0
    public var pending = 0
    public var failed = 0
    public var lastRun: Date?

    public init() {}
}

/// Per-resource state in the `backupAsset` table (SPEC §7.18.3).
public enum BackupItemState: String, Codable, Sendable {
    case pending, uploaded, matched, failed, skipped
}

public struct BackupLedgerEntry: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    public static let databaseTableName = "backupAsset"
    public var localIdentifier: String
    public var resourceKind: String
    public var fingerprint: String?
    public var state: String
    public var serverPath: String?
    public var serverFileId: Int64?
    public var serverEtag: String?
    public var matchedBy: String?
    public var attempts: Int
    public var lastError: String?
    public var assetCreatedAt: Double?
    public var assetModifiedAt: Double?
    public var updatedAt: Double
}

/// Camera-roll backup with duplicate protection (SPEC §7.18).
public actor BackupEngine {
    let api: PhotosAPI
    let database: AccountDatabase
    let library: LibraryStore
    let accountId: AccountID
    let source = PhotoLibrarySource()
    private let logger = Logger(subsystem: "com.nextcloud.photos", category: "backup")
    private var running: Task<Void, Never>?
    private var status = BackupStatus()
    private var statusHandler: (@Sendable (BackupStatus) -> Void)?
    private let pathMonitor = NWPathMonitor()
    private var path: NWPath?
    var metadataEditing = false

    public init(api: PhotosAPI, database: AccountDatabase, accountId: AccountID) {
        self.api = api
        self.database = database
        self.library = LibraryStore(database: database)
        self.accountId = accountId
        pathMonitor.pathUpdateHandler = { [weak self] path in Task { await self?.setPath(path) } }
        pathMonitor.start(queue: DispatchQueue(label: "com.nextcloud.photos.backup.path"))
    }

    private func setPath(_ path: NWPath) { self.path = path }

    public func setStatusHandler(_ handler: @escaping @Sendable (BackupStatus) -> Void) {
        statusHandler = handler
        handler(status)
    }

    public func setMetadataEditing(_ enabled: Bool) { metadataEditing = enabled }

    private func publish(_ phase: BackupStatus.Phase) {
        status.phase = phase
        statusHandler?(status)
    }

    // MARK: Run

    /// Scans, reconciles and uploads. With `dryRun` only reconciles (status for "keep using Files", SPEC §7.18.1).
    public func run(_ settings: BackupSettings, dryRun: Bool = false) async {
        if let running {
            await running.value
            return
        }
        let task = Task { await self.perform(settings, dryRun: dryRun) }
        running = task
        await task.value
        running = nil
    }

    public func cancel() { running?.cancel() }

    /// Cancels a running pass and waits until it has stopped (account removal).
    public func shutdown() async {
        running?.cancel()
        await running?.value
    }

    private func perform(_ settings: BackupSettings, dryRun: Bool) async {
        guard PhotoLibrarySource.authorization == .authorized || PhotoLibrarySource.authorization == .limited else {
            publish(.notAuthorized)
            return
        }
        publish(.scanning)
        do {
            var work: [BackupResource] = []
            let ledger = try loadLedger()
            let filesUploaded = settings.filesAppMode == .notUsed ? [] : FilesAppLedger.uploadedAssets(accountId: accountId)
            for asset in source.assets(settings) {
                for (resource, _) in source.resources(of: asset, settings: settings) {
                    let key = LedgerKey(localIdentifier: resource.localIdentifier, kind: resource.kind.rawValue)
                    if let entry = ledger[key],
                        entry.state == BackupItemState.uploaded.rawValue || entry.state == BackupItemState.matched.rawValue
                    {
                        // A newer edit replaces the edited rendition only.
                        let isNewEdit =
                            resource.kind == .edited && (resource.modifiedAt?.timeIntervalSince1970 ?? 0) > (entry.assetModifiedAt ?? 0) + 1
                        if !isNewEdit { continue }
                    }
                    if filesUploaded.contains(resource.localIdentifier) {
                        try record(resource, state: .matched, matchedBy: .filesLedger)
                        continue
                    }
                    work.append(resource)
                }
            }
            try Task.checkCancellation()
            let toUpload = try await reconcile(work)
            status.pending = toUpload.count
            try refreshCounts()
            if dryRun || toUpload.isEmpty {
                status.lastRun = Date()
                publish(toUpload.isEmpty ? .upToDate : .idle)
                return
            }
            try await upload(toUpload, settings: settings)
            status.lastRun = Date()
            try refreshCounts()
            publish(status.pending == 0 ? .upToDate : .idle)
        } catch is CancellationError {
            publish(.paused(String(localized: "Paused")))
        } catch let error as NetworkError where error == .offline {
            publish(.paused(String(localized: "Waiting for a network connection")))
        } catch {
            logger.error("backup failed: \(error.localizedDescription, privacy: .public)")
            publish(.failed(error.localizedDescription))
        }
    }

    // MARK: Reconciliation (SPEC §7.18.4 layer 4)

    /// Returns the resources that are not on the server yet; records the matched ones.
    func reconcile(_ work: [BackupResource]) async throws -> [BackupResource] {
        // Batches of ≤ 200 resources spanning ≤ 7 days, so each SEARCH stays small.
        var batches: [[BackupResource]] = []
        for resource in work {
            if let first = batches.last?.first, batches[batches.count - 1].count < 200,
                resource.createdAt.timeIntervalSince(first.createdAt) <= 7 * 86_400
            {
                batches[batches.count - 1].append(resource)
            } else {
                batches.append([resource])
            }
        }
        var remaining: [BackupResource] = []
        var checked = 0
        for batch in batches {
            try Task.checkCancellation()
            guard let first = batch.first?.createdAt, let last = batch.last?.createdAt else { continue }
            let candidates = try await serverCandidates(from: first.addingTimeInterval(-2), to: last.addingTimeInterval(2))
            let locals = batch.map(\.local)
            for resource in batch {
                if let (candidate, reason) = BackupMatcher.match(resource.local, candidates: candidates, localSiblings: locals) {
                    try record(resource, state: .matched, matchedBy: reason, serverPath: candidate.path, serverFileId: candidate.fileId)
                } else {
                    remaining.append(resource)
                }
            }
            checked += batch.count
            publish(.reconciling(checked: checked, total: work.count))
        }
        return remaining
    }

    /// All media in the user's files whose capture time or modification time lies in the window.
    func serverCandidates(from start: Date, to end: Date) async throws -> [RemoteCandidate] {
        let mimes =
            MimeTypes.defaultImages + MimeTypes.extendedImages + MimeTypes.appleExtras + MimeTypes.defaultVideos + MimeTypes.extendedVideos
        let startSeconds = start.timeIntervalSince1970
        let endSeconds = end.timeIntervalSince1970
        // Also look 14 h around for EXIF times read without their offset.
        let search = DAVSearch(
            select: [
                DAVProp.fileId, DAVProp.contentType, DAVProp.size, DAVProp.lastModified, DAVProp.metadataOriginalDateTime,
                DAVProp.metadataSize,
            ],
            scopes: [DAVSearch.Scope(href: api.connection.filesHref("/"))],
            condition: .and([
                PhotosAPI.mimeCondition(mimes),
                .or([
                    .and([
                        .gte(DAVProp.metadataOriginalDateTime, String(Int64(startSeconds - 14 * 3600))),
                        .lte(DAVProp.metadataOriginalDateTime, String(Int64(endSeconds + 14 * 3600))),
                    ]),
                    .and([.gte(DAVProp.lastModified, Self.iso(startSeconds)), .lte(DAVProp.lastModified, Self.iso(endSeconds))]),
                ]),
            ])
        )
        return try await api.dav.search(search, timeout: 300).compactMap { resource in
            guard let item = MediaParser.mediaItem(from: resource, connection: api.connection) else { return nil }
            return RemoteCandidate(
                fileId: item.fileId, path: item.path, kind: item.kind, size: item.size, capturedAt: item.capturedAt,
                modifiedAt: item.modifiedAt,
                width: item.width, height: item.height)
        }
    }

    static func iso(_ seconds: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date(timeIntervalSince1970: seconds))
    }

    // MARK: Upload

    func upload(_ work: [BackupResource], settings: BackupSettings) async throws {
        let uploader = Uploader(dav: api.dav)
        var done = 0
        var stills: [String: UploadedFile] = [:]
        var motions: [String: UploadedFile] = [:]
        for resource in work {
            try Task.checkCancellation()
            if let reason = pauseReason(settings, isVideo: resource.mediaKind == .video) {
                publish(.paused(reason))
                return
            }
            publish(.uploading(done: done, total: work.count, current: resource.originalName))
            var file: URL?
            do {
                var exported = try await source.export(resource, settings: settings)
                file = exported
                if settings.format == .mostCompatible, resource.mediaKind == .image, resource.kind != .raw {
                    exported = try PhotoLibrarySource.convertToJPEG(exported)
                    file = exported
                }
                let name = BackupNaming.fileName(
                    originalName: resource.originalName, fileExtension: exported.pathExtension, isVideo: resource.mediaKind == .video,
                    date: resource.createdAt, naming: settings.naming)
                let folder = BackupNaming.folder(base: settings.folder, subfolders: settings.subfolders, date: resource.createdAt)
                // Layer 5: an existing file with the same name and size counts as uploaded; otherwise " (2)".
                let uploaded = try await uploader.upload(
                    file: exported, fileName: name, folder: folder, capturedAt: resource.createdAt, conflict: .skipIfSameSize)
                try record(resource, state: .uploaded, matchedBy: .ownUpload, serverPath: uploaded.path, serverFileId: uploaded.fileId)
                status.uploaded += 1
                if resource.kind == .photo || resource.kind == .edited { stills[resource.localIdentifier] = uploaded }
                if resource.kind == .pairedVideo { motions[resource.localIdentifier] = uploaded }
                if let still = stills[resource.localIdentifier], let motion = motions[resource.localIdentifier] {
                    try? await api.linkLivePhoto(
                        imagePath: still.path, imageFileId: still.fileId, videoPath: motion.path, videoFileId: motion.fileId)
                }
                await afterUpload(uploaded, resource: resource)
            } catch let error as NetworkError where error.isTransient {
                if let file { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
                throw error
            } catch {
                logger.error(
                    "backup of \(resource.originalName, privacy: .private) failed: \(error.localizedDescription, privacy: .public)")
                try? record(resource, state: .failed, error: error.localizedDescription)
                status.failed += 1
            }
            if let file { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            done += 1
            status.pending = max(0, status.pending - 1)
        }
    }

    /// Puts the new file into the local index; fixes capture time and GPS the server could not read (SPEC §7.18.6).
    func afterUpload(_ uploaded: UploadedFile, resource: BackupResource) async {
        guard let item = try? await api.items(fileIds: [uploaded.fileId], properties: DAVProp.mediaIndex).first else { return }
        try? library.upsert([item])
        guard metadataEditing, resource.mediaKind == .image, !item.hasLocation, let latitude = resource.latitude,
            let longitude = resource.longitude
        else { return }
        try? await api.setMetadata(userPath: item.path, latitude: latitude, longitude: longitude)
    }

    func pauseReason(_ settings: BackupSettings, isVideo: Bool) -> String? {
        guard let path else { return nil }
        if path.status != .satisfied { return String(localized: "Waiting for a network connection") }
        let onWiFiLike = !path.isExpensive
        if (settings.wifiOnly || (isVideo && settings.wifiOnlyForVideos)) && !onWiFiLike { return String(localized: "Waiting for Wi-Fi") }
        if path.isConstrained && !settings.allowLowDataMode { return String(localized: "Paused in Low Data Mode") }
        if settings.pauseInLowPowerMode && ProcessInfo.processInfo.isLowPowerModeEnabled {
            return String(localized: "Paused in Low Power Mode")
        }
        return nil
    }

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

    func record(
        _ resource: BackupResource, state: BackupItemState, matchedBy: MatchReason? = nil, serverPath: String? = nil,
        serverFileId: FileID? = nil,
        error: String? = nil
    ) throws {
        try database.writer.write { db in
            let previous = try BackupLedgerEntry.fetchOne(
                db, key: ["localIdentifier": resource.localIdentifier, "resourceKind": resource.kind.rawValue])
            let entry = BackupLedgerEntry(
                localIdentifier: resource.localIdentifier, resourceKind: resource.kind.rawValue, fingerprint: nil, state: state.rawValue,
                serverPath: serverPath ?? previous?.serverPath, serverFileId: serverFileId ?? previous?.serverFileId, serverEtag: nil,
                matchedBy: matchedBy?.rawValue ?? previous?.matchedBy, attempts: (previous?.attempts ?? 0) + (state == .failed ? 1 : 0),
                lastError: error, assetCreatedAt: resource.createdAt.timeIntervalSince1970,
                assetModifiedAt: resource.modifiedAt?.timeIntervalSince1970, updatedAt: Date().timeIntervalSince1970)
            try entry.upsert(db)
        }
    }

    func refreshCounts() throws {
        let counts = try database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT state, count(*) AS n FROM backupAsset GROUP BY state").reduce(into: [String: Int]()) {
                $0[$1["state"]] = $1["n"]
            }
        }
        status.uploaded = counts[BackupItemState.uploaded.rawValue] ?? 0
        status.matched = counts[BackupItemState.matched.rawValue] ?? 0
        status.failed = counts[BackupItemState.failed.rawValue] ?? 0
    }

    /// Ledger entries for the details list.
    public func entries(limit: Int = 500) throws -> [BackupLedgerEntry] {
        try database.writer.read { db in try BackupLedgerEntry.order(Column("updatedAt").desc).limit(limit).fetchAll(db) }
    }

    /// Lets the user force-upload a resource that was matched (SPEC §7.18.4).
    public func forgetMatch(localIdentifier: String, kind: String) throws {
        try database.writer.write { db in
            _ = try BackupLedgerEntry.deleteOne(db, key: ["localIdentifier": localIdentifier, "resourceKind": kind])
        }
    }

    public func reset() throws {
        try database.writer.write { db in try db.execute(sql: "DELETE FROM backupAsset") }
        status = BackupStatus()
    }
}
