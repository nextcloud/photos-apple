// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosMedia
import PhotosModel
import SwiftUI

/// A photo page: pinch, double-tap and keyboard zoom in a real scroll view (`ZoomSurface`), with progressive
/// resolution (SPEC §5.5.2) and Live Photo playback while pressed.
struct ZoomablePhoto: View {
    let item: MediaItem
    var isCurrent = true
    var command: ViewerZoomCommand?
    var events = ZoomSurfaceEvents()
    @State private var image: CGImage?
    /// Set once the photo was zoomed far enough to need the large preview; it is kept afterwards.
    @State private var needsDetail = false
    @State private var playingLive = false
    @Environment(SessionModel.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var lock = AppLock.shared

    var bucket: Int { needsDetail ? 4096 : 1024 }

    /// The photo's shape: of the image shown, else what the server says, else unknown (the page is filled).
    var contentSize: CGSize {
        if let image { return CGSize(width: image.width, height: image.height) }
        if let width = item.width, let height = item.height, width > 0, height > 0 { return CGSize(width: width, height: height) }
        return .zero
    }

    /// Live Text and Visual Look Up (SPEC VW-4) for the photo shown, once its preview is there.
    var analysesLiveText: Bool {
        LiveTextPolicy.analyzes(
            isCurrent: isCurrent, hasImage: image != nil, sceneIsActive: scenePhase == .active, requiresUnlock: lock.requiresUnlock)
    }

    var surfaceEvents: ZoomSurfaceEvents {
        var surface: ZoomSurfaceEvents = events
        let scaleChanged: (CGFloat) -> Void = events.scaleChanged
        surface.scaleChanged = { scale in
            if scale >= ViewerZoom.highResolutionScale { needsDetail = true }
            scaleChanged(scale)
        }
        surface.pressing = { pressing in
            guard item.isLivePhoto else { return }
            withAnimation { playingLive = pressing }
        }
        return surface
    }

    var body: some View {
        ZStack {
            ZoomSurface(
                image: image ?? BlurHashCache.image(item.blurhash), contentSize: contentSize, command: command, isCurrent: isCurrent,
                animates: !reduceMotion, pressEnabled: item.isLivePhoto, liveText: analysesLiveText, events: surfaceEvents)
            if playingLive, item.livePhotoPeer != nil {
                LivePhotoMotion(item: item)
                    .background(.black)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topLeading) {
            if item.isLivePhoto {
                Label(String(localized: "Live", bundle: .module), systemImage: "livephoto")
                    .font(.caption.weight(.semibold))
                    .padding(6)
                    .background(.ultraThinMaterial, in: .capsule)
                    .padding(.top, 60)
                    .padding(.leading, 12)
                    .allowsHitTesting(false)
            }
        }
        .task(id: "\(item.fileId)-\(item.etag)-\(bucket)") { await load() }
    }

    /// As `PreviewImage`: what is in memory at once, then the preview of the wanted size.
    func load() async {
        guard let services = session.services else { return }
        if let cached = services.images.cache.bestMemoryImage(fileId: item.fileId, etag: item.etag, upTo: bucket) { image = cached }
        let request = ImagePipeline.Request(
            fileId: item.fileId, etag: item.etag, bucket: bucket, hasPreview: item.hasPreview, mimeType: item.mimeType,
            originalURL: services.originalURL(for: item))
        if let loaded = await services.images.preview(request) { image = loaded }
    }
}
