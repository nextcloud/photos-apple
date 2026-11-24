// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import OSLog
import PhotosModel
import PhotosNetworking
import PhotosStore

/// An upload job of PhotoKit's background-upload service (`PHAssetResourceUploadJob`, SPEC §7.18.6), as the backup sees it.
public struct UploadJobInfo: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        /// Registered or pending: PhotoKit still works on it.
        case inFlight
        case succeeded
        case failed
        case cancelled
    }

    /// The job's local identifier.
    public var id: String
    /// Where PhotoKit sends (or sent) the resource.
    public var destination: URL?
    public var state: State
    /// The server's answer headers, lower-cased (`oc-fileid`), when the job has ended.
    public var responseHeaders: [String: String]
    /// Why it failed, as PhotoKit says it (sanitized).
    public var errorDescription: String?

    public init(
        id: String, destination: URL?, state: State, responseHeaders: [String: String] = [:], errorDescription: String? = nil
    ) {
        self.id = id
        self.destination = destination
        self.state = state
        self.responseHeaders = responseHeaders
        self.errorDescription = errorDescription
    }

    /// The file id the server sent: it confirms that the server has the file, also when PhotoKit reports the job as
    /// failed after the server's answer (the Files app sees that).
    var fileId: FileID? { Uploader.parseFileId(responseHeaders["oc-fileid"]) }
}

/// PhotoKit's upload jobs. The real one is `PhotoKitUploadJobs` (in the extension); tests use a fake.
public protocol UploadJobService: Sendable {
    /// How many jobs may exist that are not acknowledged (in flight, succeeded or failed).
    var jobLimit: Int { get }
    /// Jobs that ended and wait to be acknowledged.
    func endedJobs() async -> [UploadJobInfo]
    /// Failed jobs that may be retried once.
    func retryableJobs() async -> [UploadJobInfo]
    /// Jobs PhotoKit still works on.
    func jobsInFlight() async -> [UploadJobInfo]
    /// Creates a job that sends the resource with this request; returns its id.
    func create(_ resource: BackupResource, settings: BackupSettings, request: URLRequest) async throws -> String
    func acknowledge(_ ids: [String]) async throws
    func retry(_ id: String, request: URLRequest) async throws
}

/// A job PhotoKit sends for the backup, recorded before the job is created.
public struct UploadJobEntry: Codable, Sendable, Equatable {
    /// PhotoKit's id; nil between recording and creating it.
    public var jobId: String?
    public var resource: BackupResource
    /// Destination below the user's files.
    public var path: String
    public var size: Int64
    public var createdAt: Date
    /// The job was retried (PhotoKit allows that once).
    public var retried = false
    /// The networks the request may use (Wi-Fi only, Low Data Mode); a retry keeps them.
    public var allowsExpensiveNetwork = true
    public var allowsConstrainedNetwork = true
}

/// The jobs PhotoKit sends for the backup (`<account>/UploadJobs.json`). The extension writes it; the app reads it to leave
/// those resources alone and to keep their names free (SPEC §7.18.6).
public struct UploadJobJournal: Sendable {
    public let file: URL
    /// By destination path (unique: names of uploads on their way are taken).
    public private(set) var entries: [String: UploadJobEntry] = [:]

    public init(file: URL) {
        self.file = file
        if let data = try? Data(contentsOf: file), let entries = try? JSONDecoder().decode([String: UploadJobEntry].self, from: data) {
            self.entries = entries
        }
    }

    func entry(for job: UploadJobInfo) -> UploadJobEntry? {
        if let byId = entries.values.first(where: { $0.jobId == job.id }) { return byId }
        // Created, but the extension ended before it could note the id.
        guard let destination = job.destination else { return nil }
        return entries.values.first { $0.jobId == nil && Self.path(of: destination).hasSuffix($0.path) }
    }

    static func path(of url: URL) -> String { url.path(percentEncoded: false) }

    /// The resources PhotoKit has, and the destinations they take.
    var claims: (keys: Set<BackupEngine.LedgerKey>, paths: Set<String>) {
        (Set(entries.values.map { BackupEngine.LedgerKey($0.resource) }), Set(entries.keys))
    }

    mutating func set(_ entry: UploadJobEntry) throws {
        entries[entry.path] = entry
        try save()
    }

