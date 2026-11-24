// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import OSLog
import PhotosModel
import PhotosNetworking
import PhotosStore

/// Where the files of a card come from: a mounted card or a folder (read in place), or a camera (each file is
/// downloaded to this Mac or iPad first).
public protocol CardImportSource: Sendable {
    /// A local file with the item's bytes; `isTemporary` files are removed after the upload.
    func localFile(for item: CardItem, in temporary: URL) async throws -> (url: URL, isTemporary: Bool)
    /// Deletes these files from the card (only ever ones verified on the server).
    func delete(_ items: [CardItem]) async throws
}

/// How a file was found to be safely on the server.
public enum CardVerification: Equatable, Sendable {
    /// The server has the file with the SHA-256 the app computed from the card's bytes.
    case checksum
    /// The server has the file with the same size (it keeps no checksum).
    case size
    /// Size or checksum differ: the file is not deleted from the card.
    case mismatch
}

/// The server as the import sees it; tests use a fake.
public protocol CardImportRemote: Sendable {
    /// Media files captured (or modified) in the window, for "already on the server".
    func candidates(from start: Date, to end: Date) async throws -> [RemoteCandidate]
    /// Uploads; a file of the same name and size in the folder counts as this one (nothing is uploaded twice).
    func upload(file: URL, fileName: String, folder: String, capturedAt: Date?, progress: (@Sendable (Double) -> Void)?) async throws
        -> UploadedFile
    func verify(_ uploaded: UploadedFile, size: Int64, sha256: String?) async throws -> CardVerification
    /// Puts the new file into the local index at once.
    func didUpload(_ uploaded: UploadedFile) async
}

/// How a card is imported.
public struct CardImportOptions: Hashable, Sendable, Codable {
    public var destination: DestinationPattern
    /// The camera's name for `{camera}`.
    public var cameraName: String?
    /// After every file of the import is verified on the server, the imported files are deleted from the card.
    public var deleteAfterVerifiedUpload: Bool

    public init(destination: DestinationPattern = .default, cameraName: String? = nil, deleteAfterVerifiedUpload: Bool = false) {
        self.destination = destination
        self.cameraName = cameraName
        self.deleteAfterVerifiedUpload = deleteAfterVerifiedUpload
    }
}

/// What the import has done so far.
public struct CardImportProgress: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case importing, deleting, finished, cancelled
        /// Stopped by something that affects every file (login, full storage, offline).
        case stopped(String)
    }

    public var phase: Phase = .importing
    public var totalFiles = 0
    public var totalBytes: Int64 = 0
    public var processedFiles = 0
    public var processedBytes: Int64 = 0
    public var uploaded = 0
    /// Already on the server: not uploaded again.
    public var skipped = 0
    public var failed = 0
    public var verified = 0
    public var deleted = 0
    /// Files that could not be deleted from the card, or were not because they could not be verified.
    public var keptOnCard = 0
    public var currentName: String?
    public var failures: [String] = []

    public init() {}

    public var fraction: Double { totalBytes > 0 ? min(Double(processedBytes) / Double(totalBytes), 1) : (totalFiles == 0 ? 1 : 0) }
    public var isRunning: Bool { phase == .importing || phase == .deleting }
}

