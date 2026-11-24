// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import OSLog
import PhotosBackup
import PhotosCore
import PhotosModel
import SwiftUI

/// What is remembered of an import while it is not finished, so that it can be resumed after the app was quit: the
/// chosen files (as bookmarks), whether the Mac's Photos library was part of it, and the options.
struct ImportSessionRecord: Codable, Equatable {
    var bookmarks: [Data]
    var names: [String]
    var includesPhotosLibrary: Bool
    var options: ImportOptions
    var planKey: String
    var total: Int

    static func url(in directory: URL) -> URL { directory.appending(path: "session.json") }

    static func load(from directory: URL) -> ImportSessionRecord? {
        guard let data = try? Data(contentsOf: url(in: directory)) else { return nil }
        return try? JSONDecoder().decode(ImportSessionRecord.self, from: data)
    }

    func save(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: Self.url(in: directory), options: .atomic)
    }

    static func remove(from directory: URL) {
        try? FileManager.default.removeItem(at: url(in: directory))
    }
}

/// One import of other services' exports (SPEC §15.7). It belongs to an account and outlives the sheet: closing the
/// sheet does not stop it, opening it again shows how far it got.
@MainActor
@Observable
final class ImportController {
    enum Stage: Equatable {
        case choose, reading, ready, running, finished
    }

    private(set) var stage: Stage = .choose
    private(set) var plan: ImportPlan?
    private(set) var progress = ImportProgress()
    private(set) var summary: ImportSummary?
    private(set) var reportURL: URL?
    /// What reading the exports is doing ("Downloading from iCloud Drive…", "Reading your Photos library… 1 200 of 9 000").
    private(set) var readingStatus = ""
    /// Files an earlier, interrupted import of the same exports got through.
    private(set) var alreadyDone = 0
    private(set) var error: String?
    /// Small previews of the last imported photos, newest last (the progress screen and the welcome collage).
    private(set) var previews: [Data] = []
    /// An unfinished import from an earlier launch.
    private(set) var resumable: ImportSessionRecord?
    var options = ImportOptions(destination: "/Photos")
    /// The Mac's Photos library is part of the import.
    var includePhotosLibrary = false

    @ObservationIgnored private var files: ExportFiles?
    @ObservationIgnored private var urls: [URL] = []
    @ObservationIgnored private var accessed: [URL] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var importTask: Task<ImportProgress, Never>?
    @ObservationIgnored private var account: AccountID?
    private let logger = Logger(subsystem: "com.nextcloud.photos", category: "import")

    private static var controllers: [AccountID: ImportController] = [:]

    static func controller(for session: SessionModel) -> ImportController {
        if let controller = controllers[session.account.id] { return controller }
        let controller = ImportController()
        controller.account = session.account.id
        controller.resumable = journalDirectory(session).flatMap(ImportSessionRecord.load(from:))
        controllers[session.account.id] = controller
        return controller
    }

    static func journalDirectory(_ session: SessionModel) -> URL? {
        session.services.map { $0.layout.accountDirectory($0.account.id).appending(path: "Import") }
    }

    // MARK: Reading

    /// Reads the exports: their indexes, sidecars and lists, not the photos.
    func read(_ urls: [URL], session: SessionModel) {
        stopAccessing()
        files?.cleanUp()
        accessed = urls.filter { $0.startAccessingSecurityScopedResource() }
        self.urls = urls
        let includeLibrary = includePhotosLibrary
        stage = .reading
        error = nil
        readingStatus = String(localized: "Reading the exports…", bundle: .module, comment: "Import: status while the chosen files are read.")
        let journalDirectory = Self.journalDirectory(session)
        options.destination = session.features.userConfig.photosLocation
        options.captionsAsComments = session.features.has(.comments)
        let scratch = FileManager.default.temporaryDirectory.appending(path: "ImportScratch")
        task = Task {
            do {
                await downloadFromICloudDrive(urls)
                try Task.checkCancellation()
                let onLibraryProgress: @Sendable (Int, Int) -> Void = { done, total in
                    Task { @MainActor [weak self] in
                        self?.readingStatus = String(
                            localized: "Reading your Photos library… \(done) of \(total)", bundle: .module,
                            comment: "Import (Mac): status while the Photos library is read. The values are numbers of photos.")
                    }
                }
                let (files, plan) = try await Task.detached(priority: .userInitiated) {
                    let files = try ExportFiles.open(urls, scratch: scratch)
                    var library: (items: [ImportItem], albums: [ImportAlbum]) = ([], [])
                    if includeLibrary { library = try PhotosLibraryExport().read(progress: onLibraryProgress) }
                    return (files, try ImportPlanner.plan(files, extra: library.items, extraAlbums: library.albums))
                }.value
                guard !plan.items.isEmpty else {
                    files.cleanUp()
                    error = String(
                        localized:
                            "No photos or videos were found. Choose the export's ZIP files or the folder they were unpacked into.",
                        bundle: .module, comment: "Import: the chosen files hold nothing to import.")
                    stage = .choose
                    stopAccessing()
                    return
                }
                self.files = files
                self.plan = plan
                alreadyDone = journalDirectory.flatMap { ImportJournal.load(from: $0, planKey: plan.key)?.completed } ?? 0
                stage = .ready
            } catch is CancellationError {
                stage = .choose
            } catch {
                self.error = error.localizedDescription
                stage = .choose
                stopAccessing()
            }
        }
    }