    mutating func remove(_ path: String) {
        guard entries.removeValue(forKey: path) != nil else { return }
        try? save()
    }

    /// Replaces the entry of a path with one under another path (a retry got another name).
    mutating func move(_ path: String, to entry: UploadJobEntry) throws {
        entries[path] = nil
        try set(entry)
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: file, options: .atomic)
    }

    /// Where an account's journal is.
    public static func file(in accountDirectory: URL) -> URL { accountDirectory.appending(path: "UploadJobs.json") }

    /// What the app reads: the resources and destinations PhotoKit has. Empty when there is no file.
    static func claims(at file: URL?) -> (keys: Set<BackupEngine.LedgerKey>, paths: Set<String>) {
        guard let file else { return ([], []) }
        return UploadJobJournal(file: file).claims
    }
}

/// How a run of the background-upload extension ended (`PHBackgroundResourceUploadProcessingResult`).
public enum UploadJobsResult: Sendable, Equatable {
    /// Jobs are in flight or were created: call again.
    case processing
    /// Nothing to do.
    case completed
    case failure
}

/// Which resources PhotoKit may send for the backup (SPEC §7.18.6).
enum UploadJobPolicy {
    /// PhotoKit takes up to this size; larger files go in chunks through the app's own session.
    static let maxFileSize: Int64 = 100 * 1024 * 1024
    /// Jobs in flight at most (PhotoKit's limit may be higher; the Files app uses the same).
    static let maxJobs = 20
    /// An entry whose job PhotoKit does not know after this long was never created (the extension ended in between).
    static let orphanAge: TimeInterval = 10 * 60

    /// PhotoKit uploads the resource's bytes as they are: nothing that is converted, nothing of unknown size (the name
    /// check needs it), nothing larger than it takes.
    static func isEligible(_ resource: BackupResource, settings: BackupSettings) -> Bool {
        guard let size = resource.byteSize, size > 0, size <= maxFileSize else { return false }
        return !MostCompatible.mayConvert(resource, settings: settings)
    }

    /// Whether new jobs may be created now. PhotoKit downloads originals from iCloud by itself, so with "Download originals
    /// from iCloud" off it creates none (the app does those uploads and skips what is only in iCloud).
    static func mayCreateJobs(_ settings: BackupSettings, lowPower: Bool) -> Bool {
        settings.downloadFromICloud && !(settings.pauseInLowPowerMode && lowPower)
    }
}

extension BackupEngine {
    /// An engine for the PhotoKit background-upload extension: the photo library and the server, no transfer session of
    /// its own (PhotoKit sends), no observers of the network or power.
    public static func forUploadJobs(api: PhotosAPI, database: AccountDatabase, accountId: AccountID, metadataEditing: Bool) async
        -> BackupEngine
    {
        let engine = BackupEngine(
            library: PhotoLibrarySource(),
            remote: PhotosBackupRemote(api: api, library: LibraryStore(database: database), database: database),
            database: database, accountId: accountId)
        await engine.setMetadataEditing(metadataEditing)
        return engine
    }

    /// One run of the PhotoKit background-upload extension (SPEC §7.18.6): records and acknowledges the jobs that ended,
    /// retries a failed one once, and creates jobs for resources that are not on the server (the same scan, Files-app
    /// ledger and reconciliation as a pass of the app) up to the job limit.
    ///
    /// The app and PhotoKit never send the same resource: the app leaves the resources of this journal alone, and this run
    /// leaves those the app's transfer session has (`appUploads`, its journal directory). Each side keeps the other's
    /// destinations free, and every PUT has `If-None-Match: *`, so a file is never overwritten.
    ///
    /// - Parameters:
    ///   - journal: `UploadJobs.json` in the account's directory.
    ///   - appUploads: the directory of the app's `BackgroundUploads`.
    public func processUploadJobs(
        settings: BackupSettings, service: any UploadJobService, journal file: URL, appUploads: URL?, lowPower: Bool = false
    ) async -> UploadJobsResult {
        guard settings.isEnabled, settings.filesAppMode != .keepFiles, library.isAuthorized, !library.isLimited else {
            return .completed
        }
        var journal = UploadJobJournal(file: file)
        let logger = Logger(subsystem: "com.nextcloud.photos", category: "backup")
        do {
            try await settleUploadJobs(&journal, service: service, appUploads: appUploads)
            var created = 0
            if UploadJobPolicy.mayCreateJobs(settings, lowPower: lowPower) {
                created = try await createUploadJobs(&journal, service: service, settings: settings, appUploads: appUploads)
            }
            try? refreshCounts()
            logger.notice(
                "backup: PhotoKit uploads: \(created, privacy: .public) new, \(journal.entries.count, privacy: .public) with PhotoKit")
            return journal.entries.isEmpty ? .completed : .processing
        } catch is CancellationError {
            return .processing
        } catch let error as NetworkError where BackupPolicy.isCancellation(error) || error.isTransient {
            return journal.entries.isEmpty ? .completed : .processing
        } catch {
            logger.error("backup: PhotoKit uploads failed: \(error.localizedDescription, privacy: .public)")
            return .failure
        }
    }

