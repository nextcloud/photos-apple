// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosMedia
import PhotosModel
import PhotosNetworking
import SwiftUI

/// The person a "through the years" film is of.
struct YearsPerson: Identifiable, Hashable {
    var name: String
    var id: String { name }
}

/// Birthdays of people, for the age under their faces (SPEC §16.6). Recognize knows names, not birthdays: the user adds
/// one in the film; it is kept on this device, per account.
@MainActor enum BirthdayStore {
    static func key(_ account: String) -> String { "throughTheYearsBirthdays.\(account)" }

    static func birthday(of person: String, account: String, defaults: UserDefaults = .standard) -> Date? {
        guard let stored = (defaults.dictionary(forKey: key(account)) as? [String: Double])?[person] else { return nil }
        return Date(timeIntervalSince1970: stored)
    }

    static func set(_ date: Date?, of person: String, account: String, defaults: UserDefaults = .standard) {
        var all = (defaults.dictionary(forKey: key(account)) as? [String: Double]) ?? [:]
        all[person] = date?.timeIntervalSince1970
        defaults.set(all, forKey: key(account))
    }
}

/// The wording of "through the years".
enum YearsText {
    static var title: String {
        PlatformWording.title(
            mac: LocalizedStringResource(
                "Through the Years", bundle: .module, comment: "A person's face across the years as a film: menu item and film title."),
            other: LocalizedStringResource(
                "Through the years", bundle: .module, comment: "A person's face across the years as a film: menu item and film title."))
    }

    /// The date under a face: the month and year, or the year for films that take one photo a year.
    static func date(_ date: Date, period: ThroughTheYears.Period) -> String {
        period == .year
            ? date.formatted(.dateTime.year())
            : date.formatted(.dateTime.month(.wide).year())
    }

    /// "3 years old", "8 months old".
    static func age(_ components: DateComponents) -> String? {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = components.year != nil ? [.year] : [.month]
        guard let text = formatter.string(from: components) else { return nil }
        return String(
            localized: "\(text) old", bundle: .module, comment: "Through the years: the person's age under the date, e.g. '3 years old'.")
    }

    static func span(_ first: Date, _ last: Date) -> String {
        let from = first.formatted(.dateTime.year())
        let to = last.formatted(.dateTime.year())
        return from == to ? from : "\(from) – \(to)"
    }
}

extension View {
    /// Plays a person's "through the years" film: full screen on iPhone and iPad, pushed in the window on the Mac and
    /// Vision Pro (like a memory film).
    func throughTheYears(_ person: Binding<YearsPerson?>) -> some View {
        modifier(YearsPresenter(person: person))
    }
}

private struct YearsPresenter: ViewModifier {
    @Binding var person: YearsPerson?
    @Environment(SessionModel.self) private var session

    func body(content: Content) -> some View {
        #if os(iOS)
            content.fullScreenCover(item: $person) { (person: YearsPerson) in
                ThroughTheYearsPlayer(person: person.name).environment(session)
            }
        #else
            content.navigationDestination(item: $person) { (person: YearsPerson) in
                ThroughTheYearsPlayer(person: person.name)
            }
        #endif
    }
}

/// A face of the film: the photo and where its eyes are.
struct YearsFrame: Sendable {
    var pick: ThroughTheYears.Pick
    var eyes: ThroughTheYears.Eyes
    var item: MediaItem
}

/// The film's state (SPEC §16.6): the person's photos from Recognize, one per period, their faces found and aligned on the
/// device, then a clock over the time-lapse plan.
@MainActor @Observable final class ThroughTheYearsModel: FilmPlayback {
    enum Phase: Equatable {
        case loading(done: Int, total: Int)
        /// Recognize is not on the server.
        case noRecognize
        /// Too few photos across time.
        case notEnough
        case failed(String)
        case ready
    }

    let person: String
    private(set) var phase = Phase.loading(done: 0, total: 0)
    private(set) var frames: [YearsFrame] = []
    private(set) var period = ThroughTheYears.Period.month
    private(set) var plan: FilmPlan?
    var birthday: Date?
    var speed: ThroughTheYears.Speed {
        didSet { rebuild() }
    }
    var muted = false {
        didSet { syncSound() }
    }
    /// The latest face lined up while loading.
    private(set) var latest: CGImage?

