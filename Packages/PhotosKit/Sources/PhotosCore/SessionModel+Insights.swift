// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosDomain
import PhotosModel
import PhotosStore

/// Photographer's statistics (SPEC §16.5.1).
extension SessionModel {
    /// What Insights shows, and how far reading the camera data has come.
    public struct InsightsSnapshot: Sendable, Equatable {
        public var summary: InsightsSummary
        public var analysed: Int
        public var total: Int

        public init(summary: InsightsSummary = InsightsSummary(), analysed: Int = 0, total: Int = 0) {
            self.summary = summary
            self.analysed = analysed
            self.total = total
        }
    }

    /// The numbers of the library as far as its camera data is known (computed off the main thread).
    public func insights() async throws -> InsightsSnapshot {
        guard let services else { return InsightsSnapshot() }
        let store = InsightsStore(database: services.database)
        let excluded = excludedFolders
        let rows = try await store.rows(excludedFolders: excluded)
        let summary = await Task.detached(priority: .userInitiated) { PhotoInsights.summarize(rows) }.value
        let progress = try await store.progress(excludedFolders: excluded)
        return InsightsSnapshot(summary: summary, analysed: progress.analysed, total: progress.total)
    }

    /// The camera data of one photo (the loupe's info line): from the index, else read from the server and kept.
    public func exifFacts(for item: MediaItem) async -> ExifFacts? {
        guard let services, item.kind == .image else { return nil }
        let store = InsightsStore(database: services.database)
        if let known = try? await store.facts(of: item.fileId, etag: item.etag) { return known }
        guard let tags = try? await services.api.exif(userPath: item.path) else { return nil }
        let pending = InsightsStore.Pending(
            fileId: item.fileId, etag: item.etag, path: item.path, capturedAt: item.capturedAt, captureOffset: item.captureOffset)
        let facts = ExifReader.facts(tags, for: pending)
        try? store.store([item.fileId: (item.etag, facts)])
        return facts
    }

    /// The photos behind a bar of Insights, newest first.
    public func insightsItems(_ filter: InsightsFilter) async throws -> [MediaItem] {
        guard let services else { return [] }
        return try await InsightsStore(database: services.database).items(matching: filter, excludedFolders: excludedFolders)
    }
}