    /// Records the jobs that ended (uploaded, or failed after its retry) and acknowledges them, so PhotoKit has room for
    /// new ones. A failed job is retried once, after another look at its destination.
    func settleUploadJobs(_ journal: inout UploadJobJournal, service: any UploadJobService, appUploads: URL?) async throws {
        let retryable = await service.retryableJobs()
        var handled = Set<String>()
        for job in retryable {
            try Task.checkCancellation()
            handled.insert(job.id)
            guard var entry = journal.entry(for: job) else {
                try await service.acknowledge([job.id])
                continue
            }
            if try await uploadJobArrived(job, entry: entry) {
                journal.remove(entry.path)
                try await service.acknowledge([job.id])
                continue
            }
            if entry.retried {
                try await uploadJobFailed(job, entry: entry)
                journal.remove(entry.path)
                try await service.acknowledge([job.id])
                continue
            }
            // The name may have been taken meanwhile (412): the destination is looked for again.
            let folder = (entry.path as NSString).deletingLastPathComponent
            let name = (entry.path as NSString).lastPathComponent
            var reserved = journal.claims.paths.union(Self.appReservedPaths(appUploads))
            reserved.remove(entry.path)
            switch try await remote.prepareJobUpload(
                size: entry.size, fileName: name, folder: folder, capturedAt: entry.resource.createdAt, reserved: reserved)
            {
            case .existing(let uploaded):
                try await completed(entry.resource, uploaded: uploaded)
                journal.remove(entry.path)
                try await service.acknowledge([job.id])
            case .put(let path, var request):
                request.allowsExpensiveNetwork = entry.allowsExpensiveNetwork
                request.allowsConstrainedNetwork = entry.allowsConstrainedNetwork
                let previous = entry.path
                entry.path = path
                entry.retried = true
                try journal.move(previous, to: entry)
                try await service.retry(job.id, request: request.urlRequest)
            }
        }
        for job in await service.endedJobs() where !handled.contains(job.id) {
            try Task.checkCancellation()
            guard let entry = journal.entry(for: job) else {
                try await service.acknowledge([job.id])
                continue
            }
            if job.state != .cancelled, try await !uploadJobArrived(job, entry: entry) {
                try await uploadJobFailed(job, entry: entry)
            }
            journal.remove(entry.path)
            try await service.acknowledge([job.id])
        }
        // Entries whose job was never created (the extension ended in between): the resource is free again.
        let known = Set(await service.jobsInFlight().map(\.id))
        for entry in journal.entries.values
        where (entry.jobId.map { !known.contains($0) } ?? true) && now().timeIntervalSince(entry.createdAt) > UploadJobPolicy.orphanAge {
            journal.remove(entry.path)
        }
    }

    /// Whether an ended job brought the file to the server: the server's file id, or the file at its destination with
    /// the resource's size. Then it is recorded like any upload of the backup.
    private func uploadJobArrived(_ job: UploadJobInfo, entry: UploadJobEntry) async throws -> Bool {
        var uploaded: UploadedFile?
        if let fileId = job.fileId {
            uploaded = UploadedFile(fileId: fileId, path: entry.path, etag: job.responseHeaders["oc-etag"])
        } else if job.state != .cancelled {
            uploaded = try await remote.existingFile(at: entry.path, size: entry.size)
        }
        guard let uploaded else { return false }
        try await completed(entry.resource, uploaded: uploaded)
        return true
    }

