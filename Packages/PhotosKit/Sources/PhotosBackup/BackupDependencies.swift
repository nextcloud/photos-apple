// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel
import PhotosNetworking
import PhotosStore

/// The device photo library as the backup engine sees it. `PhotoLibrarySource` is the real one; tests use a fake,
/// because PhotoKit cannot run in unit tests.
protocol BackupLibrary: Sendable {
    var isAuthorized: Bool { get }

    /// Resources of the assets selected by the settings, oldest first.
    ///
    /// `needsScan(localIdentifier, modificationDate)` is asked for every asset before its resources are read; reading them is
    /// the expensive part of a scan, so assets the ledger already knows completely are left out.
    func scan(_ settings: BackupSettings, needsScan: (String, Date?) -> Bool) -> [BackupResource]

    /// Writes the resource into a file in a directory of its own (the engine deletes that directory afterwards).
    func export(_ resource: BackupResource, settings: BackupSettings) async throws -> URL
}

/// The server as the backup engine sees it.
protocol BackupRemote: Sendable {
    /// All media in the user's files whose capture time or modification time lies in the window.
    func candidates(from start: Date, to end: Date) async throws -> [RemoteCandidate]

    /// Uploads a file; an existing file with the same name and size counts as uploaded (SPEC §7.18.4 layer 5).
    func upload(file: URL, fileName: String, folder: String, capturedAt: Date) async throws -> UploadedFile

    func linkLivePhoto(imagePath: String, imageFileId: FileID, videoPath: String, videoFileId: FileID) async throws

    /// Puts the new file into the local index; fixes metadata the server could not read (SPEC §7.18.6).
    func didUpload(_ uploaded: UploadedFile, resource: BackupResource, metadataEditing: Bool) async
}

/// The real server.
struct PhotosBackupRemote: BackupRemote {
    let api: PhotosAPI
    let library: LibraryStore

    func candidates(from start: Date, to end: Date) async throws -> [RemoteCandidate] {
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
                    .and([
                        .gte(DAVProp.lastModified, PhotosAPI.isoDate(startSeconds)),
                        .lte(DAVProp.lastModified, PhotosAPI.isoDate(endSeconds)),
                    ]),
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

    func upload(file: URL, fileName: String, folder: String, capturedAt: Date) async throws -> UploadedFile {
        try await Uploader(dav: api.dav).upload(
            file: file, fileName: fileName, folder: folder, capturedAt: capturedAt, conflict: .skipIfSameSize)
    }

    func linkLivePhoto(imagePath: String, imageFileId: FileID, videoPath: String, videoFileId: FileID) async throws {
        try await api.linkLivePhoto(imagePath: imagePath, imageFileId: imageFileId, videoPath: videoPath, videoFileId: videoFileId)
    }

    func didUpload(_ uploaded: UploadedFile, resource: BackupResource, metadataEditing: Bool) async {
        guard let item = try? await api.items(fileIds: [uploaded.fileId], properties: DAVProp.mediaIndex).first else { return }
        try? library.upsert([item])
        guard metadataEditing, resource.mediaKind == .image, !item.hasLocation, let latitude = resource.latitude,
            let longitude = resource.longitude
        else { return }
        try? await api.setMetadata(userPath: item.path, latitude: latitude, longitude: longitude)
    }
}

// MARK: - Conditions

/// The part of the network path the backup rules look at.
struct BackupNetwork: Sendable, Equatable {
    var isConnected = true
    /// Cellular or a personal hotspot.
    var isExpensive = false
    /// Low Data Mode.
    var isConstrained = false
}

/// Why uploads wait.
enum BackupPause: Sendable, Equatable {
    case offline, wifi, lowData, lowPower, user

    var message: String {
        switch self {
        case .offline: String(localized: "Waiting for a network connection")
        case .wifi: String(localized: "Waiting for Wi-Fi")
        case .lowData: String(localized: "Paused in Low Data Mode")
        case .lowPower: String(localized: "Paused in Low Power Mode")
        case .user: String(localized: "Paused")
        }
    }
}

/// Pure decisions of the backup run, so they are unit-tested.
enum BackupPolicy {
    /// Whether a resource may be uploaded now. An unknown network (`nil`, before the first path update) does not hold uploads back.
    static func pauseReason(_ settings: BackupSettings, network: BackupNetwork?, lowPower: Bool, isVideo: Bool) -> BackupPause? {
        if let network {
            if !network.isConnected { return .offline }
            if (settings.wifiOnly || (isVideo && settings.wifiOnlyForVideos)) && network.isExpensive { return .wifi }
            if network.isConstrained && !settings.allowLowDataMode { return .lowData }
        }
        if settings.pauseInLowPowerMode && lowPower { return .lowPower }
        return nil
    }

    // MARK: Failures

