// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import AVFoundation
import PhotosCore
import PhotosDomain
import PhotosMedia
import PhotosModel
import SwiftUI
import UIKit

/// A film shared over SharePlay on the Apple TV (SPEC §16.6): someone in a FaceTime call shares a memory film or a
/// slideshow from an iPhone, iPad, Mac or Vision Pro, and the TV plays it in step with them, loading the pictures from the
/// same Nextcloud with the account signed in here. The TV shows the film's pictures, camera moves, title, style and music;
/// clips show their still, and map flights a quiet pause.
@MainActor @Observable final class TVSharedFilmModel: WatchTogetherPlayer {
    let film: SharedFilm
    private(set) var stills: [Int: CGImage] = [:]
    private(set) var focus: [Int: FilmCrop] = [:]
    private(set) var unavailable: Set<Int> = []
    private(set) var checked = 0
    private(set) var grain: CGImage?
    private(set) var anchorTime = 0.0
    private(set) var anchorDate: Date?
    private var loading: Set<Int> = []
    private var motions: [Int: KenBurns.Motion] = [:]
    private var services: AccountServices?
    private var audio: AVAudioPlayer?
    var still = false

    init(film: SharedFilm) {
        self.film = film
    }

    var plan: FilmPlan { film.plan }
    var isPlaying: Bool { anchorDate != nil }
    var duration: Double { plan.duration }

    func time(at date: Date) -> Double {
        guard let anchorDate else { return anchorTime }
        return min(duration, anchorTime + max(0, date.timeIntervalSince(anchorDate)))
    }

    var now: Double { time(at: Date()) }

    func load(services: AccountServices) async {
        self.services = services
        grain = FilmLookFilter.grainTile(plan.style.look)
        if film.playsScore, let file = await ScoreSynth.file(for: plan.style.score) {
            audio = try? AVAudioPlayer(contentsOf: file)
            audio?.numberOfLoops = -1
            audio?.prepareToPlay()
        }
        for shot in plan.upcomingShots(from: 0, within: 6).prefix(3) { await loadStill(shot) }
        WatchTogether.shared.attach(self, film: film, position: 0, playing: false)
        Task { await checkAvailability() }
    }

    /// Which pictures this account can load: the others are told, and they show as dark cards.
    private func checkAvailability() async {
        guard let services else { return }
        for (index, picture) in film.pictures.enumerated() {
            let request = ImagePipeline.Request(
                fileId: picture.fileId, etag: picture.etag, bucket: 256, hasPreview: true, mimeType: picture.mimeType, originalURL: nil)
            if await services.images.preview(request) == nil { unavailable.insert(index) }
            checked += 1
        }
        WatchTogether.shared.report(
            SharedFilmReport(
                visible: film.pictures.count - unavailable.count, total: film.pictures.count,
                problem: unavailable.isEmpty ? nil : .notShared))
    }

    private func loadStill(_ shot: Int) async {
        guard stills[shot] == nil, !loading.contains(shot), !unavailable.contains(shot), let picture = film.pictures[safe: shot],
            let services
        else { return }
        loading.insert(shot)
        defer { loading.remove(shot) }
        let request = ImagePipeline.Request(
            fileId: picture.fileId, etag: picture.etag, bucket: 4096, hasPreview: true, mimeType: picture.mimeType, originalURL: nil,
            maxPixelSize: 2560)
        guard let image = await services.images.preview(request) else {
            unavailable.insert(shot)
            return
        }
        stills[shot] = FilmLookFilter.graded(image, look: plan.style.look) ?? image
        if let found = await Task.detached(priority: .utility, operation: { await FrameFocus.focus(of: image) }).value {
            focus[shot] = found
        }
    }

    /// Loads what comes next, lets go of what is over, fixes the camera moves, stops at the end.
    func tick() {
        let time = now
        if isPlaying && time >= duration {
            anchorTime = duration
            anchorDate = nil
            audio?.pause()
        }
        for shot in plan.upcomingShots(from: time, within: 8) where stills[shot] == nil {
            Task { await loadStill(shot) }
        }
        let keep = Set(plan.upcomingShots(from: max(0, time - 4), within: 14))
        for shot in stills.keys where !keep.contains(shot) { stills[shot] = nil }
    }

    func motion(_ segment: Int, shot: Int, aspect: Double) -> KenBurns.Motion {
        if let fixed = motions[segment] { return fixed }
        let viewport = 16.0 / 9.0
        let made =
            plan.shots[shot].isVideo
            ? {
                let base = KenBurns.base(imageAspect: aspect, viewportAspect: viewport)
                return KenBurns.Motion(from: base.crop, to: base.crop, fits: base.fits)
            }()
            : KenBurns.motion(
                imageAspect: aspect, viewportAspect: viewport, focus: focus[shot], seed: plan.segments[segment].seed, still: still,
                closeness: plan.style.zoom)
        // Fixed once the picture is there (its focus found or not), so the move does not jump.
        if stills[shot] != nil { motions[segment] = made }
        return made
    }

