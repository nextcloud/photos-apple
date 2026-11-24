// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import OSLog
import PhotosModel
import PhotosNetworking
import PhotosStore

/// How an export is imported.
public struct TakeoutOptions: Codable, Hashable, Sendable {
    /// Server folder the files go to; it should be inside a timeline folder.
    public var destination: String
    /// Files go into `<destination>/<year of capture>`.
    public var yearSubfolders = true
    /// Albums of the export become Photos albums.
    public var createAlbums = true
    /// Google Photos captions become comments on the file (Nextcloud has no caption field of its own).
    public var descriptionsAsComments = true

    public init(destination: String, yearSubfolders: Bool = true, createAlbums: Bool = true, descriptionsAsComments: Bool = true) {
        self.destination = destination
        self.yearSubfolders = yearSubfolders
        self.createAlbums = createAlbums
        self.descriptionsAsComments = descriptionsAsComments
    }

    func folder(for item: TakeoutItem, calendar: Calendar) -> String {
        let base = destination.hasSuffix("/") && destination.count > 1 ? String(destination.dropLast()) : destination
        guard yearSubfolders, let date = item.takenAt else { return base }
        return (base == "/" ? "" : base) + "/" + String(calendar.component(.year, from: date))
    }
}

/// What the import has done so far.
public struct TakeoutProgress: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case importing, albums, finished, cancelled
        /// Stopped by something that affects every file (login, full storage).
        case stopped(String)
    }

    public var phase: Phase = .importing
    public var total = 0
    /// Items handled, in this run or an earlier one.
    public var processed = 0
    public var uploaded = 0
    /// Already on the server (the backup's matching rules), not uploaded again.
    public var duplicates = 0
    public var failed = 0
    public var albumsCreated = 0
    public var albumsTotal = 0
    public var currentName: String?
    /// Failures with their reason, for the summary (at most 50).
    public var failures: [String] = []

    public init() {}

    public var fraction: Double { total == 0 ? 1 : Double(processed) / Double(total) }
    public var isRunning: Bool { phase == .importing || phase == .albums }
}

/// The record of an import, so that a cancelled or interrupted one continues where it stopped.
public struct TakeoutJournal: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case uploaded, duplicate, failed }

    public struct Entry: Codable, Sendable, Equatable {
        public var state: State
        /// Where the file is on the server (uploaded, or the copy that was there already).
        public var path: String?
        public var fileId: FileID?
        public var error: String?
        /// Albums the file was added to.
        public var albums: [String] = []
        public var commented = false
    }

    public var planKey: String
    public var entries: [String: Entry] = [:]

    public init(planKey: String) { self.planKey = planKey }

    static func url(in directory: URL, planKey: String) -> URL { directory.appending(path: "takeout-\(planKey).json") }

    public static func load(from directory: URL, planKey: String) -> TakeoutJournal? {
        guard let data = try? Data(contentsOf: url(in: directory, planKey: planKey)) else { return nil }
        return try? JSONDecoder().decode(TakeoutJournal.self, from: data)
    }

    func save(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: Self.url(in: directory, planKey: planKey), options: .atomic)
    }

    /// Items done in an earlier run (failed ones are tried again).
    public var completed: Int { entries.values.filter { $0.state != .failed }.count }
}

/// The server as the import sees it; tests use a fake.
protocol TakeoutRemote: Sendable {
    /// Media files whose capture or modification time lies in the window (± 14 h for EXIF times without offset).
    func candidates(from start: Date, to end: Date) async throws -> [RemoteCandidate]
    func upload(file: URL, fileName: String, folder: String, capturedAt: Date?) async throws -> UploadedFile
    /// Puts the new file into the local index and adds what the server could not read from the file.
    func didUpload(_ uploaded: UploadedFile, metadata: TakeoutMetadata?, comment: Bool) async
    func albumNames() async throws -> Set<String>
    func createAlbum(_ name: String) async throws
    func addToAlbum(_ name: String, path: String) async throws
}

