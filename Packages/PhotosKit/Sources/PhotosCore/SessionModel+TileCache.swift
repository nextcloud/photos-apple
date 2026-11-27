// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosMedia
import PhotosStore

/// When the tile cache is built (SPEC §22.4.1): in the background after a sync, the first time a while after the
/// launch, then at most every ten minutes; not in Low Power Mode.
struct TileCacheBuildState {
    var task: Task<Void, Never>?
    var lastRun: Date?
}

extension SessionModel {
    /// The wait after the launch's sync before the first build: the launch's own work goes first.
    static let tileCacheFirstDelay: Duration = .seconds(20)
    static let tileCacheInterval: TimeInterval = 600

    func scheduleTileCacheBuild(now: Date = Date()) {
        guard let services, !isStopped, tileCacheBuild.task == nil else { return }
        if let last = tileCacheBuild.lastRun, now.timeIntervalSince(last) < Self.tileCacheInterval { return }
        let first = tileCacheBuild.lastRun == nil
        tileCacheBuild.lastRun = now
        let images = services.images
        let builder = TileCacheBuilder(
            tiles: images.cache.tiles, cache: images.cache, store: CacheFillStore(database: services.database),
            budget: TileCacheBuilder.budget(previewLimit: CacheLimits.current().previewBytes), excludedFolders: excludedFolders,
            displayedEtag: { images.displayedEtag(fileId: $0, etag: $1) })
        let delay: Duration = first ? Self.tileCacheFirstDelay : .zero
        tileCacheBuild.task = Task.detached(priority: .background) { [weak self] in
            try? await Task.sleep(for: delay)
            if !Task.isCancelled, !ProcessInfo.processInfo.isLowPowerModeEnabled {
                _ = await builder.run { !Task.isCancelled && !ProcessInfo.processInfo.isLowPowerModeEnabled }
            }
            await MainActor.run { self?.tileCacheBuild.task = nil }
        }
    }
}