    // MARK: The group's commands

    func groupPlay(at time: Double, delay: Double) {
        anchorTime = min(max(0, time), duration)
        anchorDate = Date().addingTimeInterval(delay)
        if let audio, audio.duration > 0 {
            audio.currentTime = max(0, time - delay).truncatingRemainder(dividingBy: audio.duration)
            audio.play()
        }
    }

    func groupPause(at time: Double) {
        anchorTime = min(max(0, time), duration)
        anchorDate = nil
        audio?.pause()
    }

    func groupSeek(to time: Double) {
        anchorTime = min(max(0, time), duration)
        if anchorDate != nil { anchorDate = Date() }
        if let audio, audio.duration > 0 { audio.currentTime = anchorTime.truncatingRemainder(dividingBy: audio.duration) }
    }

    func stop() {
        audio?.stop()
        WatchTogether.shared.detach(self)
        WatchTogether.shared.leave()
    }
}

/// The shared film full screen: Play/Pause and left/right go to everyone, Menu leaves SharePlay on this TV.
struct TVSharedFilmView: View {
    let film: SharedFilm
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model: TVSharedFilmModel
    @State private var watch = WatchTogether.shared
    @State private var showsInfo = true

    init(film: SharedFilm) {
        self.film = film
        _model = State(initialValue: TVSharedFilmModel(film: film))
    }

    var onThisServer: Bool { film.isOn(session.account.serverURL) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if onThisServer {
                TimelineView(.animation(paused: !model.isPlaying)) { context in
                    frame(time: model.time(at: context.date))
                }
                .ignoresSafeArea()
            } else {
                ContentUnavailableView {
                    Label(film.title, systemImage: "shareplay")
                } description: {
                    Text(
                        "This film is on \(film.serverName). Sign in to that Nextcloud on this Apple TV with an account the photos are shared with, then join again.",
                        comment: "TV SharePlay: the film is on a Nextcloud this TV is not signed in to. The argument is the server.")
                }
            }
            if showsInfo || !model.isPlaying { banner.transition(.opacity) }
        }
        .animation(.easeInOut(duration: 0.3), value: showsInfo)
        .focusable()
        .focusEffectDisabled()
        .onPlayPauseCommand {
            if model.isPlaying { watch.pause() } else { watch.play() }
        }
        .onMoveCommand { direction in
            switch direction {
            case .left: watch.seek(to: model.plan.previousStart(before: model.now))
            case .right: watch.seek(to: model.plan.nextStart(after: model.now) ?? model.duration)
            default: showsInfo.toggle()
            }
        }
        .onTapGesture { showsInfo.toggle() }
        .onExitCommand { dismiss() }
        .task {
            model.still = reduceMotion
            guard onThisServer, let services = session.services else {
                WatchTogether.shared.report(SharedFilmReport(visible: 0, total: film.pictures.count, problem: .noAccount))
                return
            }
            await model.load(services: services)
        }
        .task {
            while !Task.isCancelled {
                model.tick()
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        .task(id: model.isPlaying) {
            // The banner fades a few seconds after the film starts.
            guard model.isPlaying else { return }
            try? await Task.sleep(for: .seconds(4))
            showsInfo = false
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            model.stop()
        }
    }

    var banner: some View {
        VStack {
            HStack(spacing: 16) {
                Image(systemName: "shareplay")
                VStack(alignment: .leading, spacing: 4) {
                    Text(film.title).font(.headline)
                    if model.checked >= film.pictures.count && !model.unavailable.isEmpty {
                        Text(
                            "You can see \(film.pictures.count - model.unavailable.count) of \(film.pictures.count) photos. The others aren't shared with this account on Nextcloud.",
                            comment: "TV SharePlay: how many of the film's photos this TV's account can see. Arguments are numbers."
                        )
                        .font(.callout)
                    } else {
                        Text(
                            "SharePlay · Play/Pause and the arrows control the film for everyone.",
                            comment: "TV SharePlay banner: the remote controls the shared film for everyone."
                        )
                        .font(.callout)
                    }
                }
            }
            .padding(24)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 24))
            .padding(60)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func frame(time: Double) -> some View {
        GeometryReader { proxy in
            let size = proxy.size
            let look = model.plan.style.look
            let jitter = look.jitterOffset(at: time)
            ZStack(alignment: .topLeading) {
                Color.black
                ZStack(alignment: .topLeading) {
                    ForEach(model.plan.layers(at: time), id: \.segment) { (layer: FilmLayer) in
                        layerView(layer, size: size).opacity(layer.opacity)
                    }
                }
                .frame(width: size.width, height: size.height)
                .scaleEffect(look.overscan)
                .offset(x: jitter.x * size.height, y: jitter.y * size.height)
                TVFilmLook(look: look, time: time, size: size, grain: model.grain)
                Color.black.opacity(1 - model.plan.brightness(at: time))
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
    }

    @ViewBuilder func layerView(_ layer: FilmLayer, size: CGSize) -> some View {
        let segment = model.plan.segments[layer.segment]
        switch segment.content {
        case .title:
            ZStack {
                if let cover = model.plan.cover { picture(cover, layer: layer, size: size) }
                VStack(spacing: 14) {
                    Text(film.title).font(.system(size: size.height * 0.075, weight: .bold, design: .serif))
                    if let subtitle = film.subtitle {
                        Text(subtitle.uppercased()).font(.system(size: size.height * 0.026, weight: .semibold)).tracking(4)
                    }
                }
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.65), radius: 20)
                .padding(80)
            }
        case .shot(let shot):
            if model.unavailable.contains(shot) {
                ZStack {
                    LinearGradient(colors: [Color(white: 0.12), .black], startPoint: .top, endPoint: .bottom)
                    VStack(spacing: 16) {
                        Image(systemName: "lock.fill").font(.system(size: 60))
                        Text("Not shared with you", comment: "TV SharePlay: in place of a photo not shared with this account.")
                            .font(.title3.bold())
                    }
                    .foregroundStyle(.white.opacity(0.7))
                }
            } else {
                picture(shot, layer: layer, size: size)
            }
        case .flight, .card:
            Color.black
        }
    }

    @ViewBuilder func picture(_ shot: Int, layer: FilmLayer, size: CGSize) -> some View {
        if let image = model.stills[shot] {
            let aspect = Double(image.width) / Double(max(image.height, 1))
            let motion = model.motion(layer.segment, shot: shot, aspect: aspect)
            let crop = motion.crop(at: layer.progress)
            let width = size.width / crop.width
            let height = size.height / crop.height
            ZStack(alignment: .topLeading) {
                if motion.fits {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: size.width, height: size.height).blur(radius: 50).overlay(Color.black.opacity(0.45)).clipped()
                }
                Image(decorative: image, scale: 1).resizable()
                    .frame(width: width, height: height)
                    .offset(x: -crop.x * width, y: -crop.y * height)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped()
        }
    }
}

/// The style's vignette, grain and flicker over the TV's film (the same numbers as on the other devices).
struct TVFilmLook: View {
    let look: FilmLook
    let time: Double
    let size: CGSize
    let grain: CGImage?

