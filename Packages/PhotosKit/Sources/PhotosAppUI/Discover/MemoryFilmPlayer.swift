// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import AVFoundation
import PhotosCore
import PhotosDomain
import PhotosMedia
import PhotosModel
import PhotosStore
import SwiftUI

/// What a memory film shows: a memory's title, dates and photos.
struct SlideshowStart: Identifiable, Hashable {
    var id: String
    var title: String
    var subtitle: String?
    /// The trip's places, under the dates on the title card.
    var place: String?
    var ids: [FileID]
    var cover: FileID?
    /// Trips fly over the map between their stops.
    var isTrip = false
    /// Plays the music chosen for memories (`memorySlideshowMusic`).
    var playsMemoryMusic = false

    init(memory: Memory) {
        id = memory.id
        title = memory.title
        subtitle = Memories.dateLine(for: memory)
        ids = memory.items
        cover = memory.cover
        isTrip = memory.kind == .trip
        playsMemoryMusic = true
    }
}

extension View {
    /// Plays a memory film full screen on iPhone and iPad; pushed in the window's stack on the Mac and Vision Pro, like the
    /// viewer ("Back" or Escape ends it).
    func memorySlideshow(_ start: Binding<SlideshowStart?>) -> some View {
        modifier(FilmPresenter(start: start))
    }
}

private struct FilmPresenter: ViewModifier {
    @Binding var start: SlideshowStart?
    @Environment(SessionModel.self) private var session

    func body(content: Content) -> some View {
        #if os(iOS)
            content.fullScreenCover(item: $start) { (start: SlideshowStart) in
                MemoryFilmPlayer(start: start).environment(session)
            }
        #else
            content.navigationDestination(item: $start) { (start: SlideshowStart) in
                MemoryFilmPlayer(start: start)
            }
        #endif
    }
}

/// A memory played as a film (SPEC §15.1): a title card, slow camera moves that frame the faces, cuts on the music's
/// beat, Live Photos and videos playing inline, and for trips a flight over the map between the stops. Pause, scrub,
/// skip and mute; Export makes a video of it. With Reduce Motion the camera stays still; with VoiceOver the film starts
/// paused.
struct MemoryFilmPlayer: View {
    let start: SlideshowStart
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: MemoryFilmModel
    @State private var controlsShown = true
    /// While the scrubber is dragged: the film is paused and resumes afterwards if it was playing.
    @State private var scrubbing: Double?
    @State private var resumeAfterScrub = false
    @State private var exporting = false
    @State private var lastInteraction = Date()
    @FocusState private var focused: Bool

