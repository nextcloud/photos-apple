// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import AVKit
import Combine
import PhotosCore
import PhotosMedia
import PhotosModel
import PhotosNetworking
import SwiftUI

/// Why a video is not playing, said in a way the user can act on.
struct VideoFailure: Equatable {
    /// What happened.
    var message: String
    /// The reason, when there is one worth showing.
    var detail: String?
    /// Trying again can help (the server was not reachable, the conversion was not ready).
    var canRetry = true

    /// The video could not be loaded or stopped playing.
    static func loading(_ error: (any Error)?) -> VideoFailure {
        VideoFailure(message: String(localized: "This video couldn't be loaded.", bundle: .module), detail: reason(error))
    }

    /// The format cannot be played and the server does not convert videos.
    static var unsupportedFormat: VideoFailure {
        #if os(macOS)
            let message = String(localized: "This video format can't be played on this Mac.", bundle: .module)
        #else
            let message = String(localized: "This video format can't be played on this device.", bundle: .module)
        #endif
        return VideoFailure(message: message, canRetry: false)
    }

    /// The server did not finish converting in the time the app waits for it.
    static var conversionTakesLong: VideoFailure {
        VideoFailure(
            message: String(localized: "The server is still converting this video.", bundle: .module),
            detail: String(localized: "Try again in a few minutes.", bundle: .module))
    }

    /// The app's own network errors already say what is wrong; other errors (AVFoundation, the system) are passed on
    /// as they are, cancellations are not a reason.
    static func reason(_ error: (any Error)?) -> String? {
        guard let error, !(error is CancellationError) else { return nil }
        if let network = error as? NetworkError, network == .cancelled { return nil }
        let text: String = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// While the server converts a video it answers 404: keep waiting. Anything else will not get better by waiting.
    static func isStillConverting(_ error: any Error) -> Bool {
        (error as? NetworkError) == .notFound
    }
}

/// What a video page shows until the player is there.
enum VideoLoadPhase: Equatable {
    case loading
    /// The server converts the video to a format that can be played; this can take minutes.
    case preparing
    case failed(VideoFailure)
}

/// Plays the motion part of a Live Photo while pressed.
struct LivePhotoMotion: View {
    let item: MediaItem
    @Environment(SessionModel.self) private var session
    @State private var video: PlayableVideo?

    var body: some View {
        Group {
            if let player = video?.player {
                PlayerSurface(player: player, showsControls: false)
                    .disabled(true)
                    .onAppear { player.play() }
            } else {
                Color.clear
            }
        }
        .task {
            guard let peer = item.livePhotoPeer, let services = session.services else { return }
            // The motion part is a hidden sibling file; without its row fall back to a QuickTime stream.
            let motion = try? services.library.item(peer)
            video = try? await PlayableVideo.load(
                fileId: peer, etag: motion?.etag, name: motion?.name ?? "live.mov", mimeType: motion?.mimeType ?? "video/quicktime",
                originalURL: motion.map { services.originalURL(for: $0) }, services: services, offline: session.offline)
        }
        // Only shown while pressed: nothing of it stays once the photo is let go or paged away.
        .onDisappear {
            video?.release()
            video = nil
        }
    }
}

/// The system video player.
///
/// On the Mac this wraps `AVPlayerView` directly: SwiftUI's `VideoPlayer` crashes there when it is the first
/// thing to touch AVKit ("failed to demangle superclass of VideoPlayerView"), as it does in this package.
/// On iPhone and iPad it wraps `AVPlayerViewController`, so the page can add "swipe down to close" to the player's
/// view without laying a gesture over its controls.
struct PlayerSurface: View {
    let player: AVPlayer
    var showsControls = true
    /// Vertical swipes on the player, outside its controls (iPhone, iPad).
    var verticalDrag: ((ViewerSwipe.Phase) -> Void)?

    var body: some View {
        #if os(macOS)
            MacPlayerView(player: player, showsControls: showsControls)
        #elseif os(iOS)
            PhonePlayerView(player: player, showsControls: showsControls, verticalDrag: verticalDrag)
        #else
            VideoPlayer(player: player)
        #endif
    }
}

#if os(macOS)
    private struct MacPlayerView: NSViewRepresentable {
        let player: AVPlayer
        let showsControls: Bool

        func makeNSView(context: Context) -> AVPlayerView {
            let view = AVPlayerView()
            view.controlsStyle = showsControls ? .floating : .none
            view.videoGravity = .resizeAspect
            view.player = player
            return view
        }

        func updateNSView(_ view: AVPlayerView, context: Context) {
            if view.player !== player { view.player = player }
        }
    }
#elseif os(iOS)
    private struct PhonePlayerView: UIViewControllerRepresentable {
        let player: AVPlayer
        let showsControls: Bool
        var verticalDrag: ((ViewerSwipe.Phase) -> Void)?

