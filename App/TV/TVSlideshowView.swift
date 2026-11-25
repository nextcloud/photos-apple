// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosMedia
import PhotosModel
import SwiftUI
import UIKit

/// What a slideshow plays.
enum TVSlideshowRequest: Identifiable {
    case memory(Memory)
    case album(Album)
    /// The family slideshow: the album shuffled, for hours, continuing where it stopped (SPEC §15.3).
    case family(Album)
    case items(title: String?, items: [MediaItem])

    var id: String {
        switch self {
        case .memory(let memory): "memory-\(memory.id)"
        case .album(let album): "album-\(album.id)"
        case .family(let album): "family-\(album.id)"
        case .items(_, let items): "items-\(items.first?.fileId ?? 0)-\(items.count)"
        }
    }

    var isFamily: Bool {
        if case .family = self { return true }
        return false
    }
}

/// A full-screen slideshow (SPEC §15.3): cross-fades with a slow drift (none with Reduce Motion), the memory's or album's
/// title over the first photo, Play/Pause pauses, left and right skip, a click shows where and when, Menu ends it. The
/// screen saver stays away while it plays. The family slideshow can show the time like a picture frame.
struct TVSlideshowView: View {
    let request: TVSlideshowRequest
    @Environment(SessionModel.self) private var session
    @Environment(TVLibrary.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(TVSettings.clockKey) private var showsClock = true
    @State private var player = TVSlideshowPlayer()
    @State private var showsInfo = false
    @State private var loaded = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if player.slide != nil {
                // The new photo fades in over the previous one, which stays opaque below it: a cross-dissolve, not a dip
                // to black.
                ForEach(player.visibleSlides, id: \.key) { slide in
                    TVSlideImage(
                        slide: slide, duration: Double(TVSettings.interval) + 2, fade: Slideshow.crossfade(reduceMotion: reduceMotion),
                        reduceMotion: reduceMotion
                    )
                    .zIndex(Double(slide.key))
                    .ignoresSafeArea()
                }
            } else if loaded {
                ContentUnavailableView {
                    Label {
                        Text("No Photos", comment: "TV slideshow: the memory or album has no photos.")
                    } icon: {
                        Image(systemName: "photo")
                    }
                }
            } else {
                ProgressView()
            }
            // Above every slide (they are stacked by their number).
            overlays.zIndex(1e12)
        }
        .animation(.easeInOut(duration: 0.3), value: player.isPaused)
        .animation(.easeInOut(duration: 0.3), value: showsInfo)
        .focusable()
        .focusEffectDisabled()
        .onPlayPauseCommand { player.isPaused.toggle() }
        .onMoveCommand { direction in
            switch direction {
            case .left: player.skip(by: -1)
            case .right: player.skip(by: 1)
            default: break
            }
        }
        .onTapGesture { showsInfo.toggle() }
        .task { await run() }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            if request.isFamily { UserDefaults.standard.set(player.position, forKey: TVSettings.familyPositionKey) }
        }
        .accessibilityElement()
        .accessibilityLabel(player.slide.map { TVText.label(for: $0.item) } ?? Text(verbatim: ""))
    }

    @ViewBuilder var overlays: some View {
        if let slide = player.slide {
            if slide.position == player.startPosition, let title = title, !request.isFamily {
                titleCard(title)
            }
            if showsInfo || (request.isFamily && showsClock) {
                VStack {
                    Spacer()
                    HStack(alignment: .bottom) {
                        if showsInfo || request.isFamily { caption(slide.item) }
                        Spacer()
                        if request.isFamily && showsClock { clock }
                    }
                    .padding(60)
                }
                .transition(.opacity)
            }
            if player.isPaused {
                Image(systemName: "pause.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(.white)
                    .padding(48)
                    .background(.ultraThinMaterial, in: .circle)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel(Text("Paused", comment: "TV slideshow: VoiceOver label of the pause symbol."))
            }
        }
    }

    var title: (String, String?)? {
        switch request {
        case .memory(let memory): (memory.title, Memories.dateLine(for: memory))
        case .album(let album): (album.title, album.location.isEmpty ? nil : album.location)
        case .items(let title?, _): (title, nil)
        default: nil
        }
    }

    func titleCard(_ title: (String, String?)) -> some View {
        VStack(spacing: 12) {
            Text(title.0)
                .font(.system(size: 76, weight: .bold))
                .multilineTextAlignment(.center)
            if let subtitle = title.1 {
                Text(subtitle).font(.title2).foregroundStyle(.white.opacity(0.85))
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.6), radius: 18)
        .padding(80)
        .transition(.opacity)
    }

    func caption(_ item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let place = item.place { Text(place).font(.title3.bold()) }
            Text(item.timestamp.formatted(date: .long, time: .omitted)).font(.headline)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.7), radius: 10)
    }

    var clock: some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: .trailing, spacing: 4) {
                Text(context.date.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 72, weight: .semibold).monospacedDigit())
                Text(context.date.formatted(.dateTime.weekday(.wide).day().month(.wide))).font(.title3)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.7), radius: 12)
        }
    }

    func run() async {
        let items = await photos()
        loaded = true
        guard !items.isEmpty, let services = session.services else { return }
        switch request {
        case .family:
            let defaults = UserDefaults.standard
            var seed = UInt64(bitPattern: Int64(defaults.integer(forKey: TVSettings.familySeedKey)))
            if seed == 0 {
                seed = UInt64.random(in: 1...UInt64(Int64.max))
                defaults.set(Int(Int64(bitPattern: seed)), forKey: TVSettings.familySeedKey)
            }
            let byId = Dictionary(items.map { ($0.fileId, $0) }, uniquingKeysWith: { first, _ in first })
            let ids = Array(byId.keys)
            player.startPosition = defaults.integer(forKey: TVSettings.familyPositionKey)
            await player.run(services: services, interval: TVSettings.interval, startingAt: player.startPosition) { position in
                FamilySlideshow.photo(ids, seed: seed, position: position).flatMap { byId[$0] }
            }
        default:
            await player.run(services: services, interval: TVSettings.interval, startingAt: 0) { position in
                items[((position % items.count) + items.count) % items.count]
            }
        }
    }

    /// The photos it shows: videos are left out (they would need their own time).
    func photos() async -> [MediaItem] {
        let all: [MediaItem]
        switch request {
        case .memory(let memory): all = await library.media(memory.items)
        case .album(let album), .family(let album): all = await library.media(of: album)
        case .items(_, let items): all = items
        }
        return all.filter { $0.kind == .image }
    }
}