    var body: some View {
        ZStack {
            if look.vignette > 0 {
                let radii = look.vignetteRadii(width: size.width, height: size.height)
                RadialGradient(
                    colors: [.clear, .black.opacity(look.vignetteOpacity)], center: .center, startRadius: radii.inner,
                    endRadius: radii.outer)
            }
            if let grain {
                let offset = look.grainOffset(at: time)
                // As coarse as in the video: a grain is 1/540 of the frame's height (2 pixels at 1080p).
                let point = FilmLook.grainSize(frameHeight: size.height)
                let tile = Double(grain.width) * point
                Image(decorative: grain, scale: 1 / point)
                    .interpolation(.none)
                    .resizable(resizingMode: .tile)
                    .frame(width: size.width + tile, height: size.height + tile)
                    .offset(x: -offset.x * tile, y: -offset.y * tile)
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                    .clipped()
                    .blendMode(.softLight)
            }
            let light = look.light(at: time)
            if light < 1 { Color.black.opacity(1 - light) }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }
}

extension View {
    /// Joins SharePlay sessions on the TV and plays the shared film full screen.
    func tvWatchTogether(session: SessionModel) -> some View {
        modifier(TVWatchTogether(session: session))
    }
}

private struct TVWatchTogether: ViewModifier {
    let session: SessionModel
    @State private var watch = WatchTogether.shared
    @State private var shown: SharedFilm?

    func body(content: Content) -> some View {
        content
            .task { watch.listen() }
            .onChange(of: watch.film?.id, initial: true) { _, _ in
                if let film = watch.film, shown?.id != film.id { shown = film }
            }
            .fullScreenCover(item: $shown) { (film: SharedFilm) in
                TVSharedFilmView(film: film).environment(session).id(film.id)
            }
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