/// Imports photos from a memory card or camera into the user's Nextcloud (SPEC §15.2): into date folders from a
/// pattern, RAW and JPEG of a shot together, nothing that is already there, every upload verified; optionally the
/// imported files are deleted from the card afterwards — only those verified on the server.
public actor CardImporter {
    let remote: any CardImportRemote
    let source: any CardImportSource
    let options: CardImportOptions
    let ledgerURL: URL
    private var ledger: CardImportLedger
    private var progress = CardImportProgress()
    private let logger = Logger(subsystem: "com.nextcloud.photos", category: "card-import")

    public init(remote: any CardImportRemote, source: any CardImportSource, options: CardImportOptions, ledgerURL: URL) {
        self.remote = remote
        self.source = source
        self.options = options
        self.ledgerURL = ledgerURL
        ledger = CardImportLedger.load(from: ledgerURL)
    }

    /// For the app: imports into the account behind `api`.
    public init(
        api: PhotosAPI, database: AccountDatabase, source: any CardImportSource, options: CardImportOptions, ledgerURL: URL
    ) {
        self.init(
            remote: PhotosCardImportRemote(api: api, library: LibraryStore(database: database), database: database), source: source,
            options: options, ledgerURL: ledgerURL)
    }

    // MARK: Already on the server

    /// The items that are on the server already: imported before (the ledger), or a file the backup's matching rules
    /// find on the server (same capture second and size, or name…), so "new only" leaves them out.
    ///
    /// Offline, only the ledger answers.
    public func alreadyImported(_ items: [CardItem]) async -> Set<String> {
        var found = Set(items.filter { ledger.contains($0) }.map(\.id))
        let rest = items.filter { !found.contains($0.id) && $0.capturedAt != nil }
        for window in Self.windows(rest) {
            guard !Task.isCancelled else { break }
            let dates = window.compactMap(\.capturedAt)
            guard let first = dates.min(), let last = dates.max() else { continue }
            guard let candidates = try? await remote.candidates(from: first.addingTimeInterval(-2), to: last.addingTimeInterval(2))
            else { break }
            var index = BackupMatcher.Index(candidates: candidates, locals: window.map(\.resource))
            for item in window where index.match(item.resource) != nil || Self.sameFileInAnotherZone(item, candidates) {
                found.insert(item.id)
            }
        }
        return found
    }

    /// The same bytes on the server under another name, its capture time read in another time zone: cameras write
    /// local time without an offset, which the server may read as UTC. Same size and kind, and the times differ by whole
    /// hours (at most 14) with minutes and seconds equal.
    static func sameFileInAnotherZone(_ item: CardItem, _ candidates: [RemoteCandidate]) -> Bool {
        guard let date = item.capturedAt else { return false }
        return candidates.contains { candidate in
            guard candidate.size == item.size, candidate.kind == item.kind, let captured = candidate.capturedAt else { return false }
            let difference = abs(captured.timeIntervalSince(date).rounded())
            return difference <= 14 * 3600 && difference.truncatingRemainder(dividingBy: 3600) == 0
        }
    }

    /// Items in groups whose capture times lie within a day, so one server search covers a group (at most 300 items).
    static func windows(_ items: [CardItem]) -> [[CardItem]] {
        let sorted = items.sorted { ($0.capturedAt ?? .distantPast) < ($1.capturedAt ?? .distantPast) }
        var windows: [[CardItem]] = []
        var current: [CardItem] = []
        var start: Date?
        for item in sorted {
            if let start, let date = item.capturedAt, date.timeIntervalSince(start) <= 24 * 3600, current.count < 300 {
                current.append(item)
                continue
            }
            if !current.isEmpty { windows.append(current) }
            current = [item]
            start = item.capturedAt
        }
        if !current.isEmpty { windows.append(current) }
        return windows
    }

    // MARK: Import

    /// Errors after which no other file can be uploaded either.
    static func stopsImport(_ error: any Error) -> Bool {
        switch error as? NetworkError {
        case .unauthorized, .insufficientStorage, .offline, .untrustedCertificate, .clientCertificateRequired, .maintenance: true
        default: error is CancellationError
        }
    }

    /// Imports the groups (every file of each); returns when done or cancelled. The ledger is saved as it goes.
    public func run(_ groups: [CardGroup], onProgress: @escaping @Sendable (CardImportProgress) -> Void) async -> CardImportProgress {
        progress = CardImportProgress()
        progress.totalFiles = groups.reduce(0) { $0 + $1.items.count }
        progress.totalBytes = groups.reduce(0) { $0 + $1.size }
        onProgress(progress)
        let temporary = FileManager.default.temporaryDirectory.appending(path: "CardImport-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: temporary)
            try? ledger.save(to: ledgerURL)
        }
        var verified: [CardItem] = []
        do {
            for group in groups {
                let folder = options.destination.folder(for: group.capturedAt, camera: options.cameraName)
                for item in group.items {
                    try Task.checkCancellation()
                    if try await importItem(item, folder: folder, temporary: temporary, onProgress: onProgress) {
                        verified.append(item)
                    }
                }
                try? ledger.save(to: ledgerURL)
            }
            if options.deleteAfterVerifiedUpload {
                try await deleteFromCard(verified, onProgress: onProgress)
            }
            progress.phase = .finished
        } catch let error where error is CancellationError || (error as? NetworkError) == .cancelled {
            progress.phase = .cancelled
        } catch {
            logger.error("card import stopped: \(error.localizedDescription, privacy: .public)")
            progress.phase = .stopped(error.localizedDescription)
        }
        progress.currentName = nil
        onProgress(progress)
        return progress
    }

    /// Uploads one file and checks it on the server. True when it is verified there (uploaded now or before).
    func importItem(_ item: CardItem, folder: String, temporary: URL, onProgress: @escaping @Sendable (CardImportProgress) -> Void)
        async throws -> Bool
    {
        progress.currentName = item.name
        onProgress(progress)
        let startBytes = progress.processedBytes
        defer {
            progress.processedFiles += 1
            progress.processedBytes = startBytes + item.size
        }
        do {
            let (file, isTemporary) = try await source.localFile(for: item, in: temporary)
            defer { if isTemporary { try? FileManager.default.removeItem(at: file) } }
            let digest = try? Uploader.sha256(of: file)
            let base = progress
            let uploaded = try await remote.upload(
                file: file, fileName: item.name, folder: folder, capturedAt: item.capturedAt,
                progress: { fraction in
                    var running = base
                    running.processedBytes = startBytes + Int64(Double(item.size) * fraction)
                    onProgress(running)
                })
            switch try await remote.verify(uploaded, size: item.size, sha256: digest) {
            case .checksum, .size:
                progress.uploaded += 1
                progress.verified += 1
                ledger.record(item, path: uploaded.path)
                await remote.didUpload(uploaded)
                return true
            case .mismatch:
                progress.failed += 1
                note(
                    String(
                        localized: "\(item.name): the copy on the server differs from the card.", bundle: .module,
                        comment: "Card import failure: the file name. The file is not deleted from the card."))
                return false
            }
        } catch {
            if Self.stopsImport(error) { throw error }
            logger.error("card import: a file failed: \(error.localizedDescription, privacy: .public)")
            progress.failed += 1
            note("\(item.name): \(error.localizedDescription)")
            return false
        }
    }

    private func note(_ failure: String) {
        if progress.failures.count < 50 { progress.failures.append(failure) }
    }

    /// Deletes the verified files from the card, all at once (cameras delete in one request).
    func deleteFromCard(_ items: [CardItem], onProgress: @Sendable (CardImportProgress) -> Void) async throws {
        progress.keptOnCard = progress.totalFiles - items.count
        guard !items.isEmpty else { return }
        progress.phase = .deleting
        progress.currentName = nil
        onProgress(progress)
        do {
            try await source.delete(items)
            progress.deleted = items.count
        } catch {
            logger.error("card import: deleting from the card failed: \(error.localizedDescription, privacy: .public)")
            progress.keptOnCard = progress.totalFiles
            note(
                String(
                    localized: "The files could not be deleted from the card: \(error.localizedDescription)", bundle: .module,
                    comment: "Card import failure: the reason (from the system)."))
        }
    }

    /// Notes items as imported without uploading them (they were found on the server): "new only" skips them next time
    /// without a server search.
    public func recordExisting(_ items: [CardItem]) {
        for item in items where !ledger.contains(item) { ledger.record(item, path: "") }
        try? ledger.save(to: ledgerURL)
    }
}