    /// Files of iCloud Drive that are not on the device yet are downloaded first (the import reads them in place).
    private func downloadFromICloudDrive(_ urls: [URL]) async {
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        func pending() -> [URL] {
            urls.filter { original in
                // A fresh URL each time: resource values are cached per URL value.
                var url = original
                url.removeAllCachedResourceValues()
                guard let values = try? url.resourceValues(forKeys: keys), values.isUbiquitousItem == true else { return false }
                return values.ubiquitousItemDownloadingStatus != .current
            }
        }
        var waiting = pending()
        guard !waiting.isEmpty else { return }
        readingStatus = String(
            localized: "Downloading from iCloud Drive…", bundle: .module,
            comment: "Import: status while the chosen export files are downloaded from iCloud Drive.")
        for url in waiting { try? FileManager.default.startDownloadingUbiquitousItem(at: url) }
        while !waiting.isEmpty, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            waiting = pending()
        }
    }

    // MARK: Importing

    func start(session: SessionModel) {
        guard let plan, let services = session.services, let journalDirectory = Self.journalDirectory(session) else { return }
        let importer = LibraryImporter(
            files: files, plan: plan, api: services.api, database: services.database, features: session.features, options: options,
            journalDirectory: journalDirectory)
        rememberSession(plan: plan, in: journalDirectory)
        stage = .running
        progress = ImportProgress()
        progress.total = plan.items.count
        progress.bytesTotal = plan.totalBytes
        summary = nil
        reportURL = nil
        let options = options
        let title = String(
            localized: "Importing photos to Nextcloud", bundle: .module,
            comment: "Title of the system's progress panel while an import runs in the background (iPhone, iPad).")
        task = Task {
            await ImportBackgroundRunner.shared.run(
                title: title,
                status: { [weak self] in
                    guard let self else { return (0, "") }
                    return (self.progress.fraction, self.statusLine)
                },
                stop: { [weak self] in self?.cancel() },
                work: { [weak self] in
                    guard let self else { return false }
                    let running = Task {
                        await importer.run { progress in
                            Task { @MainActor [weak self] in self?.update(progress) }
                        }
                    }
                    self.importTask = running
                    let result = await running.value
                    self.importTask = nil
                    await self.finish(result, importer: importer, plan: plan, options: options, journalDirectory: journalDirectory)
                    return result.phase == .finished
                })
            await session.syncNow()
        }
    }

    private func update(_ progress: ImportProgress) {
        guard stage == .running else { return }
        if let preview = progress.currentPreview, preview != previews.last {
            previews.append(preview)
            if previews.count > 24 { previews.removeFirst(previews.count - 24) }
        }
        self.progress = progress
    }

    private func finish(
        _ result: ImportProgress, importer: LibraryImporter, plan: ImportPlan, options: ImportOptions, journalDirectory: URL
    ) async {
        progress = result
        let journal = await importer.currentJournal
        let summary = ImportSummary.make(plan: plan, journal: journal, progress: result, options: options)
        self.summary = summary
        alreadyDone = journal.completed
        if result.phase == .finished {
            reportURL = await importer.writeReport(summary, upload: true)
            if summary.failed == 0 {
                ImportSessionRecord.remove(from: journalDirectory)
                resumable = nil
            }
        }
        stage = .finished
    }

    /// The line under the progress: "Uploading 1 200 of 48 213".
    var statusLine: String {
        switch progress.phase {
        case .albums:
            String(localized: "Creating albums…", bundle: .module, comment: "Import: status while albums are created.")
        default:
            String(
                localized: "\(min(progress.processed + 1, progress.total)) of \(progress.total)", bundle: .module,
                comment: "Import: the number of the item being imported, of all items.")
        }
    }

    func cancel() {
        importTask?.cancel()
        if stage == .reading {
            task?.cancel()
        }
    }

    /// Back to the start: other exports can be chosen.
    func reset() {
        task?.cancel()
        importTask?.cancel()
        task = nil
        files?.cleanUp()
        files = nil
        plan = nil
        summary = nil
        reportURL = nil
        progress = ImportProgress()
        previews = []
        error = nil
        stage = .choose
        stopAccessing()
    }

    private func stopAccessing() {
        for url in accessed { url.stopAccessingSecurityScopedResource() }
        accessed = []
    }

    // MARK: Resuming after a relaunch

    private func rememberSession(plan: ImportPlan, in directory: URL) {
        let bookmarks = urls.compactMap { try? $0.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) }
        let record = ImportSessionRecord(
            bookmarks: bookmarks, names: urls.map(\.lastPathComponent), includesPhotosLibrary: includePhotosLibrary, options: options,
            planKey: plan.key, total: plan.items.count)
        record.save(to: directory)
        resumable = record
    }

    /// Opens the files of an unfinished import again and reads them; the journal makes the import continue where it
    /// stopped.
    func resume(_ record: ImportSessionRecord, session: SessionModel) {
        var urls: [URL] = []
        for bookmark in record.bookmarks {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) {
                urls.append(url)
            }
        }
        guard urls.count == record.bookmarks.count || record.includesPhotosLibrary else {
            error = String(
                localized: "The files of the earlier import are no longer there. Choose them again: the import continues where it stopped.",
                bundle: .module, comment: "Import: resuming failed because the chosen files moved or were deleted.")
            return
        }
        includePhotosLibrary = record.includesPhotosLibrary
        let options = record.options
        read(urls, session: session)
        self.options = options
    }

    func forgetResumable(session: SessionModel) {
        if let directory = Self.journalDirectory(session) { ImportSessionRecord.remove(from: directory) }
        resumable = nil
    }

    /// Whether the destination is inside a timeline folder, so the imported photos show in the library.
    func destinationIsInTimeline(_ session: SessionModel) -> Bool {
        let destination = options.destination
        return session.features.userConfig.photosSourceFolders.contains { folder in
            folder == "/" || destination == folder || destination.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
        }
    }
}
