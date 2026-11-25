// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import AVFoundation
import PhotosCore
import PhotosDomain
import PhotosMedia
import PhotosModel
import PhotosNetworking
import SwiftUI

#if os(iOS) || os(visionOS)
    import UIKit
#endif

// MARK: - Living album covers (SPEC §16.8.2)

/// An album's cover as the user chose it: the chosen photo, still, playing its Live Photo motion once, or with the subject
/// in front of the album's title.
struct LivingAlbumCover: View {
    let album: Album
    @Environment(SessionModel.self) private var session

    var body: some View {
        if let services = session.services {
            let looks = AlbumLookStore.store(for: services)
            AlbumCoverArt(
                album: album, cover: looks.coverFileId(for: album), effect: looks.effect(for: album), playKey: album.id)
        } else if let cover = album.displayCoverFileId {
            AlbumCover(fileId: cover)
        }
    }
}

/// The cover itself, for a given photo and effect (also the preview of "Customize Cover").
struct AlbumCoverArt: View {
    let album: Album
    let cover: FileID?
    let effect: AlbumCoverEffect
    /// Live Photo motion plays once per app session and key; nil plays it every time the cover appears (the preview).
    var playKey: String?
    /// Told where the title ended up on a depth cover.
    var placementChanged: ((DepthCoverLayout.Placement) -> Void)?

    var body: some View {
        if let cover {
            switch effect {
            case .depth:
                DepthCover(fileId: cover, title: album.title, placementChanged: placementChanged)
            case .automatic:
                LiveCover(fileId: cover, playKey: playKey)
            case .still:
                AlbumCover(fileId: cover)
            }
        }
    }
}

/// When covers may move: the setting, Reduce Motion, Low Power Mode and the system's video autoplay setting.
enum LiveCoverPolicy {
    static func plays(setting: Bool, reduceMotion: Bool, lowPower: Bool, autoplay: Bool) -> Bool {
        setting && !reduceMotion && !lowPower && autoplay
    }

    /// The system's "Auto-Play Video Previews" (iPhone, iPad, Vision Pro); the Mac has none.
    @MainActor static var systemAutoplay: Bool {
        #if os(iOS) || os(visionOS)
            UIAccessibility.isVideoAutoplayEnabled
        #else
            true
        #endif
    }
}

/// Which covers played already in this app session: a cover moves once, not every time it is scrolled past.
@MainActor
enum PlayedCovers {
    static var keys: Set<String> = []
}

/// A still cover that plays its Live Photo motion once, muted, when it is well in view.
private struct LiveCover: View {
    let fileId: FileID
    let playKey: String?
    @Environment(SessionModel.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(LookSettings.liveCoversKey) private var setting = true
    @State private var item: MediaItem?
    @State private var visible = false
    @State private var playing = false

    var mayPlay: Bool {
        LiveCoverPolicy.plays(
            setting: setting, reduceMotion: reduceMotion, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            autoplay: LiveCoverPolicy.systemAutoplay)
    }

    var body: some View {
        AlbumCover(fileId: fileId)
            .overlay {
                if playing, let item {
                    LiveCoverMotion(item: item) {
                        withAnimation(.easeOut(duration: 0.45)) { playing = false }
                    }
                    .transition(.opacity)
                }
            }
            .onScrollVisibilityChange(threshold: 0.8) { isVisible in
                visible = isVisible
            }
            .task(id: fileId) {
                item = try? session.services?.library.item(fileId)
            }
            .task(id: PlayRequest(fileId: fileId, visible: visible, live: item?.isLivePhoto == true)) {
                guard visible, mayPlay, let item, item.isLivePhoto else { return }
                if let playKey, PlayedCovers.keys.contains(playKey) { return }
                // Settled in view for a moment first: a cover flicked past does not start.
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled else { return }
                if let playKey { PlayedCovers.keys.insert(playKey) }
                withAnimation(.easeIn(duration: 0.3)) { playing = item.livePhotoPeer != nil }
            }
    }

    struct PlayRequest: Hashable {
        var fileId: FileID
        var visible: Bool
        var live: Bool
    }
}

/// The motion of a Live Photo, filling the cover, muted, played once.
private struct LiveCoverMotion: View {
    let item: MediaItem
    let finished: () -> Void
    @Environment(SessionModel.self) private var session
    @State private var video: PlayableVideo?
    @State private var started = false

    var body: some View {
        Group {
            if let player = video?.player {
                CoverPlayerView(player: player)
            } else {
                Color.clear
            }
        }
        .opacity(started ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task {
            guard let peer = item.livePhotoPeer, let services = session.services else { return finished() }
            let motion = try? services.library.item(peer)
            guard
                let loaded = try? await PlayableVideo.load(
                    fileId: peer, etag: motion?.etag, name: motion?.name ?? "live.mov", mimeType: motion?.mimeType ?? "video/quicktime",
                    originalURL: motion.map { services.originalURL(for: $0) }, services: services, offline: session.offline)
            else { return finished() }
            loaded.player.isMuted = true
            loaded.player.actionAtItemEnd = .pause
            video = loaded
            // Up to a few seconds for the stream to be ready; a cover that cannot play stays still.
            for _ in 0..<40 where loaded.player.currentItem?.status != .readyToPlay {
                try? await Task.sleep(for: .milliseconds(100))
                if Task.isCancelled { return }
            }
            guard let current = loaded.player.currentItem, current.status == .readyToPlay else { return finished() }
            loaded.player.play()
            withAnimation(.easeIn(duration: 0.25)) { started = true }
            let seconds = current.duration.seconds
            let length = seconds.isFinite && seconds > 0 ? min(seconds, 4) : 3
            try? await Task.sleep(for: .seconds(max(0.5, length - 0.35)))
            finished()
        }
        .onDisappear {
            video?.release()
            video = nil
        }
    }
}

/// A player layer that fills its frame (the system player views fit the video instead).
private struct CoverPlayerView {
    let player: AVPlayer
}

#if os(macOS)
    extension CoverPlayerView: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspectFill
            view.layer = layer
            view.wantsLayer = true
            return view
        }

