// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import AVKit
import PhotosCore
import PhotosDomain
import PhotosMedia
import PhotosModel
import SwiftUI

struct TVViewerRequest: Identifiable {
    let id = UUID()
    var items: [MediaItem]
    var index: Int
}

/// Photos and videos full screen, made for the Siri Remote (SPEC §15.3): swipe or press left and right for the previous and
/// next, click for the details, Play/Pause plays a video or starts a slideshow from this photo, Menu goes back.
struct TVViewer: View {
    let request: TVViewerRequest
    @State private var index: Int
    @State private var showsInfo = false
    @State private var playing: MediaItem?
    @State private var slideshow: TVSlideshowRequest?
    @Environment(SessionModel.self) private var session
    @Environment(TVLibrary.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(request: TVViewerRequest) {
        self.request = request
        _index = State(initialValue: min(max(request.index, 0), max(request.items.count - 1, 0)))
    }

    var items: [MediaItem] { request.items }
    var item: MediaItem? { items.indices.contains(index) ? items[index] : nil }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let item {
                TVPreview(item: item, bucket: 4096, maxPixelSize: 3840, contentMode: .fit)
                    .ignoresSafeArea()
                    .id(item.fileId)
                    .transition(reduceMotion ? .opacity : .asymmetric(insertion: .opacity, removal: .opacity))
                if item.kind == .video {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 120))
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(radius: 12)
                        .accessibilityHidden(true)
                }
                if showsInfo { info(item) }
            }
        }
        .animation(.easeInOut(duration: 0.35), value: index)
        .animation(.easeInOut(duration: 0.25), value: showsInfo)
        .focusable()
        .focusEffectDisabled()
        .onMoveCommand { direction in
            switch direction {
            case .left: move(by: -1)
            case .right: move(by: 1)
            case .up: showsInfo = false
            case .down: showsInfo = true
            @unknown default: break
            }
        }
        .onPlayPauseCommand { playOrStartSlideshow() }
        .onTapGesture {
            if item?.kind == .video { playing = item } else { showsInfo.toggle() }
        }
        .task(id: index) { prefetchNeighbours() }
        .fullScreenCover(item: $playing) { item in
            TVVideoScreen(item: item).environment(session)
        }
        .fullScreenCover(item: $slideshow) { request in
            TVSlideshowView(request: request).environment(session).environment(library)
        }
        .accessibilityElement()
        .accessibilityLabel(item.map(TVText.label(for:)) ?? Text(verbatim: ""))
        .accessibilityAction(named: Text("Next", comment: "TV viewer: VoiceOver action")) { move(by: 1) }
        .accessibilityAction(named: Text("Previous", comment: "TV viewer: VoiceOver action")) { move(by: -1) }
    }

    func info(_ item: MediaItem) -> some View {
        VStack {
            Spacer()
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.timestamp.formatted(date: .complete, time: .shortened))
                        .font(.title3.bold())
                    if let place = item.place {
                        Label(place, systemImage: "mappin.and.ellipse").font(.headline)
                    }
                    if let caption = item.caption, !caption.isEmpty {
                        Text(caption).font(.body)
                    }
                    Text(item.name).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(index + 1) of \(items.count)", comment: "TV viewer: position of the photo, e.g. 3 of 40.")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(48)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 32))
            .padding(60)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    func move(by offset: Int) {
        let next = index + offset
        guard items.indices.contains(next) else { return }
        index = next
    }

    func playOrStartSlideshow() {
        guard let item else { return }
        if item.kind == .video {
            playing = item
        } else {
            let photos = items.filter { $0.kind == .image }
            let start = photos.firstIndex { $0.fileId == item.fileId } ?? 0
            slideshow = .items(title: nil, items: Array(photos[start...] + photos[..<start]))
        }
    }

    /// The neighbours load while this one is looked at, so a swipe shows them at once.
    func prefetchNeighbours() {
        guard let services = session.services else { return }
        let neighbours = [index - 1, index + 1, index + 2].filter(items.indices.contains).map { items[$0] }.filter { $0.kind == .image }
        let requests = neighbours.map { item in
            ImagePipeline.Request(
                fileId: item.fileId, etag: item.etag, bucket: 4096, hasPreview: item.hasPreview, mimeType: item.mimeType,
                originalURL: services.originalURL(for: item), maxPixelSize: 3840)
        }
        Task { await services.images.prefetch(requests) }
    }
}

/// A video in the system's player (transport bar, scrubbing on the remote's touch surface, info panel), streamed through
/// the app's own HTTP client like on the other platforms (SPEC §5.5.3).
struct TVVideoScreen: View {
    let item: MediaItem
    @Environment(SessionModel.self) private var session
    @State private var player: AVPlayer?
    @State private var loader: StreamingAssetLoader?
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                TVPlayerController(player: player).ignoresSafeArea()
            } else if failed {
                ContentUnavailableView {
                    Label {
                        Text("Can't Play This Video", comment: "TV: the video could not be loaded.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                }
            } else {
                ProgressView()
            }
        }
        .task { await load() }
        .onDisappear { player?.pause() }
    }

    func load() async {
        guard let services = session.services else { return }
        do {
            let asset: AVURLAsset
            if let cached = services.images.originals.cached(fileId: item.fileId, etag: item.etag, url: services.originalURL(for: item)) {
                asset = AVURLAsset(url: cached)
            } else {
                let url = try await services.api.directDownloadURL(fileId: item.fileId)
                let source = MediaByteSource(url: url, headers: ["User-Agent": services.connection.userAgent], http: services.http)
                let loader = StreamingAssetLoader(source: source, mimeType: item.mimeType)
                self.loader = loader
                asset = loader.makeAsset(fileName: item.name)
            }
            let playerItem = AVPlayerItem(asset: asset)
            playerItem.externalMetadata = metadata()
            let player = AVPlayer(playerItem: playerItem)
            self.player = player
            player.play()
        } catch {
            failed = true
        }
    }

    /// The title and date in the player's info panel.
    func metadata() -> [AVMetadataItem] {
        let title = AVMutableMetadataItem()
        title.identifier = .commonIdentifierTitle
        title.value = (item.place ?? item.timestamp.formatted(date: .long, time: .omitted)) as NSString
        title.extendedLanguageTag = "und"
        let date = AVMutableMetadataItem()
        date.identifier = .commonIdentifierCreationDate
        date.value = item.timestamp.formatted(date: .long, time: .shortened) as NSString
        date.extendedLanguageTag = "und"
        return [title, date]
    }
}

struct TVPlayerController: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }
}