/// The real server.
struct PhotosCardImportRemote: CardImportRemote {
    let api: PhotosAPI
    let library: LibraryStore
    let database: AccountDatabase

    static let checksums = QName(XMLNamespace.oc, "checksums")
    static let checksum = QName(XMLNamespace.oc, "checksum")

    func candidates(from start: Date, to end: Date) async throws -> [RemoteCandidate] {
        try await PhotosBackupRemote(api: api, library: library, database: database).candidates(from: start, to: end)
    }

    func upload(file: URL, fileName: String, folder: String, capturedAt: Date?, progress: (@Sendable (Double) -> Void)?) async throws
        -> UploadedFile
    {
        var uploader = Uploader(dav: api.dav)
        uploader.folders = BackupUploadFolders(database: database)
        return try await uploader.upload(
            file: file, fileName: fileName, folder: folder, capturedAt: capturedAt, conflict: .skipIfSameSize, progress: progress)
    }

    func verify(_ uploaded: UploadedFile, size: Int64, sha256: String?) async throws -> CardVerification {
        let resource = try await api.dav.propfind(
            api.connection.filesURL(uploaded.path), depth: 0, properties: [DAVProp.size, DAVProp.fileId, Self.checksums]
        ).first
        guard let resource, resource.int64(DAVProp.size) == size else { return .mismatch }
        return Self.verification(checksums: resource.node(Self.checksums), sha256: sha256)
    }

    /// `<oc:checksums><oc:checksum>SHA1:… MD5:… SHA256:…</oc:checksum></oc:checksums>`: a SHA-256 there must be ours.
    static func verification(checksums: PhotosNetworking.XMLNode?, sha256: String?) -> CardVerification {
        let values = (checksums?.children(checksum).map(\.value) ?? []) + [checksums?.value ?? ""]
        let entries = values.flatMap { $0.split(separator: " ") }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let stored = entries.first(where: { $0.uppercased().hasPrefix("SHA256:") }) else { return .size }
        guard let sha256 else { return .size }
        return stored.dropFirst("SHA256:".count).lowercased() == sha256.lowercased() ? .checksum : .mismatch
    }

    func didUpload(_ uploaded: UploadedFile) async {
        guard let item = try? await api.items(fileIds: [uploaded.fileId], properties: DAVProp.mediaIndex).first else { return }
        try? library.upsert([item])
    }
}
