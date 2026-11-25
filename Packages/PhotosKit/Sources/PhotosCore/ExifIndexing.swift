// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import OSLog
import Observation
import PhotosDomain
import PhotosModel
import PhotosNetworking
import PhotosStore

/// Reads the camera data of the library's photos for Insights (SPEC §16.5.1), lazily and in the background: it starts
/// when Insights is opened and goes on while the app runs, a page or a batch at a time with pauses in between, newest
/// photos first. Only what the stock server already has (`nc:metadata-photos-exif` / `-ifd0`); nothing is analysed on the
/// server for it.
@MainActor
@Observable
public final class ExifIndexing {
    public static let shared = ExifIndexing()

    /// Reading is under way for the active account.
    public private(set) var isRunning = false
    /// Goes up whenever a batch was stored: Insights reloads its numbers.
    public private(set) var revision = 0
    /// Why the last run stopped early (offline, server error); it starts again with the next visit.
    public private(set) var lastError: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var account: AccountID?
    @ObservationIgnored private weak var session: SessionModel?
    @ObservationIgnored private let logger = Logger(subsystem: "com.nextcloud.photos", category: "insights")

    /// A pause between two requests, so reading tens of thousands of photos never loads the server.
    nonisolated static let pause: Duration = .milliseconds(250)
    /// From this many photos to read on, the library is paged through (500 a request) instead of asked for by id (50).
    nonisolated static let pagingThreshold = 1000

    init() {}

    /// Starts reading for the session's account, unless it runs already.
    public func start(session: SessionModel) {
        guard let services = session.services, !session.isSignedOut else { return }
        if account == session.account.id, task != nil { return }
        task?.cancel()
        account = session.account.id
        lastError = nil
        isRunning = true
        let folders = session.features.userConfig.photosSourceFolders
        let mimeTypes = session.features.imageMimeTypes + MimeTypes.appleExtras
        let excluded = session.excludedFolders
        let id = session.account.id
        self.session = session
        let reader = ExifReader(
            api: services.api, store: InsightsStore(database: services.database), sourceFolders: folders, mimeTypes: mimeTypes,
            excludedFolders: excluded)
        task = Task { [weak self] in
            do {
                try await reader.run(pause: Self.pause) { [weak self] in
                    await self?.batchStored(id) ?? false
                }
            } catch is CancellationError {
            } catch {
                self?.failed(error)
            }
            self?.finish(id)
        }
    }

    /// After each stored batch: the screen reloads; reading stops when another account is shown or the session ended.
    private func batchStored(_ id: AccountID) -> Bool {
        revision += 1
        return account == id && session?.account.id == id && session?.services != nil
    }

    private func failed(_ error: any Error) {
        logger.error("reading EXIF stopped: \(error.localizedDescription, privacy: .public)")
        lastError = error.localizedDescription
    }

    private func finish(_ id: AccountID) {
        guard account == id else { return }
        isRunning = false
        task = nil
        revision += 1
    }

    /// Stops reading (account removed or switched).
    public func stop() {
        task?.cancel()
        task = nil
        account = nil
        isRunning = false
    }
}

/// The reading itself, off the main actor: pages through a large library first, then asks for the rest by id.
struct ExifReader: Sendable {
    let api: PhotosAPI
    let store: InsightsStore
    let sourceFolders: [String]
    let mimeTypes: [String]
    let excludedFolders: [String]

    /// Reads until every photo of the library has its row; after each stored batch `stored` is called, and reading
    /// stops when it says false.
    func run(
        pause: Duration, pagingThreshold: Int = ExifIndexing.pagingThreshold, stored: @Sendable () async -> Bool
    ) async throws {
        try store.removeOrphans()
        var all = try store.pending(limit: Int.max, excludedFolders: excludedFolders)
        guard !all.isEmpty else { return }
        if all.count >= pagingThreshold {
            guard try await page(through: all, pause: pause, stored: stored) else { return }
            all = try store.pending(limit: Int.max, excludedFolders: excludedFolders)
        }
        for start in stride(from: 0, to: all.count, by: 50) {
            try Task.checkCancellation()
            let batch = Array(all[start..<min(start + 50, all.count)])
            let records = try await api.exifRecords(fileIds: batch.map(\.fileId))
            let byId = Dictionary(records.map { ($0.fileId, $0) }, uniquingKeysWith: { first, _ in first })
            var facts: [FileID: (etag: String, facts: ExifFacts)] = [:]
            for item in batch {
                // A photo the server did not return (deleted meanwhile, no longer shared) gets an empty row. Rows
                // carry the index's ETag: a photo is asked for again when the sync sees it change, not before.
                facts[item.fileId] = (item.etag, Self.facts(byId[item.fileId]?.tags ?? [:], for: item))
            }
            try store.store(facts)
            guard await stored() else { return }
            try await Task.sleep(for: pause)
        }
    }

    /// Pages through the timeline folders newest first, storing the photos that are still to be read. False when
    /// `stored` said stop.
    func page(through pending: [InsightsStore.Pending], pause: Duration, stored: @Sendable () async -> Bool) async throws -> Bool {
        let wanted = Dictionary(pending.map { ($0.fileId, $0) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<FileID> = []
        var cursor: Double?
        while true {
            try Task.checkCancellation()
            let page = try await api.exifPage(sourceFolders: sourceFolders, mimeTypes: mimeTypes, before: cursor)
            let fresh = page.filter { seen.insert($0.fileId).inserted }
            var facts: [FileID: (etag: String, facts: ExifFacts)] = [:]
            for record in fresh {
                guard let item = wanted[record.fileId] else { continue }
                facts[record.fileId] = (item.etag, Self.facts(record.tags, for: item))
            }
            try store.store(facts)
            guard await stored() else { return false }
            // The page boundary is inclusive: a page of only photos seen already (many in one second) ends the paging;
            // the by-id pass picks up what is left.
            guard !fresh.isEmpty, let oldest = page.compactMap(\.capturedAt).min(), oldest != cursor else { return true }
            cursor = oldest
            try await Task.sleep(for: pause)
        }
    }

    /// The facts of a photo, with the hour from its capture time where the EXIF has no date (screenshots, edited
    /// copies): in the photo's own time zone when known, else this device's.
    static func facts(_ tags: [String: String], for item: InsightsStore.Pending, timeZone: TimeZone = .current) -> ExifFacts {
        var facts = ExifFacts.parse(tags)
        if facts.hour == nil, let captured = item.capturedAt {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = item.captureOffset.flatMap { TimeZone(secondsFromGMT: $0) } ?? timeZone
            facts.hour = calendar.component(.hour, from: captured)
        }
        return facts
    }
}