/// Imports a Google Takeout export into the user's Nextcloud (SPEC §7.18.10): uploads the photos and videos unchanged (EXIF
/// stays), with the capture time of the sidecar as modification time, skips what is already on the server (the
/// backup's matching rules), sets the position where the file has none (Nextcloud 35+), keeps captions as comments and
/// turns the export's albums into Photos albums. Resumable: a journal records every file as it is done.
public actor TakeoutImporter {
    let source: TakeoutSource
    let plan: TakeoutPlan
    let remote: any TakeoutRemote
    let options: TakeoutOptions
    let journalDirectory: URL
    let calendar: Calendar
    private var journal: TakeoutJournal
    private var progress = TakeoutProgress()
    private let logger = Logger(subsystem: "com.nextcloud.photos", category: "takeout")

    init(
        source: TakeoutSource, plan: TakeoutPlan, remote: any TakeoutRemote, options: TakeoutOptions, journalDirectory: URL,
        calendar: Calendar = .current
    ) {
        self.source = source
        self.plan = plan
        self.remote = remote
        self.options = options
        self.journalDirectory = journalDirectory
        self.calendar = calendar
        journal = TakeoutJournal.load(from: journalDirectory, planKey: plan.key) ?? TakeoutJournal(planKey: plan.key)
    }

    /// For the app: imports into the account behind `api`.
    public init(
        source: TakeoutSource, plan: TakeoutPlan, api: PhotosAPI, database: AccountDatabase, features: ServerFeatures,
        options: TakeoutOptions, journalDirectory: URL
    ) {
        self.init(
            source: source, plan: plan,
            remote: PhotosTakeoutRemote(
                api: api, library: LibraryStore(database: database), database: database, metadataEditing: features.has(.metadataEdit),
                comments: features.has(.comments)),
            options: options, journalDirectory: journalDirectory)
    }

    /// Items handled by an earlier run of the same export.
    public var alreadyDone: Int { journal.completed }

    /// Runs the import; returns when it is done or the task is cancelled (the journal is kept for the next run).
    public func run(onProgress: @escaping @Sendable (TakeoutProgress) -> Void) async -> TakeoutProgress {
        progress = TakeoutProgress()
        progress.total = plan.items.count
        progress.albumsTotal = options.createAlbums ? plan.albums.count : 0
        let temporary = FileManager.default.temporaryDirectory.appending(path: "Takeout-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: temporary)
            try? journal.save(to: journalDirectory)
        }
        do {
            try await importItems(temporary: temporary, onProgress: onProgress)
            if options.createAlbums {
                progress.phase = .albums
                onProgress(progress)
                try await createAlbums(onProgress: onProgress)
            }
            progress.phase = .finished
        } catch let error where error is CancellationError || (error as? NetworkError) == .cancelled {
            progress.phase = .cancelled
        } catch {
            logger.error("takeout import stopped: \(error.localizedDescription, privacy: .public)")
            progress.phase = .stopped(error.localizedDescription)
        }
        progress.currentName = nil
        onProgress(progress)
        return progress
    }

    /// Errors after which no other file can be uploaded either.
    static func stopsImport(_ error: any Error) -> Bool {
        switch error as? NetworkError {
        case .unauthorized, .insufficientStorage, .offline, .untrustedCertificate, .clientCertificateRequired, .maintenance: true
        default: error is CancellationError
        }
    }

    func importItems(temporary: URL, onProgress: @Sendable (TakeoutProgress) -> Void) async throws {
        var pending: [TakeoutItem] = []
        for item in plan.items {
            switch journal.entries[item.id]?.state {
            case .uploaded?:
                progress.uploaded += 1
                progress.processed += 1
            case .duplicate?:
                progress.duplicates += 1
                progress.processed += 1
            default: pending.append(item)
            }
        }
        onProgress(progress)
        var sinceSave = 0
        for window in Self.windows(pending) {
            try Task.checkCancellation()
            let candidates = try await candidates(for: window)
            let resources = window.map(Self.resource(for:))
            for (item, resource) in zip(window, resources) {
                try Task.checkCancellation()
                progress.currentName = item.name
                onProgress(progress)
                do {
                    if item.takenAt != nil,
                        let (match, _) = BackupMatcher.match(resource, candidates: candidates, localSiblings: resources)
                    {
                        journal.entries[item.id] = TakeoutJournal.Entry(state: .duplicate, path: match.path, fileId: match.fileId)
                        progress.duplicates += 1
                    } else {
                        let uploaded = try await upload(item, temporary: temporary)
                        progress.uploaded += 1
                        journal.entries[item.id] = TakeoutJournal.Entry(
                            state: .uploaded, path: uploaded.path, fileId: uploaded.fileId,
                            commented: options.descriptionsAsComments && item.metadata?.description != nil)
                    }
                } catch {
                    if Self.stopsImport(error) { throw error }
                    logger.error("takeout: a file failed: \(error.localizedDescription, privacy: .public)")
                    journal.entries[item.id] = TakeoutJournal.Entry(state: .failed, error: error.localizedDescription)
                    progress.failed += 1
                    if progress.failures.count < 50 { progress.failures.append("\(item.name): \(error.localizedDescription)") }
                }
                progress.processed += 1
                sinceSave += 1
                if sinceSave >= 20 {
                    try? journal.save(to: journalDirectory)
                    sinceSave = 0
                }
            }
        }
        onProgress(progress)
    }

    func upload(_ item: TakeoutItem, temporary: URL) async throws -> UploadedFile {
        let (file, isTemporary) = try source.materialize(item.file, in: temporary)
        defer { if isTemporary { try? FileManager.default.removeItem(at: file) } }
        let uploaded = try await remote.upload(
            file: file, fileName: item.name, folder: options.folder(for: item, calendar: calendar), capturedAt: item.takenAt)
        await remote.didUpload(
            uploaded, metadata: item.metadata, comment: options.descriptionsAsComments && item.metadata?.description != nil)
        return uploaded
    }

    func candidates(for window: [TakeoutItem]) async throws -> [RemoteCandidate] {
        let dates = window.compactMap(\.takenAt)
        guard let first = dates.min(), let last = dates.max() else { return [] }
        return try await remote.candidates(from: first.addingTimeInterval(-2), to: last.addingTimeInterval(2))
    }

    /// Items in groups whose capture times lie within a day, so one server search covers a group (at most 200 items).
    static func windows(_ items: [TakeoutItem]) -> [[TakeoutItem]] {
        var windows: [[TakeoutItem]] = []
        var current: [TakeoutItem] = []
        var start: Date?
        for item in items {
            let date = item.takenAt
            if let start, let date, date.timeIntervalSince(start) <= 24 * 3600, current.count < 200 {
                current.append(item)
                continue
            }
            if !current.isEmpty { windows.append(current) }
            current = [item]
            start = date
        }
        if !current.isEmpty { windows.append(current) }
        return windows
    }

    /// A Takeout file as the backup matcher sees a device file.
    static func resource(for item: TakeoutItem) -> LocalResource {
        let base = (item.name as NSString).deletingPathExtension
        let edited = TakeoutSidecars.editedSuffixes.contains { base.hasSuffix($0) }
        return LocalResource(
            localIdentifier: item.id, kind: item.kind, createdAt: item.takenAt ?? .distantPast, originalName: item.name,
            byteSize: Int64(item.file.size), rendition: edited ? .edited : .original)
    }

    // MARK: Albums

    /// Album names may not contain `/`.
    static func albumName(_ title: String) -> String {
        let name = title.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Google Photos" : name
    }

    func createAlbums(onProgress: @Sendable (TakeoutProgress) -> Void) async throws {
        var existing = try await remote.albumNames()
        for title in plan.albums {
            try Task.checkCancellation()
            let name = Self.albumName(title)
            if !existing.contains(name) {
                try await remote.createAlbum(name)
                existing.insert(name)
            }
            for item in plan.items where item.albums.contains(title) {
                try Task.checkCancellation()
                guard var entry = journal.entries[item.id], entry.state != .failed, let path = entry.path, !entry.albums.contains(name)
                else { continue }
                do {
                    try await remote.addToAlbum(name, path: path)
                    entry.albums.append(name)
                    journal.entries[item.id] = entry
                } catch {
                    if Self.stopsImport(error) { throw error }
                    // A copy that was already on the server may be in a shared folder, which albums cannot hold.
                    if progress.failures.count < 50 { progress.failures.append("\(name): \(item.name): \(error.localizedDescription)") }
                }
            }
            progress.albumsCreated += 1
            onProgress(progress)
        }
    }
}