    private(set) var anchorTime = 0.0
    private(set) var anchorDate: Date?
    private let music = SlideshowMusicPlayer()
    private var score: SlideshowMusic?

    /// Faces are rendered square, so they fill a landscape or a portrait screen alike (eyes a little above the middle).
    static let side = 1280.0

    init(person: String, speed: ThroughTheYears.Speed) {
        self.person = person
        self.speed = speed
    }

    var isPlaying: Bool { anchorDate != nil }
    var duration: Double { plan?.duration ?? 0 }
    var now: Double { time(at: Date()) }
    var ended: Bool { !isPlaying && plan != nil && anchorTime >= duration - 0.05 }

    func time(at date: Date) -> Double {
        guard let anchorDate else { return anchorTime }
        return min(duration, anchorTime + max(0, date.timeIntervalSince(anchorDate)))
    }

    var first: Date? { frames.first?.pick.sample.date }
    var last: Date? { frames.last?.pick.sample.date }

    func load(session: SessionModel) async {
        guard let services = session.services else { return }
        guard session.features.has(.recognize) else {
            phase = .noRecognize
            return
        }
        let photos: [PersonPhoto]
        do {
            photos = try await services.api.personPhotos(person, key: await session.recognizeKey())
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        // Photos only, and none that were archived on this device's library.
        let local = (try? await services.library.fetchItems(photos.map(\.item.fileId))) ?? [:]
        var items: [FileID: MediaItem] = [:]
        var samples: [ThroughTheYears.Sample] = []
        for photo in photos where photo.item.kind == .image && local[photo.item.fileId]?.isArchived != true {
            let item = local[photo.item.fileId] ?? photo.item
            items[item.fileId] = item
            samples.append(
                ThroughTheYears.Sample(
                    fileId: item.fileId, date: item.timestamp,
                    face: photo.box.map { FilmCrop(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }, isFavorite: item.isFavorite,
                    aspectRatio: item.aspectRatio))
        }
        period = ThroughTheYears.period(spanning: samples)
        let candidates = ThroughTheYears.candidates(samples, period: period)
        guard candidates.count >= ThroughTheYears.minimumFrames else {
            phase = .notEnough
            return
        }
        let total = candidates.count
        phase = .loading(done: 0, total: total)
        var found: [Int: YearsFrame] = [:]
        var done = 0
        // A few periods at a time: downloads and face detection in parallel, in the order of the film; a period's next
        // photo when its best face cannot be lined up. Only the eyes are kept; the pictures are drawn again around the
        // moment they are shown.
        for chunk in stride(from: 0, to: total, by: 4).map({ Array(candidates.indices[$0..<min($0 + 4, total)]) }) {
            if Task.isCancelled { return }
            await withTaskGroup(of: (Int, YearsFrame?, CGImage?).self) { group in
                for index in chunk {
                    let options: [(ThroughTheYears.Pick, MediaItem)] = candidates[index].compactMap { pick in
                        items[pick.sample.fileId].map { (pick, $0) }
                    }
                    group.addTask {
                        for (pick, item) in options {
                            guard let found = await Self.prepare(pick, item: item, services: services) else { continue }
                            let thumbnail = FaceTimeLapse.frame(found.image, eyes: found.frame.eyes, size: CGSize(width: 360, height: 360))
                            return (index, found.frame, thumbnail)
                        }
                        return (index, nil, nil)
                    }
                }
                for await (index, frame, thumbnail) in group {
                    done += 1
                    if let frame { found[index] = frame }
                    if let thumbnail { latest = thumbnail }
                    phase = .loading(done: done, total: total)
                }
            }
        }
        frames = found.keys.sorted().compactMap { found[$0] }
        guard frames.count >= ThroughTheYears.minimumFrames else {
            phase = .notEnough
            return
        }
        self.services = services
        if await ScoreSynth.file(for: FilmStyle.calm.score) != nil { score = FilmStyle.calm.scoreMusic }
        rebuild()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<min(3, frames.count) { group.addTask { await self.render(index) } }
        }
        phase = .ready
    }

    /// The aligned faces around the current time, by frame.
    private(set) var rendered: [Int: CGImage] = [:]
    private var rendering: Set<Int> = []
    private var services: AccountServices?

    /// The photo of a pick and its eyes (Recognize's box tells which face is the person's).
    nonisolated static func prepare(_ pick: ThroughTheYears.Pick, item: MediaItem, services: AccountServices, size: Int = 1600) async
        -> (frame: YearsFrame, image: CGImage)?
    {
        let request = ImagePipeline.Request(
            fileId: item.fileId, etag: item.etag, bucket: 4096, hasPreview: item.hasPreview, mimeType: item.mimeType,
            originalURL: services.originalURL(for: item), maxPixelSize: size)
        guard let image = await services.images.preview(request) else { return nil }
        guard let eyes = await FaceTimeLapse.eyes(in: image, near: pick.sample.face) else { return nil }
        return (YearsFrame(pick: pick, eyes: eyes, item: item), image)
    }

    /// Draws a face aligned (square, `side`), from the preview the loading already fetched (it is in the cache).
    private func render(_ index: Int) async {
        guard rendered[index] == nil, !rendering.contains(index), let frame = frames[safe: index], let services else { return }
        rendering.insert(index)
        defer { rendering.remove(index) }
        let side = Self.side
        let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            let request = ImagePipeline.Request(
                fileId: frame.item.fileId, etag: frame.item.etag, bucket: 4096, hasPreview: frame.item.hasPreview,
                mimeType: frame.item.mimeType, originalURL: services.originalURL(for: frame.item), maxPixelSize: 1600)
            guard let source = await services.images.preview(request) else { return nil }
            return FaceTimeLapse.frame(source, eyes: frame.eyes, size: CGSize(width: side, height: side))
        }.value
        if let image { rendered[index] = image }
    }

