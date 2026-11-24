// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import ImageIO
import OSLog
import PhotosModel
import PhotosNetworking
import PhotosStore
import UniformTypeIdentifiers

/// How the chosen exports are imported.
public struct ImportOptions: Codable, Hashable, Sendable {
    /// Server folder the files go to; it should be inside a timeline folder.
    public var destination: String
    /// Files go into `<destination>/<source>/…` (`Google Photos`, `iCloud Photos`, `Facebook`…).
    public var folderPerSource = true
    /// Files go into `…/<year of capture>`.
    public var yearSubfolders = true
    /// Albums of the exports become Photos albums.
    public var createAlbums = true
    /// Captions become comments on the file (Nextcloud has no caption field of its own).
    public var captionsAsComments = true
    /// Favourites of the exports become favourites.
    public var favorites = true
    /// Capture time, position and caption go into photos that lack them (Facebook and Instagram remove them).
    public var addMissingMetadata = true
    /// Photos hidden or archived in the service go to the archive (SPEC §7.13).
    public var hiddenToArchive = true

    public init(destination: String) {
        self.destination = destination
    }

    /// The folder an item goes to.
    func folder(for item: ImportItem, calendar: Calendar) -> String {
        var base = destination.hasSuffix("/") && destination.count > 1 ? String(destination.dropLast()) : destination
        if base == "/" { base = "" }
        if folderPerSource { base += "/" + item.source.folderName }
        if yearSubfolders, let date = item.takenAt { base += "/" + String(calendar.component(.year, from: date)) }
        if hiddenToArchive && item.metadata.hidden { base = Self.archiveFolder + base }
        return base.isEmpty ? "/" : base
    }

    /// The archive (SPEC §7.13): the same path below this folder.
    static let archiveFolder = "/.archive"
}

/// What the import has done so far.
public struct ImportProgress: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case importing, albums, finished, cancelled
        /// Stopped by something that affects every file (login, full storage, no space on the device).
        case stopped(String)
    }

    public var phase: Phase = .importing
    public var total = 0
    /// Items handled, in this run or an earlier one.
    public var processed = 0
    public var uploaded = 0
    /// Already on the server (the backup's matching rules and the import's own), not uploaded again.
    public var duplicates = 0
    public var failed = 0
    public var albumsCreated = 0
    public var albumsTotal = 0
    public var bytesTotal: UInt64 = 0
    public var bytesDone: UInt64 = 0
    public var currentName: String?
    public var currentSource: ImportSourceKind?
    /// A small JPEG of the photo being imported, for the progress screen.
    public var currentPreview: Data?
    /// Small JPEGs of the last photos imported (at most 12), newest last: the progress screen and the welcome summary.
    public var recentPreviews: [Data] = []
    /// Failures with their reason, for the summary (at most 50).
    public var failures: [String] = []

    public init() {}

    public var fraction: Double {
        if bytesTotal > 0 { return min(1, Double(bytesDone) / Double(bytesTotal)) }
        return total == 0 ? 1 : Double(processed) / Double(total)
    }
    public var isRunning: Bool { phase == .importing || phase == .albums }
}

/// The record of an import, so that a cancelled or interrupted one continues where it stopped.
public struct ImportJournal: Codable, Sendable, Equatable {
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
        public var favorited = false
        /// The import added capture time, position or caption to the file.
        public var metadataAdded = false
        /// Why it counts as already on the server (`ImportMatcher.Rule`).
        public var rule: String?
    }

    public var planKey: String
    public var entries: [String: Entry] = [:]
    public var startedAt: Date?
    public var finishedAt: Date?

    public init(planKey: String) { self.planKey = planKey }

    static func url(in directory: URL, planKey: String) -> URL { directory.appending(path: "import-\(planKey).json") }

    public static func load(from directory: URL, planKey: String) -> ImportJournal? {
        guard let data = try? Data(contentsOf: url(in: directory, planKey: planKey)) else { return nil }
        return try? JSONDecoder().decode(ImportJournal.self, from: data)
    }

    func save(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: Self.url(in: directory, planKey: planKey), options: .atomic)
    }

    /// Items done in an earlier run (failed ones are tried again).
    public var completed: Int { entries.values.count { $0.state != .failed } }
}

/// Errors of the import itself.
public enum ImportError: Error, LocalizedError, Equatable {
    /// The device has no room for the next file (a ZIP entry is unpacked one at a time before it is uploaded).
    case notEnoughSpace(needed: Int64)