/// The real server.
struct PhotosTakeoutRemote: TakeoutRemote {
    let api: PhotosAPI
    let library: LibraryStore
    let database: AccountDatabase
    /// The server can set capture time and position (Nextcloud 35+).
    let metadataEditing: Bool
    let comments: Bool

    var backupRemote: PhotosBackupRemote { PhotosBackupRemote(api: api, library: library, database: database) }

    func candidates(from start: Date, to end: Date) async throws -> [RemoteCandidate] {
        try await backupRemote.candidates(from: start, to: end)
    }

    func upload(file: URL, fileName: String, folder: String, capturedAt: Date?) async throws -> UploadedFile {
        var uploader = Uploader(dav: api.dav)
        uploader.folders = BackupUploadFolders(database: database)
        return try await uploader.upload(file: file, fileName: fileName, folder: folder, capturedAt: capturedAt, conflict: .skipIfSameSize)
    }

    func didUpload(_ uploaded: UploadedFile, metadata: TakeoutMetadata?, comment: Bool) async {
        guard let item = try? await api.items(fileIds: [uploaded.fileId], properties: DAVProp.mediaIndex).first else { return }
        try? library.upsert([item])
        if metadataEditing, !item.hasLocation, let latitude = metadata?.latitude, let longitude = metadata?.longitude {
            try? await api.setMetadata(userPath: item.path, latitude: latitude, longitude: longitude)
        }
        if comment, comments, let text = metadata?.description {
            try? await api.addFileComment(fileId: uploaded.fileId, message: text)
        }
    }

    func albumNames() async throws -> Set<String> {
        Set(try await api.listAlbums(.own, extended: false).map(\.name))
    }

    func createAlbum(_ name: String) async throws {
        try await api.createAlbum(name: name)
    }

    func addToAlbum(_ name: String, path: String) async throws {
        try await api.addToAlbum(Album(kind: .own, name: name), userPath: path)
    }
}