    private func rebuild() {
        guard !frames.isEmpty else { return }
        let progress = duration > 0 ? now / duration : 0
        plan = ThroughTheYears.plan(frames: frames.count, speed: speed)
        anchorTime = progress * duration
        if anchorDate != nil { anchorDate = Date() }
        syncSound(seeking: true)
    }

    /// The date and age shown under a frame.
    func caption(_ index: Int) -> (date: String, age: String?) {
        let date = frames[index].pick.sample.date
        let age = birthday.flatMap { ThroughTheYears.age(on: date, birthday: $0) }.flatMap { YearsText.age($0) }
        return (YearsText.date(date, period: period), age)
    }

    // MARK: Clock

    func play() {
        guard plan != nil else { return }
        if ended { anchorTime = 0 }
        anchorDate = Date()
        syncSound(seeking: true)
    }

    func pause() {
        anchorTime = now
        anchorDate = nil
        syncSound()
    }

    func togglePlaying() { if isPlaying { pause() } else { play() } }

    func seek(to time: Double) {
        anchorTime = min(max(0, time), duration)
        if anchorDate != nil { anchorDate = Date() }
        syncSound(seeking: true)
    }

    func skip(_ forward: Bool) {
        guard let plan else { return }
        if forward { seek(to: plan.nextStart(after: now) ?? duration) } else { seek(to: plan.previousStart(before: now)) }
    }

    /// Stops at the end, draws the faces about to be shown and lets go of those shown a while ago.
    func tick() {
        guard let plan else { return }
        if isPlaying && now >= duration {
            anchorTime = duration
            anchorDate = nil
            syncSound()
        }
        let time = now
        // Faces (cards after the title) on screen within the next few seconds.
        var wanted: Set<Int> = [0]
        for segment in plan.segments where segment.end + 1 >= time && segment.start <= time + 5 {
            if case .card(let card) = segment.content, card > 0 { wanted.insert(card - 1) }
        }
        for index in wanted where rendered[index] == nil { Task { await render(index) } }
        for index in rendered.keys where !wanted.contains(index) { rendered[index] = nil }
    }

    private func syncSound(seeking: Bool = false) {
        guard let score else { return }
        if isPlaying && !muted { music.play(score, at: seeking ? now : nil) } else { music.pause() }
    }

    func stop() {
        anchorDate = nil
        music.stop()
    }

    // MARK: Export

