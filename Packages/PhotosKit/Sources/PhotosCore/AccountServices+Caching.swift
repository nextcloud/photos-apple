// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosDomain
import PhotosMedia
import PhotosModel
import PhotosStore

/// What the caches learn about which photos matter (SPEC §18.2): what the viewer shows, and where photos are shown
/// besides the grids.
extension AccountServices {
    /// How long the viewer must show a photo before it counts as viewed (paging through quickly is not looking).
    public static let viewedAfter: Duration = .seconds(1)

    /// The viewer shows `fileId`, with `neighbours` next to it. Run it in a task per photo (`.task(id:)`), which ends when
    /// the viewer pages on or closes:
    /// - while it runs, the photo's decodes and its neighbours' stay in memory under memory pressure;
    /// - after `viewedAfter`, the photo is remembered as recently viewed (`CacheImportanceStore`), which ranks it higher
    ///   for smart offline and for the preview cache's eviction.
    public func viewerShows(_ fileId: FileID?, neighbours: [FileID]) async {
        guard let fileId else { return }
        let cache = images.cache
        cache.setViewerFocus(current: fileId, neighbours: neighbours)
        defer { cache.clearViewerFocus(ifCurrent: fileId) }
        do {
            try await Task.sleep(for: Self.viewedAfter)
            try await CacheImportanceStore(database: database).noteViewed(fileId)
            // Keeps the focus until the viewer moves on.
            while !Task.isCancelled { try await Task.sleep(for: .seconds(3600)) }
        } catch {}
    }

    /// Photos that the app shows in `role` now (key photos of the Library, memory covers): they rank higher for eviction and
    /// smart offline, and their thumbnails stay in memory under memory pressure. Writes only when they changed.
    public func noteCacheRole(_ role: CacheImportance.Roles, fileIds: Set<FileID>) async {
        let store = CacheImportanceStore(database: database)
        guard (try? await store.setRole(role, fileIds: fileIds)) == true,
            let prominent = try? await store.prominentFileIds()
        else { return }
        images.cache.setProtectedInMemory(prominent)
    }

    /// The key photos of the Library's years, months and days (and a day's highlights), as the zoom levels show them.
    public func noteKeyPhotos(of summary: LibrarySummary) async {
        var ids: Set<FileID> = []
        for bucket in summary.years + summary.months + summary.days {
            ids.insert(bucket.key.fileId)
            for highlight in bucket.highlights { ids.insert(highlight.fileId) }
        }
        await noteCacheRole(.keyPhoto, fileIds: ids)
    }

    /// What a trim of the preview cache knows about the photos: their importance, the photos shown as covers, and (when
    /// the whole library's thumbnails are kept) the library's ETags. A few queries, whatever the size of the library.
    static func evictionContext(_ database: AccountDatabase, defaults: UserDefaults = .standard) -> PreviewCache.EvictionContext {
        let store = CacheImportanceStore(database: database)
        let library = CacheLimits.keepsWholeLibraryThumbnails(defaults) ? try? store.libraryEtags() : nil
        return PreviewCache.EvictionContext(
            tiers: (try? store.tiers()) ?? [:], libraryEtags: library, prominent: Set(((try? store.roles()) ?? [:]).keys))
    }
}