        @MainActor
        final class Coordinator {
            var swipe: VerticalSwipe?
            var verticalDrag: ((ViewerSwipe.Phase) -> Void)?
        }

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeUIViewController(context: Context) -> AVPlayerViewController {
            let controller = AVPlayerViewController()
            controller.player = player
            controller.showsPlaybackControls = showsControls
            controller.videoGravity = .resizeAspect
            controller.view.backgroundColor = .clear
            let coordinator: Coordinator = context.coordinator
            coordinator.verticalDrag = verticalDrag
            if verticalDrag != nil {
                let swipe = VerticalSwipe(
                    view: controller.view, isAllowed: { true },
                    handler: { [weak coordinator] phase in coordinator?.verticalDrag?(phase) })
                // The scrubber and the buttons keep their touches.
                swipe.ignoresControls = true
                coordinator.swipe = swipe
            }
            return controller
        }

        func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
            if controller.player !== player { controller.player = player }
            context.coordinator.verticalDrag = verticalDrag
        }
    }
#endif

/// A player together with what keeps its data flowing.
@MainActor
struct PlayableVideo {
    let player: AVPlayer
    /// Retained here: the asset's resource loader only holds its delegate weakly.
    let loader: StreamingAssetLoader?

    init(file: URL) {
        player = AVPlayer(url: file)
        loader = nil
    }

    init(loader: StreamingAssetLoader, fileName: String) {
        player = AVPlayer(playerItem: AVPlayerItem(asset: loader.makeAsset(fileName: fileName)))
        self.loader = loader
    }

    /// Stops playback and lets go of the item, its buffers and (once this value is dropped) the stream behind it. A
    /// paused player still holds its buffers and may keep loading ahead.
    func release() {
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    /// Prefers a local copy (offline album, already downloaded original); otherwise streams a temporary
    /// direct-download URL through the app's own HTTP client, so certificates the user trusted and the
    /// account's client certificate apply to video like to everything else (SPEC §5.5.3).
    static func load(
        fileId: FileID, etag: String?, name: String, mimeType: String, originalURL: URL?, services: AccountServices,
        offline: OfflineManager?
    ) async throws -> PlayableVideo {
        if let etag {
            if let local = offline?.localFile(fileId: fileId, etag: etag) { return PlayableVideo(file: local) }
            if let originalURL, let cached = services.images.originals.cached(fileId: fileId, etag: etag, url: originalURL) {
                return PlayableVideo(file: cached)
            }
        }
        let url = try await services.api.directDownloadURL(fileId: fileId)
        let source = MediaByteSource(url: url, headers: ["User-Agent": services.connection.userAgent], http: services.http)
        return PlayableVideo(loader: StreamingAssetLoader(source: source, mimeType: mimeType), fileName: name)
    }
}

/// Video playback from the local copy or streamed through the app's HTTP client (SPEC §5.5.3).
struct VideoPage: View {
    let item: MediaItem
    let isCurrent: Bool
    var playbackToggle = 0
    var verticalDrag: ((ViewerSwipe.Phase) -> Void)?
    @Environment(SessionModel.self) private var session
    @State private var video: PlayableVideo?
    @State private var phase = VideoLoadPhase.loading
    /// Counted up by "Try again".
    @State private var attempt = 0
    /// Where playback was when the page was paged away; it goes on from there when the page is shown again.
    @State private var resumeAt: Double?

    /// How often and how long the app waits for the server to convert a video (2 minutes).
    static let conversionAttempts = 12
    static let conversionInterval = Duration.seconds(10)

    struct LoadRequest: Hashable {
        var isCurrent: Bool
        var attempt: Int
    }

    var player: AVPlayer? { video?.player }

    var body: some View {
        ZStack {
            if let player {
                PlayerSurface(player: player, verticalDrag: verticalDrag)
            } else {
                PreviewImage(item: item, bucket: 1024, contentMode: .fit)
                status
            }
        }
        .task(id: LoadRequest(isCurrent: isCurrent, attempt: attempt)) { await load() }
        .task(id: player.map { ObjectIdentifier($0) }) { await watchPlayback() }
        .onChange(of: playbackToggle) {
            guard isCurrent, let player else { return }
            if player.timeControlStatus == .paused { player.play() } else { player.pause() }
        }
        .onDisappear { release() }
    }

    /// Lets go of the player once the page is no longer the one shown (SPEC §10: only the current video holds a
    /// player). Paging through twenty videos used to keep twenty players with their buffers and streams alive.
    func release() {
        guard let video else { return }
        resumeAt = VideoRetention.resumePosition(
            current: video.player.currentTime().seconds, duration: video.player.currentItem?.duration.seconds)
        video.release()
        self.video = nil
        phase = .loading
    }