    /// The film as a 1080p video: the same faces aligned for a landscape frame, the captions drawn in, the calm score.
    func export(codec: FilmExporter.Codec, session: SessionModel, report: @escaping @MainActor (Double, String) -> Void) async throws
        -> URL
    {
        guard let services = session.services, let first, let last else { throw CancellationError() }
        let size = CGSize(width: 1920, height: 1080)
        var material = FilmMaterial()
        report(0.02, FilmExportJob.photosStep)
        var faces: [CGImage] = []
        for (index, frame) in frames.enumerated() {
            try Task.checkCancellation()
            guard let source = await Self.prepare(frame.pick, item: frame.item, services: services, size: 2560),
                let aligned = FaceTimeLapse.frame(source.image, eyes: source.frame.eyes, size: size)
            else { continue }
            let caption = caption(index)
            let overlay = MemoryFilmExportSheet.render(
                YearsCaption(date: caption.date, age: caption.age, height: size.height), size: size)
            faces.append(Self.compose(aligned, overlay: overlay, size: size) ?? aligned)
            report(0.02 + 0.5 * Double(index + 1) / Double(frames.count), FilmExportJob.photosStep)
        }
        guard let opening = faces.first else { throw CancellationError() }
        let title = MemoryFilmExportSheet.render(
            YearsTitle(name: person, span: YearsText.span(first, last), height: size.height), size: size)
        material.cards = [Self.compose(Self.darkened(opening) ?? opening, overlay: title, size: size) ?? opening] + faces
        let plan = ThroughTheYears.plan(frames: faces.count, speed: speed)
        let music = await ScoreSynth.file(for: .ambient)
        report(0.55, FilmExportJob.renderingStep)
        let exporter = FilmExporter(
            plan: plan, material: material, size: size, codec: codec, music: music, still: true,
            fileName: "\(person) – \(YearsText.title)")
        return try await exporter.export { progress in
            Task { @MainActor in report(0.55 + 0.45 * progress, FilmExportJob.renderingStep) }
        }
    }

    static func compose(_ base: CGImage, overlay: CGImage?, size: CGSize) -> CGImage? {
        guard let overlay else { return base }
        let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(base, in: CGRect(origin: .zero, size: size))
        context?.draw(overlay, in: CGRect(origin: .zero, size: size))
        return context?.makeImage()
    }

    /// The title's background: the first face, dimmed.
    static func darkened(_ image: CGImage) -> CGImage? {
        let size = CGSize(width: image.width, height: image.height)
        let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(image, in: CGRect(origin: .zero, size: size))
        context?.setFillColor(CGColor(gray: 0, alpha: 0.55))
        context?.fill(CGRect(origin: .zero, size: size))
        return context?.makeImage()
    }
}

/// The date and age under a face, sized to the frame (the export renders the same view).
struct YearsCaption: View {
    let date: String
    let age: String?
    let height: CGFloat