/// One photo of a slideshow, drifting slowly towards one of its corners.
struct TVSlideImage: View {
    let slide: TVSlideshowPlayer.Slide
    let duration: Double
    /// How long it takes to appear over the previous photo.
    let fade: Double
    let reduceMotion: Bool
    @State private var drifting = false
    @State private var shown = false

    var anchor: UnitPoint {
        [.topLeading, .bottomTrailing, .topTrailing, .bottomLeading, .center][abs(slide.position) % 5]
    }

    var body: some View {
        GeometryReader { proxy in
            Image(decorative: slide.image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: fills ? .fill : .fit)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .scaleEffect(drifting ? Slideshow.drift(reduceMotion: reduceMotion) : 1, anchor: anchor)
                .clipped()
                .background {
                    // Opaque, so the photo before is gone once this one has faded in. Portrait photos: the photo blurred
                    // behind it instead of black bars.
                    ZStack {
                        Color.black
                        if !fills {
                            Image(decorative: slide.image, scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .blur(radius: 60)
                                .opacity(0.5)
                                .clipped()
                        }
                    }
                }
        }
        .opacity(shown ? 1 : 0)
        .onAppear {
            withAnimation(.easeInOut(duration: fade)) { shown = true }
            withAnimation(.linear(duration: duration)) { drifting = true }
        }
    }

    /// Landscape photos fill the screen; others are shown whole.
    var fills: Bool {
        let ratio = Double(slide.image.width) / Double(max(slide.image.height, 1))
        return ratio > 1.3 && ratio < 2.1
    }
}

/// Runs a slideshow: loads each photo before it is shown (the next one while the current one is on screen), waits the
/// interval, and follows pause and skip.
@MainActor
@Observable
final class TVSlideshowPlayer {
    struct Slide {
        var position: Int
        var item: MediaItem
        var image: CGImage
        /// Changes for every slide shown, also when the same photo comes again.
        var key: Int
    }

    private(set) var slide: Slide?
    /// The slide before, kept below the current one while that fades in.
    private(set) var previous: Slide?
    var isPaused = false

    var visibleSlides: [Slide] { [previous, slide].compactMap { $0 } }
    private(set) var position = 0
    var startPosition = 0
    @ObservationIgnored private var skipRequest: Int?
    @ObservationIgnored private var shown = 0

    func skip(by offset: Int) {
        skipRequest = (skipRequest ?? 0) + offset
    }

    func run(services: AccountServices, interval: Int, startingAt start: Int, item: @escaping (Int) -> MediaItem?) async {
        position = start
        var failures = 0
        var next: Task<CGImage?, Never>?
        while !Task.isCancelled {
            guard let current = item(position) else { return }
            let image: CGImage?
            if let next {
                image = await next.value
            } else {
                image = await Self.load(current, services: services)
            }
            next = nil
            guard let image else {
                // A photo that cannot be loaded is skipped; a slideshow of nothing but failures stops.
                failures += 1
                if failures > 20 { return }
                position += 1
                continue
            }
            failures = 0
            shown += 1
            previous = slide
            slide = Slide(position: position, item: current, image: image, key: shown)
            if let upcoming = item(position + 1) {
                next = Task { await Self.load(upcoming, services: services) }
            }
            let offset = await wait(seconds: interval)
            if offset != 1 { next?.cancel(); next = nil }
            position = max(position + offset, 0)
        }
        next?.cancel()
    }

    /// Waits the interval (not counting paused time); returns how far to move: 1, or what the user skipped.
    private func wait(seconds: Int) async -> Int {
        var elapsed = 0.0
        while !Task.isCancelled {
            if let skip = skipRequest {
                skipRequest = nil
                if skip != 0 { return skip }
            }
            if elapsed >= Double(seconds) { return 1 }
            try? await Task.sleep(for: .milliseconds(100))
            if !isPaused { elapsed += 0.1 }
        }
        return 1
    }

    static func load(_ item: MediaItem, services: AccountServices) async -> CGImage? {
        let request = ImagePipeline.Request(
            fileId: item.fileId, etag: item.etag, bucket: 4096, hasPreview: item.hasPreview, mimeType: item.mimeType,
            originalURL: services.originalURL(for: item), maxPixelSize: 3840)
        return await services.images.preview(request)
    }
}