    init(start: SlideshowStart) {
        self.start = start
        _model = State(initialValue: MemoryFilmModel(start: start))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()
                if model.loaded, let plan = model.plan, !plan.segments.isEmpty {
                    TimelineView(.animation(paused: !model.isPlaying || scrubbing != nil)) { context in
                        FilmFrame(model: model, plan: plan, time: scrubbing ?? model.time(at: context.date), size: proxy.size)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(frameDescription)
                    .accessibilityAddTraits(.isImage)
                } else if model.loaded {
                    ContentUnavailableView(
                        String(localized: "No photos to show", bundle: .module), systemImage: "photo.on.rectangle.angled")
                } else {
                    ProgressView().tint(.white)
                }
                if model.ended { endCard }
            }
            .onAppear { model.setViewport(proxy.size) }
            .onChange(of: proxy.size) { _, size in model.setViewport(size) }
        }
        #if os(iOS)
            // Full screen on iPhone and iPad; in the window on the Mac and Vision Pro, beside the sidebar, not under it.
            .ignoresSafeArea()
        #endif
        .contentShape(.rect)
        .onTapGesture { toggleControls() }
        .overlay(alignment: .top) { if controlsShown { topBar } }
        .overlay(alignment: .bottom) {
            if controlsShown && model.loaded && !model.ended {
                FilmControls(model: model, scrubbing: $scrubbing, resume: $resumeAfterScrub)
            }
        }
        #if os(iOS)
            .statusBarHidden(!controlsShown)
            .persistentSystemOverlays(controlsShown ? .automatic : .hidden)
        #else
            .navigationTitle(start.title)
        #endif
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear {
            focused = true
            model.still = reduceMotion
        }
        .onKeyPress(keys: [.leftArrow, .rightArrow, .space, .escape, "m"]) { press in
            switch press.key {
            case .leftArrow: model.skip(false)
            case .rightArrow: model.skip(true)
            case .space: model.togglePlaying()
            case "m": model.muted.toggle()
            default: dismiss()
            }
            lastInteraction = Date()
            return .handled
        }
        .task {
            await model.load(session: session, autoplay: Slideshow.startsPlaying(voiceOver: voiceOver))
        }
        .task(id: model.loaded) {
            // The model's housekeeping a few times a second; the frames themselves follow the clock.
            while !Task.isCancelled {
                model.tick()
                hideControlsWhenIdle()
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
        .onChange(of: model.isPlaying) { _, playing in DisplaySleep.prevent(playing) }
        .onChange(of: scenePhase) { _, phase in if phase != .active && model.isPlaying { model.pause() } }
        .onDisappear {
            model.stop()
            DisplaySleep.prevent(false)
        }
        .sheet(isPresented: $exporting) {
            MemoryFilmExportSheet(start: start)
        }
    }

    var frameDescription: String {
        guard let plan = model.plan, let segment = plan.segments[safe: model.segment] else { return start.title }
        switch segment.content {
        case .title:
            return AccessibilityText.join([start.title, start.subtitle, start.place])
        case .flight(_, _, let from, let to):
            return FilmFlightCaption.text(from: from, to: to)
        case .card:
            return start.title
        case .shot(let shot):
            guard let item = model.making?.items[safe: shot] else { return start.title }
            return AccessibilityText.media(
                isVideo: item.kind == .video, isLivePhoto: item.isLivePhoto, date: item.timestamp, duration: item.duration,
                place: item.place, isFavorite: item.isFavorite, caption: item.caption)
        }
    }

    func toggleControls() {
        lastInteraction = Date()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { controlsShown.toggle() }
    }

    /// The controls fade away after a few seconds of playing, as in the TV app.
    func hideControlsWhenIdle() {
        guard controlsShown, model.isPlaying, scrubbing == nil, !voiceOver, Date().timeIntervalSince(lastInteraction) > 3.5 else {
            return
        }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.4)) { controlsShown = false }
    }

    var muteTitle: String {
        model.muted
            ? String(localized: "Turn Sound On", bundle: .module, comment: "Memory film: plays the music and the videos' sound again.")
            : String(localized: "Mute", bundle: .module, comment: "Memory film: silences the music and the videos.")
    }

    var topBar: some View {
        HStack(spacing: 12) {
            FilmButton(title: String(localized: "Close", bundle: .module), systemImage: "xmark") { dismiss() }
            Spacer(minLength: 0)
            FilmButton(title: muteTitle, systemImage: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill") {
                lastInteraction = Date()
                model.muted.toggle()
            }
            FilmButton(title: MemoryFilmExportSheet.menuTitle, systemImage: "square.and.arrow.up") {
                model.pause()
                exporting = true
            }
            .disabled(!model.loaded || model.plan?.segments.isEmpty != false)
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .background(alignment: .top) {
            LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 110)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }

    var endCard: some View {
        VStack(spacing: 18) {
            Text(start.title).font(.title.bold()).multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button {
                    model.play()
                } label: {
                    Label(
                        String(localized: "Play Again", bundle: .module, comment: "Memory film: plays the film again from the start."),
                        systemImage: "arrow.counterclockwise")
                }
                Button {
                    exporting = true
                } label: {
                    Label(MemoryFilmExportSheet.menuTitle, systemImage: "square.and.arrow.up")
                }
            }
            .buttonStyle(.bordered)
            .tint(.white)
        }
        .foregroundStyle(.white)
        .padding(28)
        .background(.black.opacity(0.35), in: .rect(cornerRadius: 24))
        .transition(.opacity)
    }
}

/// One frame of the film at `time`: its layers bottom first, each placed through the camera's window.
private struct FilmFrame: View {
    let model: MemoryFilmModel
    let plan: FilmPlan
    let time: Double
    let size: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            ForEach(plan.layers(at: time), id: \.segment) { (layer: FilmLayer) in
                layerView(layer).opacity(layer.opacity)
            }
            Color.black.opacity(1 - plan.brightness(at: time)).allowsHitTesting(false)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    @ViewBuilder func layerView(_ layer: FilmLayer) -> some View {
        let segment = plan.segments[layer.segment]
        switch segment.content {
        case .title:
            ZStack {
                if let shot = plan.cover { shotView(shot, layer: layer, showsClip: false) }
                FilmTitleOverlay(
                    title: model.start.title, subtitle: model.start.subtitle, place: model.start.place,
                    height: FilmTitleOverlay.textScale(size))
            }
        case .shot(let shot):
            shotView(shot, layer: layer, showsClip: true)
        case .flight(_, _, let from, let to):
            ZStack {
                FlightView(map: model.maps[layer.segment], progress: layer.progress, still: model.still, size: size)
                FilmFlightCaption(from: from, to: to, height: FilmTitleOverlay.textScale(size))
            }
        case .card:
            Color.black
        }
    }