    var body: some View {
        VStack(spacing: height * 0.006) {
            Spacer()
            Text(date)
                .font(.system(size: height * 0.05, weight: .semibold, design: .serif))
            if let age {
                Text(age).font(.system(size: height * 0.03, weight: .medium)).opacity(0.85)
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.7), radius: height * 0.015)
        .padding(.bottom, height * 0.08)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

/// The title card: the person's name, "Through the years" and the span of years.
struct YearsTitle: View {
    let name: String
    let span: String
    let height: CGFloat

    var body: some View {
        VStack(spacing: height * 0.014) {
            Text(name)
                .font(.system(size: height * 0.085, weight: .bold, design: .serif))
                .lineLimit(2)
                .minimumScaleFactor(0.5)
            Text(YearsText.title.uppercased())
                .font(.system(size: height * 0.026, weight: .semibold))
                .tracking(height * 0.004)
            Text(span).font(.system(size: height * 0.032, design: .serif)).italic()
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.6), radius: height * 0.02)
        .padding(.horizontal, height * 0.08)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

/// A person's face through the years (SPEC §16.6): one photo per month (or season, or year), the eyes level and in the
/// same place in every frame, dissolving into each other, with the date and (with a birthday) the age. Exportable as a
/// video. Without Recognize, without a name or without enough photos it says why.
struct ThroughTheYearsPlayer: View {
    let person: String
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("throughTheYearsSpeed") private var storedSpeed = ThroughTheYears.Speed.normal.rawValue
    @State private var model: ThroughTheYearsModel
    @State private var controlsShown = true
    @State private var scrubbing: Double?
    @State private var resume = false
    @State private var exporting = false
    @State private var editingBirthday = false
    @State private var lastInteraction = Date()
    @FocusState private var focused: Bool

    init(person: String) {
        self.person = person
        let stored = UserDefaults.standard.string(forKey: "throughTheYearsSpeed") ?? ""
        _model = State(initialValue: ThroughTheYearsModel(person: person, speed: ThroughTheYears.Speed(rawValue: stored) ?? .normal))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()
                switch model.phase {
                case .ready:
                    if let plan = model.plan {
                        TimelineView(.animation(paused: !model.isPlaying || scrubbing != nil)) { context in
                            frame(plan: plan, time: scrubbing ?? model.time(at: context.date), size: proxy.size)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(description)
                        .accessibilityAddTraits(.isImage)
                    }
                    if model.ended { endCard }
                case .loading(let done, let total):
                    loading(done: done, total: total)
                case .noRecognize:
                    explanation(
                        systemImage: "person.crop.circle.badge.questionmark",
                        text: String(
                            localized:
                                "Through the years needs face recognition on your Nextcloud: the Recognize app. Ask whoever runs your Nextcloud to install it; once people are recognized and named, their films appear here.",
                            bundle: .module, comment: "Through the years: the server has no face recognition."))
                case .notEnough:
                    explanation(
                        systemImage: "calendar.badge.clock",
                        text: String(
                            localized:
                                "There aren't enough photos of \(person) across time yet. Through the years needs clear photos of their face from at least three different months.",
                            bundle: .module, comment: "Through the years: too few photos of the person over time. The argument is the name."
                        ))
                case .failed(let message):
                    explanation(systemImage: "exclamationmark.triangle", text: message)
                }
            }
        }
        #if os(iOS)
            .ignoresSafeArea()
        #endif
        .contentShape(.rect)
        .onTapGesture {
            lastInteraction = Date()
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { controlsShown.toggle() }
        }
        .overlay(alignment: .top) {
            // Faded rather than removed: an open menu stays open when the controls hide.
            topBar.opacity(controlsShown ? 1 : 0).allowsHitTesting(controlsShown).accessibilityHidden(!controlsShown)
        }
        .overlay(alignment: .bottom) {
            if controlsShown && model.phase == .ready && !model.ended {
                FilmControls(model: model, scrubbing: $scrubbing, resume: $resume)
            }
        }
        #if os(iOS)
            .statusBarHidden(!controlsShown)
            .persistentSystemOverlays(controlsShown ? .automatic : .hidden)
        #else
            .navigationTitle(person)
        #endif
        .keyFocusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .hardwareKeys([.leftArrow, .rightArrow, .space, .escape, "m"]) { key in
            switch key {
            case .leftArrow: model.skip(false)
            case .rightArrow: model.skip(true)
            case .space: model.togglePlaying()
            case "m": model.muted.toggle()
            default: dismiss()
            }
            lastInteraction = Date()
        }
        .task {
            model.birthday = BirthdayStore.birthday(of: person, account: session.account.id.rawValue)
            await model.load(session: session)
            if model.phase == .ready && Slideshow.startsPlaying(voiceOver: voiceOver) { model.play() }
        }
        .task(id: model.phase == .ready) {
            while !Task.isCancelled {
                model.tick()
                if controlsShown, model.isPlaying, scrubbing == nil, !voiceOver, Date().timeIntervalSince(lastInteraction) > 3.5 {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.4)) { controlsShown = false }
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        .onChange(of: storedSpeed) { _, raw in model.speed = ThroughTheYears.Speed(rawValue: raw) ?? .normal }
        .onChange(of: model.isPlaying) { _, playing in DisplaySleep.prevent(playing) }
        .onChange(of: scenePhase) { _, phase in if phase != .active && model.isPlaying { model.pause() } }
        .onDisappear {
            model.stop()
            DisplaySleep.prevent(false)
        }
        .sheet(isPresented: $exporting) { ThroughTheYearsExportSheet(model: model) }
        .sheet(isPresented: $editingBirthday) {
            BirthdaySheet(person: person, birthday: model.birthday) { date in
                model.birthday = date
                BirthdayStore.set(date, of: person, account: session.account.id.rawValue)
            }
        }
    }

    // MARK: Frames

    func frame(plan: FilmPlan, time: Double, size: CGSize) -> some View {
        ZStack {
            Color.black
            ForEach(plan.layers(at: time), id: \.segment) { (layer: FilmLayer) in
                card(plan.segments[layer.segment], size: size).opacity(layer.opacity)
            }
            Color.black.opacity(1 - plan.brightness(at: time)).allowsHitTesting(false)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    @ViewBuilder func card(_ segment: FilmSegment, size: CGSize) -> some View {
        if case .card(let index) = segment.content {
            let height = FilmTitleOverlay.textScale(size)
            if index == 0 {
                ZStack {
                    face(0, size: size).overlay(Color.black.opacity(0.55))
                    if let first = model.first, let last = model.last {
                        YearsTitle(name: person, span: YearsText.span(first, last), height: height)
                    }
                }
            } else {
                let caption = model.caption(index - 1)
                ZStack {
                    face(index - 1, size: size)
                    YearsCaption(date: caption.date, age: caption.age, height: height)
                }
            }
        }
    }

    /// An aligned face, filling the frame (square: the sides or the top and bottom are cut).
    @ViewBuilder func face(_ index: Int, size: CGSize) -> some View {
        if let image = model.rendered[index] {
            Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height).clipped()
        }
    }

    var description: String {
        guard let plan = model.plan, let index = plan.segmentIndex(at: model.now), case .card(let card) = plan.segments[index].content
        else { return person }
        if card == 0 { return AccessibilityText.join([person, YearsText.title]) }
        let caption = model.caption(card - 1)
        return AccessibilityText.join([person, caption.date, caption.age])
    }

    // MARK: States

    func loading(done: Int, total: Int) -> some View {
        VStack(spacing: 18) {
            if let latest = model.latest {
                Image(decorative: latest, scale: 1).resizable().scaledToFit()
                    .frame(width: 180, height: 180).clipShape(.circle)
                    .overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 1))
                    .transition(.opacity)
                    .id(ObjectIdentifier(latest))
            } else {
                Image(systemName: "person.crop.circle").font(.system(size: 80, weight: .ultraLight)).foregroundStyle(.white.opacity(0.5))
            }
            Text(
                "Lining up \(person)'s face across the years…", bundle: .module,
                comment: "Through the years: shown while the photos are loaded and the faces aligned. The argument is the name."
            )
            .font(.headline)
            if total > 0 {
                ProgressView(value: Double(done), total: Double(total)).frame(maxWidth: 260).tint(.white)
            }
        }
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .padding(32)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: done)
    }

    func explanation(systemImage: String, text: String) -> some View {
        ContentUnavailableView {
            Label(YearsText.title, systemImage: systemImage)
        } description: {
            Text(text)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    var topBar: some View {
        HStack(spacing: 12) {
            FilmButton(title: String(localized: "Close", bundle: .module), systemImage: "xmark") { dismiss() }
            Spacer(minLength: 0)
            if model.phase == .ready {
                FilmButton(
                    title: model.muted
                        ? String(localized: "Turn Sound On", bundle: .module) : String(localized: "Mute", bundle: .module),
                    systemImage: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
                ) { model.muted.toggle() }
                optionsMenu
                FilmButton(title: MemoryFilmExportSheet.menuTitle, systemImage: "square.and.arrow.up") {
                    model.pause()
                    exporting = true
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .background(alignment: .top) {
            LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 110).ignoresSafeArea().allowsHitTesting(false)
        }
    }

    var optionsMenu: some View {
        Menu {
            Picker(selection: $storedSpeed) {
                Text("Slow", bundle: .module, comment: "Through the years: speed, about 1.6 s per face.")
                    .tag(ThroughTheYears.Speed.slow.rawValue)
                Text("Normal", bundle: .module, comment: "Through the years: speed, about a second per face.")
                    .tag(ThroughTheYears.Speed.normal.rawValue)
                Text("Fast", bundle: .module, comment: "Through the years: speed, about half a second per face.")
                    .tag(ThroughTheYears.Speed.fast.rawValue)
            } label: {
                Text("Speed", bundle: .module, comment: "Through the years: how fast the faces change.")
            }
            .pickerStyle(.inline)
            Button {
                editingBirthday = true
            } label: {
                Label(
                    model.birthday == nil
                        ? String(
                            localized: "Add Birthday…", bundle: .module,
                            comment: "Through the years: adds the person's birthday to show their age.")
                        : String(
                            localized: "Change Birthday…", bundle: .module, comment: "Through the years: changes the person's birthday."),
                    systemImage: "birthday.cake")
            }
        } label: {
            Label(
                String(localized: "Options", bundle: .module, comment: "Through the years: menu of speed and birthday."),
                systemImage: "ellipsis.circle"
            )
            .labelStyle(.iconOnly)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .contentShape(.rect)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
    }

    var endCard: some View {
        VStack(spacing: 18) {
            Text(person).font(.title.bold())
            HStack(spacing: 12) {
                Button {
                    model.play()
                } label: {
                    Label(String(localized: "Play Again", bundle: .module), systemImage: "arrow.counterclockwise")
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
    }
}

/// The person's birthday, for the age under the faces; kept on this device.
struct BirthdaySheet: View {
    let person: String
    let birthday: Date?
    let save: (Date?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker(
                        String(localized: "Birthday", bundle: .module, comment: "Through the years: the person's birthday."),
                        selection: $date,
                        in: ...Date(), displayedComponents: .date)
                } footer: {
                    Text(
                        "Shows \(person)'s age under every photo. Kept on this device.", bundle: .module,
                        comment: "Through the years: what the birthday is for. The argument is the name.")
                }
                if birthday != nil {
                    Button(
                        String(localized: "Remove Birthday", bundle: .module, comment: "Through the years: forgets the birthday."),
                        role: .destructive
                    ) {
                        save(nil)
                        dismiss()
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(person)
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", bundle: .module)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save", bundle: .module)) {
                        save(date)
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 360, minHeight: 260)
        #if os(iOS)
            .presentationDetents([.medium])
        #endif
        .onAppear { if let birthday { date = birthday } }
    }
}

/// "Through the years" as a 1080p video.
struct ThroughTheYearsExportSheet: View {
    let model: ThroughTheYearsModel
    @Environment(SessionModel.self) private var session
    @State private var job = FilmExportJob()
    @AppStorage("memoryFilmCodec") private var codec = FilmExporter.Codec.h264.rawValue

    var body: some View {
        FilmExportView(
            title: model.person, job: job, codec: $codec,
            musicNote: String(
                localized: "With calm music, made on this device.", bundle: .module,
                comment: "Through the years video export: the music that goes into the video."),
            fileName: model.person
        ) {
            let codec = FilmExporter.Codec(rawValue: codec) ?? .h264
            let model = model
            let session = session
            job.start { report in try await model.export(codec: codec, session: session, report: report) }
        }
    }
}

/// "Through the years" in the Memories screen (SPEC §16.6): the named people, each a film; without Recognize or without
/// named people, a line that says what is needed.
struct ThroughTheYearsRow: View {
    @Environment(SessionModel.self) private var session
    @State private var people: [Person] = []
    @State private var loaded = false
    @State private var playing: YearsPerson?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if loaded {
                Text(YearsText.title).font(Typography.sectionTitle).accessibilityAddTraits(.isHeader)
                if !session.features.has(.recognize) {
                    note(
                        String(
                            localized:
                                "Watch the people you love grow up: Through the years needs face recognition (the Recognize app) on your Nextcloud.",
                            bundle: .module, comment: "Memories: Through the years needs Recognize on the server."))
                } else if people.isEmpty {
                    note(
                        String(
                            localized: "Name people in People to watch them grow up through the years.", bundle: .module,
                            comment: "Memories: Through the years needs named people."))
                } else {
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 16) {
                            ForEach(people) { (person: Person) in
                                Button {
                                    playing = YearsPerson(name: person.name)
                                } label: {
                                    VStack(spacing: 6) {
                                        Group {
                                            if let cover = person.coverFileId {
                                                FaceCroppedPreview(fileId: cover, box: person.coverBox)
                                            } else {
                                                Color.secondary.opacity(0.2)
                                            }
                                        }
                                        .frame(width: 84, height: 84)
                                        .clipShape(.circle)
                                        Text(person.name).font(.caption).lineLimit(1).frame(maxWidth: 90)
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Text(verbatim: "\(person.name), \(YearsText.title)"))
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
        .throughTheYears($playing)
        .task {
            defer { loaded = true }
            guard session.features.has(.recognize), let services = session.services else { return }
            let hidden = session.hiddenPeopleFile.map { HiddenPeople.load(from: $0) } ?? HiddenPeople()
            let all = (try? await services.api.people(key: await session.recognizeKey())) ?? []
            // Named people with enough photos to change over time, most photographed first.
            people = Array(all.filter { !$0.isUnnamed && !hidden.names.contains($0.name) && $0.itemCount >= 6 }.prefix(12))
        }
    }

    func note(_ text: String) -> some View {
        Label(text, systemImage: "person.crop.rectangle.stack")
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}