    /// Records a failed job, unless the resource got onto the server another way meanwhile (the app sent it).
    private func uploadJobFailed(_ job: UploadJobInfo, entry: UploadJobEntry) async throws {
        if let current = try ledgerEntries(of: entry.resource.localIdentifier).first(where: {
            $0.resourceKind == entry.resource.kind.rawValue
        }),
            BackupPolicy.isComplete(current)
        {
            return
        }
        let reason = job.errorDescription ?? String(localized: "The system could not upload the file.", bundle: .module)
        try record(entry.resource, state: .failed, error: reason)
    }

    /// Creates jobs for resources that are not on the server, oldest first, as many as there is room for.
    private func createUploadJobs(
        _ journal: inout UploadJobJournal, service: any UploadJobService, settings: BackupSettings, appUploads: URL?
    ) async throws -> Int {
        let inFlight = await service.jobsInFlight().count
        let room = min(service.jobLimit, UploadJobPolicy.maxJobs) - max(inFlight, journal.entries.count)
        guard room > 0 else { return 0 }
        let app = BackgroundUploadJournal(directory: appUploads ?? URL(fileURLWithPath: "/nonexistent"))
        func eligible(_ resource: BackupResource) -> Bool {
            UploadJobPolicy.isEligible(resource, settings: settings) && !journal.claims.keys.contains(LedgerKey(resource))
                && !app.isHandedOver(resource)
        }
        let work = try scan(settings, retryFailed: false)
        var candidates = work.ready.filter(eligible)
        var unchecked = work.unchecked[...]
        // Only as much of the server is asked as the free jobs need.
        while candidates.count < room, !unchecked.isEmpty {
            try Task.checkCancellation()
            let chunk = Array(unchecked.prefix(serverCheckChunk))
            unchecked = unchecked.dropFirst(chunk.count)
            candidates += try await reconcile(chunk).filter(eligible)
        }
        candidates.sort(by: BackupPolicy.isOlder)
        var created = 0
        for resource in candidates where created < room {
            try Task.checkCancellation()
            guard let size = resource.byteSize else { continue }
            let name = BackupNaming.fileName(
                originalName: resource.originalName, fileExtension: (resource.originalName as NSString).pathExtension,
                isVideo: resource.mediaKind == .video, date: resource.createdAt, naming: settings.naming)
            let folder = BackupNaming.folder(base: settings.folder, subfolders: settings.subfolders, date: resource.createdAt)
            let reserved = journal.claims.paths.union(app.reservedPaths)
            switch try await remote.prepareJobUpload(
                size: size, fileName: name, folder: folder, capturedAt: resource.createdAt, reserved: reserved)
            {
            case .existing(let uploaded):
                try await completed(resource, uploaded: uploaded)
            case .put(let path, var request):
                let isVideo = resource.mediaKind == .video
                request.allowsExpensiveNetwork = !(settings.wifiOnly || (isVideo && settings.wifiOnlyForVideos))
                request.allowsConstrainedNetwork = settings.allowLowDataMode
                // Recorded before it is created: the app must not take the resource meanwhile.
                var entry = UploadJobEntry(
                    resource: resource, path: path, size: size, createdAt: now(), allowsExpensiveNetwork: request.allowsExpensiveNetwork,
                    allowsConstrainedNetwork: request.allowsConstrainedNetwork)
                try journal.set(entry)
                do {
                    entry.jobId = try await service.create(resource, settings: settings, request: request.urlRequest)
                    try journal.set(entry)
                    created += 1
                } catch {
                    journal.remove(path)
                    // PhotoKit's limit is reached: the next run goes on.
                    if UploadJobPolicy.isLimitExceeded(error) { return created }
                    throw error
                }
            }
        }
        return created
    }

    /// Destinations of the app's own uploads on their way.
    static func appReservedPaths(_ directory: URL?) -> Set<String> {
        guard let directory else { return [] }
        return BackgroundUploadJournal(directory: directory).reservedPaths
    }
}

extension UploadJobPolicy {
    /// PhotoKit's `PHPhotosError.limitExceeded` (the job limit).
    static func isLimitExceeded(_ error: any Error) -> Bool {
        let error = error as NSError
        return error.domain == "PHPhotosErrorDomain" && error.code == 3307
    }
}
