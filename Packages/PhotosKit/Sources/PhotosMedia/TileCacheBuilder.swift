// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import OSLog
import PhotosModel
import PhotosStore

/// Fills the tile cache (SPEC §22.4.1) from the previews in the disk cache, newest month first, in the background.
///
/// Goes through the library in pages (the cache fillers' query: what the timeline shows, newest first), month by month.
/// A month's file is written again only when a photo got a tile it did not have (its preview is cached now, or it
/// changed) or when more than a tenth of its tiles belong to photos that are gone; tiles that are still right are
/// copied over, so a build after a sync makes only the new ones. Nothing is downloaded: a photo without a cached preview
/// gets its tile at a later build. Months beyond the budget (the oldest) and months the library no longer has lose
/// their files.
public struct TileCacheBuilder: Sendable {
    let tiles: TileCache
    let cache: PreviewCache
    let store: CacheFillStore
    /// The ETag the grid shows a photo under (an edited photo has its own, `ImagePipeline.displayedEtag`).
    let displayedEtag: @Sendable (FileID, String) -> String
    let budget: Int64
    let excludedFolders: [String]
    private let logger = Logger(subsystem: "com.nextcloud.photos", category: "images")

    /// The previews a tile is made from, in this order: the grid's own size on iPhone, then the Mac's and iPad's.
    static let sourceBuckets = [256, 1024, 4096]

    public init(
        tiles: TileCache, cache: PreviewCache, store: CacheFillStore, budget: Int64, excludedFolders: [String] = [],
        displayedEtag: @escaping @Sendable (FileID, String) -> String = { _, etag in etag }
    ) {
        self.tiles = tiles
        self.cache = cache
        self.store = store
        self.budget = budget
        self.excludedFolders = excludedFolders
        self.displayedEtag = displayedEtag
    }

    /// The tile cache's share of the preview cache's limit: an eighth, at least 64 MB (about 7 000 photos).
    public static func budget(previewLimit: Int64) -> Int64 { max(64 << 20, previewLimit / 8) }

    public struct Outcome: Sendable, Equatable {
        public var months = 0
        public var monthsWritten = 0
        public var tilesMade = 0
        public var tiles = 0
        public var bytes: Int64 = 0
        public var finished = false
    }

    /// One pass. `shouldContinue` is asked between months and every 50 tiles; a pass that stops is simply done again
    /// later (the files are the state).
    public func run(shouldContinue: @escaping @Sendable () -> Bool = { true }) async -> Outcome {
        var outcome = Outcome()
        var cursor: CacheFillStore.Cursor?
        var month: String?
        var members: [CacheFillStore.Photo] = []
        var kept: Set<String> = []
        var overBudget = false
        func finish(_ name: String, _ photos: [CacheFillStore.Photo]) {
            outcome.months += 1
            guard !overBudget else { return }
            let result = buildMonth(name, photos: photos, shouldContinue: shouldContinue)
            outcome.tilesMade += result.made
            outcome.tiles += result.tiles
            outcome.bytes += result.bytes
            if result.written { outcome.monthsWritten += 1 }
            kept.insert(name)
            if outcome.bytes >= budget { overBudget = true }
        }
        while shouldContinue() {
            guard let page = try? await store.libraryPage(after: cursor, limit: 1000, excludedFolders: excludedFolders) else {
                return outcome
            }
            for photo in page {
                let key = TileCache.month(of: photo.timestamp)
                if key != month {
                    if let month { finish(month, members) }
                    month = key
                    members = []
                }
                members.append(photo)
            }
            guard let last = page.last else {
                if let month { finish(month, members) }
                outcome.finished = true
                break
            }
            cursor = CacheFillStore.Cursor(timestamp: last.timestamp, fileId: last.fileId)
            await Task.yield()
        }
        // Months beyond the budget and months without photos any more.
        if outcome.finished {
            for name in tiles.files().keys where !kept.contains(name) { tiles.remove(month: name) }
        }
        logger.info(
            "tiles: \(outcome.tilesMade) made, \(outcome.monthsWritten) of \(outcome.months) months written, \(outcome.tiles) tiles, \(outcome.bytes) bytes"
        )
        return outcome
    }

    /// Brings one month's file up to date. Returns its tiles, bytes, how many were made and whether it was written.
    func buildMonth(_ month: String, photos: [CacheFillStore.Photo], shouldContinue: () -> Bool) -> (
        tiles: Int, bytes: Int64, made: Int, written: Bool
    ) {
        let existing = tiles.entries(month: month)
        let block = tiles.block(month)
        var result: [(fileId: FileID, etag: UInt64, data: Data)] = []
        var made = 0
        var stale = existing.count
        for (index, photo) in photos.enumerated() {
            // Stopped half-way: the month stays as it was (a partial file would lose the tiles not looked at yet).
            if index % 50 == 49, !shouldContinue() { return (existing.count, 0, 0, false) }
            let etag = displayedEtag(photo.fileId, photo.etag)
            let hash = TileCache.etagHash(etag)
            if let entry = existing[photo.fileId], entry.etag == hash, let data = block?.tile(photo.fileId, etag: hash) {
                result.append((photo.fileId, hash, data))
                stale -= 1
                continue
            }
            guard let preview = Self.sourceBuckets.lazy.compactMap({ cache.diskData(fileId: photo.fileId, etag: etag, bucket: $0) }).first,
                let tile = TileCache.makeTile(from: preview)
            else { continue }
            result.append((photo.fileId, hash, tile))
            made += 1
        }
        let bytes = result.reduce(Int64(0)) { $0 + Int64($1.data.count) }
        // Nothing new, and what is gone is not worth a rewrite.
        if made == 0, stale * 10 <= max(existing.count, 1) {
            return (existing.count - stale, existing.count == 0 ? 0 : bytes, 0, false)
        }
        do {
            try tiles.write(month: month, tiles: result)
        } catch {
            logger.notice("tiles: \(month, privacy: .public) not written (\(error.localizedDescription, privacy: .public))")
            return (0, 0, 0, false)
        }
        return (result.count, bytes, made, true)
    }
}
