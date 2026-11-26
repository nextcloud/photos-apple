// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosMedia
import PhotosModel
import SwiftUI

/// Loads the viewer's neighbours ahead of time (SPEC §18.1.2): whenever the page changes, the 1024 px previews of the
/// two pages on each side (the direction of paging first) are downloaded or decoded from disk, and what is no longer
/// a neighbour is taken back. After a moment on a photo, on an inexpensive network, its 4096 px preview is downloaded
/// for zooming.
struct ViewerNeighbourPrefetch: ViewModifier {
    /// The photos of the pages, in order.
    let pages: [FileID]
    let current: FileID?
    @Environment(SessionModel.self) private var session
    @State private var prefetcher = ViewerPrefetcher()

    func body(content: Content) -> some View {
        content
            .task(id: current) {
                guard let current, let services = session.services else { return }
                await prefetcher.show(current, in: pages, services: services)
            }
            .onDisappear { prefetcher.stop() }
    }
}

/// The prefetches the viewer has asked for, so it can take them back.
@MainActor
final class ViewerPrefetcher {
    private var previousIndex: Int?
    private var neighbours: Set<ImagePipeline.Request> = []
    private var detail: ImagePipeline.Request?
    private var images: ImagePipeline?

    /// The page shows `current`. Runs until the next page is shown (the task is cancelled then).
    func show(_ current: FileID, in pages: [FileID], services: AccountServices) async {
        let images = services.images
        self.images = images
        takeBackDetail()
        guard let index = pages.firstIndex(of: current) else { return }
        let direction = ViewerPrefetchPlan.direction(from: previousIndex, to: index)
        previousIndex = index
        let ids: [FileID] = ViewerPrefetchPlan.neighbours(of: index, count: pages.count, direction: direction).map { pages[$0] }
        let items: [FileID: MediaItem] = (try? await services.library.fetchItems(ids + [current])) ?? [:]
        guard !Task.isCancelled else { return }
        // Video pages show the same 1024 px preview as their poster.
        let requests: [ImagePipeline.Request] = ids.compactMap { id in
            items[id].map { Self.request(for: $0, bucket: ViewerPrefetchPlan.neighbourBucket, services: services) }
        }
        let wanted = Set(requests)
        let gone = neighbours.subtracting(wanted)
        neighbours = wanted
        if !gone.isEmpty { await images.cancelPrefetch(for: Array(gone)) }
        // The pipeline starts the last of a batch first.
        await images.prefetch(requests.reversed(), decode: true)

        guard let item = items[current], item.kind == .image else { return }
        try? await Task.sleep(for: ViewerPrefetchPlan.detailDelay)
        guard !Task.isCancelled, ViewerPrefetchPlan.loadsDetailNow else { return }
        var large = Self.request(for: item, bucket: ViewerPrefetchPlan.detailBucket, services: services)
        large.maxPixelSize = ViewerPrefetchPlan.detailDecodeSize
        detail = large
        await images.prefetch([large])
    }

    /// The viewer closed: nothing it asked for is loaded any more unless something else wants it.
    func stop() {
        let taken: [ImagePipeline.Request] = Array(neighbours) + (detail.map { [$0] } ?? [])
        neighbours = []
        detail = nil
        previousIndex = nil
        guard let images, !taken.isEmpty else { return }
        Task { await images.cancelPrefetch(for: taken) }
    }

    private func takeBackDetail() {
        guard let detail, let images else { return }
        self.detail = nil
        Task { await images.cancelPrefetch(for: [detail]) }
    }

    static func request(for item: MediaItem, bucket: Int, services: AccountServices) -> ImagePipeline.Request {
        ImagePipeline.Request(
            fileId: item.fileId, etag: item.etag, bucket: bucket, hasPreview: item.hasPreview, mimeType: item.mimeType,
            originalURL: services.originalURL(for: item))
    }
}