    @ViewBuilder func shotView(_ shot: Int, layer: FilmLayer, showsClip: Bool) -> some View {
        let motion = model.motion(for: layer.segment, shot: shot)
        let crop = motion.crop(at: layer.progress)
        ZStack(alignment: .topLeading) {
            if motion.fits, let fill = model.fills[shot] {
                Image(decorative: fill, scale: 1).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height).clipped()
                    .overlay(Color.black.opacity(0.45))
            }
            if let still = model.stills[shot] {
                placed(Image(decorative: still, scale: 1).resizable(), crop: crop)
            }
            if showsClip, let player = model.showsClip(shot, elapsed: layer.elapsed) {
                placed(FilmVideoSurface(player: player), crop: crop)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
    }

    /// Scales and moves the content so the window `crop` fills the frame.
    func placed(_ content: some View, crop: FilmCrop) -> some View {
        let width = size.width / crop.width
        let height = size.height / crop.height
        return content.frame(width: width, height: height).offset(x: -crop.x * width, y: -crop.y * height)
    }
}

/// The map of a flight: the camera moves from the first stop over the whole route to the second, the route drawn behind
/// the plane (`MapFlight`).
private struct FlightView: View {
    let map: FilmMapPicture?
    let progress: Double
    let still: Bool
    let size: CGSize

    var body: some View {
        if let map {
            let from = (x: Double(map.from.x), y: Double(map.from.y))
            let to = (x: Double(map.to.x), y: Double(map.to.y))
            let crop = MapFlight.camera(at: progress, from: from, to: to, still: still)
            ZStack(alignment: .topLeading) {
                Image(decorative: map.image, scale: 1).resizable()
                    .frame(width: size.width / crop.width, height: size.height / crop.height)
                    .offset(x: -crop.x * size.width / crop.width, y: -crop.y * size.height / crop.height)
                Canvas { context, canvas in
                    FlightRoute.draw(
                        in: &context, size: canvas, from: from, to: to, crop: crop, travelled: MapFlight.travelled(at: progress))
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped()
        } else {
            // No map (offline): a calm background under the caption.
            LinearGradient(colors: [Color(red: 0.05, green: 0.12, blue: 0.22), .black], startPoint: .top, endPoint: .bottom)
        }
    }
}

/// The route of a flight drawn over the map: an arc up to the plane, the two stops, the plane.
enum FlightRoute {
    static let stopColor = Color(red: 0, green: 0.51, blue: 0.79)

    static func draw(
        in context: inout GraphicsContext, size: CGSize, from: (x: Double, y: Double), to: (x: Double, y: Double), crop: FilmCrop,
        travelled: Double
    ) {
        func point(_ p: (x: Double, y: Double)) -> CGPoint {
            CGPoint(x: (p.x - crop.x) / crop.width * size.width, y: (p.y - crop.y) / crop.height * size.height)
        }
        func circle(_ centre: CGPoint, _ radius: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
        }
        var route = Path()
        route.move(to: point(from))
        for step in 1...48 {
            route.addLine(to: point(MapFlight.point(at: Double(step) / 48 * travelled, from: from, to: to)))
        }
        let line = max(3, size.height / 160)
        context.drawLayer { (layer: inout GraphicsContext) in
            layer.addFilter(.shadow(color: .black.opacity(0.5), radius: line * 2))
            layer.stroke(route, with: .color(.white), style: StrokeStyle(lineWidth: line, lineCap: .round))
        }
        for stop in [from, to] {
            let centre = point(stop)
            context.fill(circle(centre, line * 2.2), with: .color(.white))
            context.fill(circle(centre, line * 1.3), with: .color(stopColor))
        }
        context.fill(circle(point(MapFlight.point(at: travelled, from: from, to: to)), line * 1.6), with: .color(.white))
    }
}

/// The title card's text: title, dates and place, sized to the frame (the video export renders the same view).
struct FilmTitleOverlay: View {
    let title: String
    let subtitle: String?
    let place: String?
    /// The frame's height: the text is sized to it, so it looks the same on a phone, a Mac and in the video.
    let height: CGFloat

    /// What the text is sized to: the frame's height, but no more than a narrow (portrait) frame's width allows.
    static func textScale(_ size: CGSize) -> CGFloat {
        min(size.height, size.width * 1.25)
    }

    var body: some View {
        VStack(spacing: height * 0.012) {
            Text(title)
                .font(.system(size: height * 0.075, weight: .bold, design: .serif))
                .lineLimit(2)
                .minimumScaleFactor(0.5)
            if let subtitle {
                Text(subtitle.uppercased())
                    .font(.system(size: height * 0.026, weight: .semibold))
                    .tracking(height * 0.004)
            }
            if let place, place != title {
                Text(place).font(.system(size: height * 0.03, weight: .regular, design: .serif)).italic()
            }
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.65), radius: height * 0.02)
        .padding(.horizontal, height * 0.08)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RadialGradient(colors: [.black.opacity(0.45), .clear], center: .center, startRadius: 0, endRadius: height * 0.8)
        )
        .allowsHitTesting(false)
    }
}

/// "Lisbon to Porto" under a map flight.
struct FilmFlightCaption: View {
    let from: String?
    let to: String?
    let height: CGFloat