    public var errorDescription: String? {
        switch self {
        case .notEnoughSpace(let needed):
            String(
                localized:
                    "There is not enough free space on this device for the next file (\(needed.formatted(.byteCount(style: .file))) needed).",
                bundle: .module, comment: "Why an import stopped: the device's storage is full. The value is a size such as 1.2 GB.")
        }
    }
}

/// The server as the import sees it; tests use a fake.
protocol ImportRemote: Sendable {
    /// Media files whose capture or modification time lies in the window (± 14 h for EXIF times without offset).
    func candidates(from start: Date, to end: Date) async throws -> [RemoteCandidate]
    func upload(file: URL, fileName: String, folder: String, capturedAt: Date?) async throws -> UploadedFile
    /// Puts the new file into the local index and adds what the server could not read from the file (position on
    /// Nextcloud 35+, caption as a comment).
    func didUpload(_ uploaded: UploadedFile, metadata: ImportMetadata, comment: Bool) async
    func setFavorite(path: String) async throws
    func albumNames() async throws -> Set<String>
    func createAlbum(_ name: String) async throws
    func addToAlbum(_ name: String, path: String) async throws
}

/// Imports the photos and videos of the chosen exports into the user's Nextcloud (SPEC §15.7): uploads them (unchanged,
/// or with the capture time, position and caption the file lacks added to its metadata), with the capture time as the
/// file's time, skips what is already on the server (`ImportMatcher`), keeps captions as comments, favourites as
/// favourites, hidden photos in the archive, and recreates the albums. Resumable: a journal records every file as it is
/// done.
public actor LibraryImporter {
    let files: ExportFiles?
    let plan: ImportPlan
    let remote: any ImportRemote
    let options: ImportOptions
    let journalDirectory: URL
    let calendar: Calendar
    let exportAsset: @Sendable (BackupResource) async throws -> URL
    /// Free space on the device the next file needs beyond its own size.
    let spaceMargin: Int64
    /// Files uploaded at the same time (each waits for the server between its requests).
    let parallelUploads: Int
    private var journal: ImportJournal
    /// The journal of an earlier, finished import of the same plan.
    private var previous: ImportJournal?
    private var progress = ImportProgress()
    private var sinceSave = 0
    private let logger = Logger(subsystem: "com.nextcloud.photos", category: "import")

    init(
        files: ExportFiles?, plan: ImportPlan, remote: any ImportRemote, options: ImportOptions, journalDirectory: URL,
        calendar: Calendar = .current, spaceMargin: Int64 = 200 << 20, parallelUploads: Int = 3,
        exportAsset: @escaping @Sendable (BackupResource) async throws -> URL = LibraryImporter.exportFromPhotos
    ) {
        self.files = files
        self.plan = plan
        self.remote = remote
        self.options = options
        self.journalDirectory = journalDirectory
        self.calendar = calendar
        self.spaceMargin = spaceMargin
        self.parallelUploads = max(1, parallelUploads)
        self.exportAsset = exportAsset
        let loaded = ImportJournal.load(from: journalDirectory, planKey: plan.key)
        if let loaded, loaded.finishedAt != nil {
            // A finished import of the same files runs again from the start: what is on the server now is looked up
            // again (the user may have deleted photos since), and only the albums it filled are remembered.
            previous = loaded
            journal = ImportJournal(planKey: plan.key)
        } else {
            journal = loaded ?? ImportJournal(planKey: plan.key)
        }
    }

    /// For the app: imports into the account behind `api`.
    public init(
        files: ExportFiles?, plan: ImportPlan, api: PhotosAPI, database: AccountDatabase, features: ServerFeatures,
        options: ImportOptions, journalDirectory: URL
    ) {
        self.init(
            files: files, plan: plan,
            remote: PhotosImportRemote(
                api: api, library: LibraryStore(database: database), database: database, metadataEditing: features.has(.metadataEdit),
                comments: features.has(.comments)),
            options: options, journalDirectory: journalDirectory)
    }

    /// The Mac's Photos library: the original, downloaded from iCloud when it is not on this Mac.
    @Sendable static func exportFromPhotos(_ resource: BackupResource) async throws -> URL {
        try await PhotoLibrarySource().export(resource, settings: PhotosLibraryExport.settings, allowNetwork: true)
    }

    /// Items handled by an earlier, unfinished run of the same plan.
    public var alreadyDone: Int { journal.completed }

    /// The journal as it is now (for the summary).
    public var currentJournal: ImportJournal { journal }

    /// Runs the import; returns when it is done or the task is cancelled (the journal is kept for the next run).
    public func run(onProgress: @escaping @Sendable (ImportProgress) -> Void) async -> ImportProgress {
        progress = ImportProgress()
        progress.total = plan.items.count
        progress.bytesTotal = plan.totalBytes
        progress.albumsTotal = options.createAlbums ? plan.albums.count : 0
        if journal.startedAt == nil { journal.startedAt = Date() }
        let temporary = FileManager.default.temporaryDirectory.appending(path: "Import-\(UUID().uuidString)")
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
            journal.finishedAt = Date()
        } catch let error where error is CancellationError || (error as? NetworkError) == .cancelled {
            progress.phase = .cancelled
        } catch {
            logger.error("import stopped: \(error.localizedDescription, privacy: .public)")
            progress.phase = .stopped(error.localizedDescription)
        }
        progress.currentName = nil
        progress.currentPreview = nil
        onProgress(progress)
        return progress
    }

    /// Errors after which no other file can be uploaded either.
    static func stopsImport(_ error: any Error) -> Bool {
        if error is ImportError { return true }
        switch error as? NetworkError {
        case .unauthorized, .insufficientStorage, .offline, .untrustedCertificate, .clientCertificateRequired, .maintenance: return true
        default: return error is CancellationError
        }
    }

    func importItems(temporary: URL, onProgress: @escaping @Sendable (ImportProgress) -> Void) async throws {
        var pending: [ImportItem] = []
        for item in plan.items {
            switch journal.entries[item.id]?.state {
            case .uploaded?:
                progress.uploaded += 1
                progress.processed += 1
                progress.bytesDone += item.size
            case .duplicate?:
                progress.duplicates += 1
                progress.processed += 1
                progress.bytesDone += item.size
            default: pending.append(item)
            }
        }
        onProgress(progress)
        // One group for the whole import: the uploads of a window go on while the next window is looked up.
        try await withThrowingTaskGroup(of: Void.self) { group in
            var running = 0
            for window in Self.windows(pending) {
                try Task.checkCancellation()
                let candidates = try await candidates(for: window)
                var index = BackupMatcher.Index(candidates: candidates, locals: window.map(ImportMatcher.resource(for:)))
                for item in window {
                    try Task.checkCancellation()
                    if let (match, rule) = ImportMatcher.match(item, index: &index, candidates: candidates) {
                        // On the server already (known from the search): nothing to upload.
                        progress.currentName = item.name
                        progress.currentSource = item.source
                        do {
                            try await recordDuplicate(item, path: match.path, fileId: match.fileId, rule: rule.rawValue)
                        } catch {
                            try recordFailure(item, error)
                        }
                        finished(item, onProgress: onProgress)
                        continue
                    }
                    if running >= parallelUploads {
                        try await group.next()
                        running -= 1
                    }
                    try Task.checkCancellation()
                    group.addTask { try await self.importOne(item, temporary: temporary, onProgress: onProgress) }
                    running += 1
                }
            }
            try await group.waitForAll()
        }
        onProgress(progress)
    }

    /// Uploads one item; a failure that concerns only this file is recorded, one that concerns every file is thrown.
    func importOne(_ item: ImportItem, temporary: URL, onProgress: @escaping @Sendable (ImportProgress) -> Void) async throws {
        try Task.checkCancellation()
        progress.currentName = item.name
        progress.currentSource = item.source
        onProgress(progress)
        do {
            try await importFile(item, temporary: temporary, onProgress: onProgress)
        } catch {
            try recordFailure(item, error)
        }
        finished(item, onProgress: onProgress)
    }

    func recordFailure(_ item: ImportItem, _ error: any Error) throws {
        if Self.stopsImport(error) { throw error }
        logger.error("import: a file failed: \(error.localizedDescription, privacy: .public)")
        journal.entries[item.id] = ImportJournal.Entry(state: .failed, error: error.localizedDescription)
        progress.failed += 1
        if progress.failures.count < 50 { progress.failures.append("\(item.name): \(error.localizedDescription)") }
    }

    /// Counts an item as handled and saves the journal now and then.
    func finished(_ item: ImportItem, onProgress: @Sendable (ImportProgress) -> Void) {
        progress.processed += 1
        progress.bytesDone += item.size
        sinceSave += 1
        if sinceSave >= 20 {
            try? journal.save(to: journalDirectory)
            sinceSave = 0
        }
        onProgress(progress)
    }

    func recordDuplicate(_ item: ImportItem, path: String, fileId: FileID, rule: String) async throws {
        var entry = ImportJournal.Entry(state: .duplicate, path: path, fileId: fileId, rule: rule)
        if let earlier = previous?.entries[item.id], earlier.path == path {
            // Imported by the earlier run: its albums are filled already.
            entry.albums = earlier.albums
            entry.commented = earlier.commented
            entry.metadataAdded = earlier.metadataAdded
        }
        // The copy on the server becomes a favourite too: favourites stay favourites.
        if options.favorites, item.metadata.favorite {
            do {
                try await remote.setFavorite(path: path)
                entry.favorited = true
            } catch {
                if Self.stopsImport(error) { throw error }
            }
        }
        journal.entries[item.id] = entry
        progress.duplicates += 1
    }

    /// Unpacks or exports the file, looks at it once more (a file without a capture time in the export may have one of
    /// its own), adds missing metadata, uploads it.
    func importFile(_ item: ImportItem, temporary: URL, onProgress: @Sendable (ImportProgress) -> Void) async throws {
        try ensureSpace(for: item.size)
        let (file, cleanUp) = try await materialize(item, temporary: temporary)
        defer { cleanUp() }
        var item = item
        let present = item.kind == .image ? ImportMetadataWriter.present(in: file) : nil
        if let embedded = present?.captureDate {
            if !item.metadata.isCaptureTime {
                // No capture time in the export (or only a posting time): the file's own is better, and lets the server
                // copy be found.
                item.metadata.takenAt = embedded
                item.metadata.timeSource = .capture
                let candidates = try await remote.candidates(from: embedded.addingTimeInterval(-2), to: embedded.addingTimeInterval(2))
                var index = BackupMatcher.Index(candidates: candidates, locals: [ImportMatcher.resource(for: item)])
                if let (match, rule) = ImportMatcher.match(item, index: &index, candidates: candidates) {
                    try await recordDuplicate(item, path: match.path, fileId: match.fileId, rule: rule.rawValue)
                    return
                }
            } else if item.metadata.timeSource == .captureMinute, let takenAt = item.takenAt,
                abs(embedded.timeIntervalSince(takenAt)) < 60
            {
                // Apple's list has minutes only; the file has the seconds.
                item.metadata.takenAt = embedded
                item.metadata.timeSource = .capture
            }
        }
        progress.currentPreview = present.flatMap { _ in Self.preview(of: file) }
        if let preview = progress.currentPreview {
            progress.recentPreviews.append(preview)
            if progress.recentPreviews.count > 12 { progress.recentPreviews.removeFirst() }
        }
        onProgress(progress)
        var upload = file
        var metadataAdded = false
        if options.addMissingMetadata, item.kind == .image,
            let rewritten = ImportMetadataWriter.addMissing(to: file, metadata: item.metadata, in: temporary)
        {
            upload = rewritten
            metadataAdded = true
        }
        let uploadedFile = upload
        defer { if metadataAdded { try? FileManager.default.removeItem(at: uploadedFile.deletingLastPathComponent()) } }
        let uploaded = try await remote.upload(
            file: upload, fileName: item.name, folder: options.folder(for: item, calendar: calendar), capturedAt: item.takenAt)
        let comment = options.captionsAsComments && item.metadata.caption != nil
        await remote.didUpload(uploaded, metadata: item.metadata, comment: comment)
        var entry = ImportJournal.Entry(
            state: .uploaded, path: uploaded.path, fileId: uploaded.fileId, commented: comment, metadataAdded: metadataAdded)
        if options.favorites, item.metadata.favorite {
            do {
                try await remote.setFavorite(path: uploaded.path)
                entry.favorited = true
            } catch {
                if Self.stopsImport(error) { throw error }
            }
        }
        journal.entries[item.id] = entry
        progress.uploaded += 1
    }

    /// The file's content on disk, and what removes it again.
    func materialize(_ item: ImportItem, temporary: URL) async throws -> (URL, @Sendable () -> Void) {
        switch item.origin {
        case .file(let file):
            guard let files else { throw CocoaError(.fileNoSuchFile) }
            let (url, isTemporary) = try files.materialize(file, in: temporary)
            return (url, { if isTemporary { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) } })
        case .asset(let resource):
            let url = try await exportAsset(resource)
            return (url, { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) })
        }
    }

    /// Stops the import before the device runs full: a file is unpacked or exported before it is uploaded.
    func ensureSpace(for size: UInt64) throws {
        let directory = FileManager.default.temporaryDirectory
        guard let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
            let available = values.volumeAvailableCapacityForImportantUsage, available > 0
        else { return }
        let needed = Int64(size) + spaceMargin
        if available < needed { throw ImportError.notEnoughSpace(needed: needed) }
    }

    /// A small JPEG of a photo (at most 240 pixels), for the progress screen.
    static func preview(of file: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 240,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    func candidates(for window: [ImportItem]) async throws -> [RemoteCandidate] {
        let timed = window.filter(\.metadata.isCaptureTime)
        guard let first = timed.compactMap(\.takenAt).min(), let last = timed.compactMap(\.takenAt).max() else { return [] }
        let margin = timed.map { ImportMatcher.margin(for: $0.metadata) }.max() ?? 2
        return try await remote.candidates(from: first.addingTimeInterval(-margin), to: last.addingTimeInterval(margin))
    }

    /// Items in groups whose capture times lie within a day, so one server search covers a group (at most 200 items).
    /// Items without a capture time (none, or only when it was posted) go in groups of their own.
    static func windows(_ items: [ImportItem]) -> [[ImportItem]] {
        var windows: [[ImportItem]] = []
        var current: [ImportItem] = []
        var start: Date?
        for item in items {
            let date = item.metadata.isCaptureTime ? item.takenAt : nil
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

    // MARK: Albums

    /// Album names may not contain `/`.
    static func albumName(_ title: String) -> String {
        let name = title.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Imported" : name
    }

    func createAlbums(onProgress: @Sendable (ImportProgress) -> Void) async throws {
        var existing = try await remote.albumNames()
        var members: [String: [ImportItem]] = [:]
        for item in plan.items {
            for album in item.albums { members[album, default: []].append(item) }
        }
        for album in plan.albums {
            try Task.checkCancellation()
            let name = Self.albumName(album.title)
            let done = (members[album.title] ?? []).filter { item in
                guard let entry = journal.entries[item.id] else { return false }
                return entry.state != .failed && entry.path != nil
            }
            if !done.isEmpty, !existing.contains(name) {
                try await remote.createAlbum(name)
                existing.insert(name)
            }
            for item in done {
                try Task.checkCancellation()
                guard var entry = journal.entries[item.id], let path = entry.path, !entry.albums.contains(name) else { continue }
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

    // MARK: Report

    /// Writes the report of what was imported and skipped into the journal's folder and, when asked, uploads it to the
    /// destination folder next to the photos (best effort: the local copy is what the summary offers).
    public func writeReport(_ summary: ImportSummary, upload: Bool) async -> URL? {
        let text = summary.reportText()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let name = String(
            localized: "Import report \(formatter.string(from: Date())).txt", bundle: .module,
            comment: "File name of the report an import writes. The value is a date and time such as 2026-11-24 18.30.")
        let url = journalDirectory.appending(path: "Reports").appending(path: name)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            return nil
        }
        if upload {
            var base =
                options.destination.hasSuffix("/") && options.destination.count > 1
                ? String(options.destination.dropLast()) : options.destination
            if base == "/" { base = "" }
            _ = try? await remote.upload(file: url, fileName: name, folder: base.isEmpty ? "/" : base, capturedAt: nil)
        }
        return url
    }
}

/// The real server.
struct PhotosImportRemote: ImportRemote {
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

    func didUpload(_ uploaded: UploadedFile, metadata: ImportMetadata, comment: Bool) async {
        guard let item = try? await api.items(fileIds: [uploaded.fileId], properties: DAVProp.mediaIndex).first else { return }
        try? library.upsert([item])
        if metadataEditing, !item.hasLocation, let latitude = metadata.latitude, let longitude = metadata.longitude {
            try? await api.setMetadata(userPath: item.path, latitude: latitude, longitude: longitude)
        }
        if comment, comments, let text = metadata.caption {
            try? await api.addFileComment(fileId: uploaded.fileId, message: text)
        }
    }

    func setFavorite(path: String) async throws {
        try await api.setFavorite(userPath: path, true)
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