        func updateNSView(_ view: NSView, context: Context) {
            if let layer = view.layer as? AVPlayerLayer, layer.player !== player { layer.player = player }
        }
    }
#else
    extension CoverPlayerView: UIViewRepresentable {
        final class PlayerLayerView: UIView {
            override class var layerClass: AnyClass { AVPlayerLayer.self }
            var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }
        }

        func makeUIView(context: Context) -> PlayerLayerView {
            let view = PlayerLayerView()
            view.playerLayer?.videoGravity = .resizeAspectFill
            view.playerLayer?.player = player
            view.isUserInteractionEnabled = false
            return view
        }

        func updateUIView(_ view: PlayerLayerView, context: Context) {
            if view.playerLayer?.player !== player { view.playerLayer?.player = player }
        }
    }
#endif

// MARK: Depth

/// Subject masks of cover photos, per account, next to the account's previews (cleared and removed with them).
@MainActor
enum SubjectMasks {
    private static var caches: [AccountID: SubjectMaskCache] = [:]

    static func cache(for services: AccountServices) -> SubjectMaskCache {
        if let cache = caches[services.account.id] { return cache }
        let cache = SubjectMaskCache(directory: services.layout.previews(services.account.id).appending(path: "SubjectMasks"))
        caches[services.account.id] = cache
        return cache
    }
}

/// A cover with the album's title in its upper part and the photo's subject standing in front of the title, like the depth
/// effect of the Lock Screen. Where Vision finds no subject, or the subject would hide too much of the title, the title is
/// drawn in front.
private struct DepthCover: View {
    let fileId: FileID
    let title: String
    var placementChanged: ((DepthCoverLayout.Placement) -> Void)?
    @Environment(SessionModel.self) private var session
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var image: CGImage?
    @State private var mask: SubjectMask?

    /// Long side of the picture the cover and its mask are made from.
    static let pixels = 768

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                if let image {
                    photo(image, size: size)
                    titleText(size: size)
                    if let mask, mask.placement == .behindSubject {
                        photo(image, size: size)
                            .mask {
                                Image(decorative: mask.image, scale: 1)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: size.width, height: size.height)
                                    .clipped()
                            }
                            .transition(.opacity)
                    }
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .animation(.easeInOut(duration: 0.3), value: mask?.placement)
        }
        .task(id: fileId) { await load() }
    }

    func photo(_ image: CGImage, size: CGSize) -> some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: size.width, height: size.height)
            .clipped()
    }

    /// Large and heavy, centred in the title band; the card's own label says the title to VoiceOver.
    func titleText(size: CGSize) -> some View {
        let band: CGRect = DepthCoverLayout.titleBand
        let side: CGFloat = min(size.width, size.height)
        return Text(title)
            .font(.system(size: max(14, side * 0.19), weight: .heavy, design: .rounded))
            .minimumScaleFactor(0.35)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(contrast == .increased ? 0.75 : 0.35), radius: contrast == .increased ? 3 : 8, y: 1)
            .frame(width: band.width * size.width, height: band.height * size.height)
            .offset(x: band.minX * size.width, y: band.minY * size.height)
            .accessibilityHidden(true)
    }

    /// The mask is drawn filling the cover like the photo: it fits when both have the same shape.
    static func sameShape(_ a: CGImage, _ b: CGImage) -> Bool {
        guard a.height > 0, b.height > 0 else { return false }
        return abs(Double(a.width) / Double(a.height) - Double(b.width) / Double(b.height)) < 0.01
    }

    func load() async {
        guard let services = session.services else { return }
        let fileId = fileId
        let etag = (try? services.library.item(fileId))?.etag ?? ""
        let request = ImagePipeline.Request(
            fileId: fileId, etag: etag, bucket: 1024, hasPreview: true, mimeType: "image/jpeg", originalURL: nil,
            maxPixelSize: Self.pixels)
        if let cached = services.images.cache.bestMemoryImage(fileId: fileId, etag: etag, upTo: 1024) { image = cached }
        guard let loaded = await services.images.preview(request) else { return }
        image = loaded
        let cache = SubjectMasks.cache(for: services)
        let result: SubjectMaskCache.Result
        if let known = await cache.cached(fileId: fileId, etag: etag) {
            result = known
        } else {
            // Vision on the device, off the main thread; the picture is the one shown, so the mask fits it exactly.
            result = await cache.mask(fileId: fileId, etag: etag) { loaded }
        }
        if case .mask(let made) = result, Self.sameShape(made.image, loaded) {
            mask = made
            placementChanged?(made.placement)
        } else {
            mask = nil
            placementChanged?(.inFront)
        }
    }
}