    static func text(from: String?, to: String?) -> String {
        switch (from, to) {
        case (let from?, let to?) where from != to:
            String(
                localized: "\(from) to \(to)", bundle: .module,
                comment: "Memory film: caption of a map flight from one place to another.")
        case (_, let to?): to
        case (let from?, nil): from
        default:
            String(
                localized: "On the way", bundle: .module, comment: "Memory film: caption of a map flight between places without names.")
        }
    }

    var body: some View {
        VStack {
            Spacer()
            Text(Self.text(from: from, to: to))
                .font(.system(size: height * 0.04, weight: .semibold, design: .serif))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.7), radius: height * 0.015)
                .padding(.bottom, height * 0.12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

/// Play/pause, skip, the scrubber and the time.
private struct FilmControls: View {
    let model: MemoryFilmModel
    @Binding var scrubbing: Double?
    @Binding var resume: Bool

    var body: some View {
        VStack(spacing: 6) {
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                scrubber(time: scrubbing ?? model.time(at: context.date))
            }
            HStack(spacing: 28) {
                FilmButton(title: String(localized: "Previous", bundle: .module), systemImage: "backward.fill") { model.skip(false) }
                FilmButton(
                    title: model.isPlaying ? String(localized: "Pause", bundle: .module) : String(localized: "Play", bundle: .module),
                    systemImage: model.isPlaying ? "pause.fill" : "play.fill", large: true
                ) { model.togglePlaying() }
                FilmButton(title: String(localized: "Next", bundle: .module), systemImage: "forward.fill") { model.skip(true) }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: 560)
        .background(.black.opacity(0.45), in: .rect(cornerRadius: 22))
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
    }

    func scrubber(time: Double) -> some View {
        let value = Binding<Double>(
            get: { scrubbing ?? time },
            set: { (newValue: Double) in scrubbing = newValue })
        return HStack(spacing: 10) {
            Text(Self.clock(time)).monospacedDigit()
            Slider(value: value, in: 0...max(model.duration, 0.1)) { (editing: Bool) in
                scrub(editing: editing)
            }
            .tint(.white)
            .accessibilityLabel(Text("Position", bundle: .module, comment: "Memory film: the scrubber's name for VoiceOver."))
            .accessibilityValue(
                String(
                    localized: "Played \(AccessibilityText.spokenDuration(time)) of \(AccessibilityText.spokenDuration(model.duration))",
                    bundle: .module, comment: "Memory film scrubber value: elapsed time of total time, both spoken durations."))
            Text(Self.clock(model.duration)).monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.white)
    }

    func scrub(editing: Bool) {
        if editing {
            resume = model.isPlaying
            scrubbing = model.now
            model.pause()
        } else {
            if let scrubbing { model.seek(to: scrubbing) }
            scrubbing = nil
            if resume { model.play() }
        }
    }

    static func clock(_ seconds: Double) -> String {
        Duration.seconds(Int(max(0, seconds).rounded(.down))).formatted(.time(pattern: .minuteSecond))
    }
}

/// A round control of the film (44 points: easy to hit).
private struct FilmButton: View {
    let title: String
    let systemImage: String
    var large = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(large ? .title.weight(.semibold) : .title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

/// A clip without controls, stretched to its frame (the frame has the clip's shape; the film places it).
struct FilmVideoSurface: View {
    let player: AVPlayer

    var body: some View {
        Surface(player: player).allowsHitTesting(false).accessibilityHidden(true)
    }

    #if os(macOS)
        private struct Surface: NSViewRepresentable {
            let player: AVPlayer

            func makeNSView(context: Context) -> NSView {
                let view = NSView()
                let layer = AVPlayerLayer(player: player)
                layer.videoGravity = .resize
                view.layer = layer
                view.wantsLayer = true
                return view
            }

            func updateNSView(_ view: NSView, context: Context) {
                (view.layer as? AVPlayerLayer)?.player = player
            }
        }
    #else
        private struct Surface: UIViewRepresentable {
            let player: AVPlayer

            final class PlayerView: UIView {
                override static var layerClass: AnyClass { AVPlayerLayer.self }
                // The layer class above makes this cast always succeed.
                var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
            }

            func makeUIView(context: Context) -> PlayerView {
                let view = PlayerView()
                view.playerLayer.videoGravity = .resize
                view.playerLayer.player = player
                return view
            }

            func updateUIView(_ view: PlayerView, context: Context) {
                if view.playerLayer.player !== player { view.playerLayer.player = player }
            }
        }
    #endif
}