    /// Plays a freshly loaded video, from where it was left when the page was shown before.
    func start(_ loaded: PlayableVideo) {
        video = loaded
        if let resumeAt {
            self.resumeAt = nil
            loaded.player.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600))
        }
        loaded.player.play()
    }

    /// Loading and converting are progress, not problems: no warning sign. A failure says what happened and, where
    /// it can help, offers to try again.
    @ViewBuilder var status: some View {
        switch phase {
        case .loading:
            // The poster is shown already; a spinner only if the video takes long to start.
            DelayedSpinner(tint: .white, large: true)
                .accessibilityLabel(Text("Loading video…", bundle: .module))
        case .preparing:
            VStack(spacing: 10) {
                ProgressView().controlSize(.large)
                Text("Preparing video…", bundle: .module).font(.headline)
                Text("The server is converting it so it can be played here. This can take a few minutes.", bundle: .module)
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(20)
            .frame(maxWidth: 340)
            // A solid card, not a material: its text keeps its contrast over any video frame (accessibility audit).
            .background(.background.secondary, in: .rect(cornerRadius: 14))
            .accessibilityElement(children: .combine)
        case .failed(let failure):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.title).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(failure.message).font(.headline).multilineTextAlignment(.center)
                if let detail = failure.detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                if failure.canRetry {
                    Button(String(localized: "Try again", bundle: .module)) { attempt += 1 }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .padding(.top, 4)
                        .accessibilityHidden(true)
                }
            }
            .padding(20)
            .frame(maxWidth: 340)
            .background(.background.secondary, in: .rect(cornerRadius: 14))
            // One element: the message and its reason are read together, and "Try again" is its action (the lines of
            // text alone were too small to be targets, above all while the info card shrinks the page).
            .accessibilityElement(children: .combine)
            .accessibilityActions {
                if failure.canRetry {
                    Button(String(localized: "Try again", bundle: .module)) { attempt += 1 }
                }
            }
        }
    }

    func load() async {
        switch VideoRetention.action(isCurrent: isCurrent, hasPlayer: video != nil) {
        case .release:
            release()
            return
        case .keep:
            return
        case .load:
            break
        }
        guard let services = session.services else { return }
        phase = .loading
        if MimeTypes.unplayableVideos.contains(item.mimeType) {
            guard session.features.has(.videoRenditions) else {
                phase = .failed(.unsupportedFormat)
                return
            }
            await loadRendition(services)
            return
        }
        do {
            let loaded: PlayableVideo = try await PlayableVideo.load(
                fileId: item.fileId, etag: item.etag, name: item.name, mimeType: item.mimeType,
                originalURL: services.originalURL(for: item), services: services, offline: session.offline)
            guard !Task.isCancelled else {
                loaded.release()
                return
            }
            start(loaded)
        } catch {
            if !Task.isCancelled { phase = .failed(.loading(error)) }
        }
    }

    /// The server converts on first request and answers 404 until it is done.
    func loadRendition(_ services: AccountServices) async {
        for _ in 0..<Self.conversionAttempts {
            do {
                let file: URL = try await services.api.videoRendition(fileId: item.fileId, etag: item.etag)
                guard !Task.isCancelled else { return }
                start(PlayableVideo(file: file))
                return
            } catch {
                if Task.isCancelled { return }
                guard VideoFailure.isStillConverting(error) else {
                    phase = .failed(.loading(error))
                    return
                }
            }
            phase = .preparing
            try? await Task.sleep(for: Self.conversionInterval)
            if Task.isCancelled { return }
        }
        phase = .failed(.conversionTakesLong)
    }

    /// A stream can still fail after the player is shown (connection lost, a file the system cannot decode); the
    /// player would only show a crossed-out play button.
    func watchPlayback() async {
        guard let playerItem = player?.currentItem else { return }
        for await status in playerItem.publisher(for: \.status).values where status == .failed {
            guard !Task.isCancelled else { return }
            let error: (any Error)? = playerItem.error
            video?.release()
            video = nil
            phase = .failed(.loading(error))
            return
        }
    }
}

/// Which video pages hold a player: only the one shown. A page that is paged away lets go of its player at once
/// (not just pauses it), and loads it again when it is shown again.
enum VideoRetention {
    enum Action: Equatable {
        /// Shown, without a player yet.
        case load
        /// Shown, and the player is there.
        case keep
        /// Not shown (any more): stop and let go of the player, if there is one.
        case release
    }

    static func action(isCurrent: Bool, hasPlayer: Bool) -> Action {
        guard isCurrent else { return .release }
        return hasPlayer ? .keep : .load
    }

    /// Where to go on when the page is shown again: nil at the very start, near the end (it starts over) or when the
    /// position is not known.
    static func resumePosition(current: Double, duration: Double?) -> Double? {
        guard current.isFinite, current >= 1 else { return nil }
        if let duration, duration.isFinite, duration > 0, current >= duration - 1 { return nil }
        return current
    }
}