    /// Errors that will hit every other file as well: the run stops instead of exporting and failing the whole library.
    static func blocker(for error: any Error) -> BackupStatus.Blocker? {
        guard let error = error as? NetworkError else { return nil }
        switch error {
        case .insufficientStorage: return .insufficientStorage
        case .unauthorized: return .unauthorized
        case .forbidden: return .forbidden
        case .untrustedCertificate, .clientCertificateRequired: return .serverTrust
        default: return nil
        }
    }

    static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let error = error as? NetworkError, error == .cancelled { return true }
        return (error as? URLError)?.code == .cancelled
    }

    static let retryBase: TimeInterval = 15 * 60
    static let retryCap: TimeInterval = 24 * 3600

    /// How long a failed resource waits before its next attempt: 15 min, 1 h, 4 h, 16 h, then once a day.
    static func retryDelay(attempts: Int) -> TimeInterval {
        guard attempts > 0 else { return 0 }
        return min(retryCap, retryBase * pow(4, Double(min(attempts, 8) - 1)))
    }

    static func isBackingOff(_ entry: BackupLedgerEntry, now: Date) -> Bool {
        entry.state == BackupItemState.failed.rawValue
            && now.timeIntervalSince1970 < entry.updatedAt + retryDelay(attempts: entry.attempts)
    }

    // MARK: Scan

    static func isComplete(_ entry: BackupLedgerEntry) -> Bool {
        entry.state == BackupItemState.uploaded.rawValue || entry.state == BackupItemState.matched.rawValue
    }

    /// PhotoKit modification dates against what the ledger stored (seconds; both may be missing).
    static func isModified(_ modifiedAt: Date?, since stored: Double?) -> Bool {
        switch (modifiedAt?.timeIntervalSince1970, stored) {
        case (nil, nil): false
        case (let current?, let stored?): abs(current - stored) > 1
        default: true
        }
    }

    /// Whether an asset's resources have to be read: not when every resource the ledger knows is done (or failed and still
    /// backing off) and the asset has not changed since.
    static func needsScan(entries: [BackupLedgerEntry], modifiedAt: Date?, now: Date) -> Bool {
        if entries.isEmpty { return true }
        return entries.contains { entry in
            if isModified(modifiedAt, since: entry.assetModifiedAt) { return true }
            return !(isComplete(entry) || isBackingOff(entry, now: now))
        }
    }

    /// What a run does with one resource.
    enum Action: Equatable {
        /// Nothing to do.
        case done
        /// Nothing to upload, but the asset changed: remember its new modification date, so the next scan can skip it.
        case touch
        /// Failed before, not due yet.
        case waiting
        /// Check the server, upload when it is not there.
        case reconcile
        /// Upload without asking the matcher (a new edit, or the user's "Upload anyway").
        case upload
    }

    static func action(for resource: BackupResource, entry: BackupLedgerEntry?, now: Date, retryFailed: Bool = false) -> Action {
        guard let entry else { return .reconcile }
        let modified = isModified(resource.modifiedAt, since: entry.assetModifiedAt)
        // The server still has the previous edit under the same name and capture time, so the matcher must not be asked.
        let replacesEdit = resource.isEdit && entry.serverFileId != nil
        switch BackupItemState(rawValue: entry.state) {
        case .uploaded, .matched:
            if isMismatch(resource, entry: entry) { return .reconcile }
            if modified, resource.isEdit {
                // Favouriting also changes the modification date; the same size means it is still the same edit.
                let sameData = resource.sizeFingerprint != nil && resource.sizeFingerprint == entry.fingerprint
                if !sameData, (resource.modifiedAt?.timeIntervalSince1970 ?? 0) > (entry.assetModifiedAt ?? 0) + 1 { return .upload }
            }
            return modified ? .touch : .done
        case .failed:
            if !modified, !retryFailed, isBackingOff(entry, now: now) { return .waiting }
            return replacesEdit ? .upload : .reconcile
        case .pending where entry.matchedBy == MatchReason.user.rawValue:
            return .upload
        default:
            return replacesEdit ? .upload : .reconcile
        }
    }

    /// Earlier versions matched an edit or a RAW with the original on the server (same second, same number) and never
    /// uploaded it. Such an entry is checked again; a match by the same byte size stays.
    static func isMismatch(_ resource: BackupResource, entry: BackupLedgerEntry) -> Bool {
        guard entry.state == BackupItemState.matched.rawValue, let path = entry.serverPath,
            entry.matchedBy == MatchReason.serverTimeName.rawValue || entry.matchedBy == MatchReason.serverTimeSize.rawValue
        else { return false }
        let name = (path as NSString).lastPathComponent
        if BackupMatcher.isRaw(resource.local) != BackupMatcher.isRawName(name) { return true }
        return resource.isEdit && !BackupMatcher.isEditedName(name)
    }

    /// The settings that decide which resources an asset has; when they change, every asset is scanned again.
    static func scanSignature(_ settings: BackupSettings) -> String {
        "v1|\(settings.edits.rawValue)|\(settings.livePhotos)"
    }
}
