// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import AVFoundation
import MapKit
import OSLog
import PhotosCore
import PhotosDomain
import PhotosMedia
import PhotosModel
import PhotosStore
import SwiftUI

/// What a memory film is made of before anything is loaded: the memory's photos as shots, the plan cut to the music,
/// and the music (SPEC §15.1, §16.6). Shared by the player and the video export.
struct FilmMaking {
    var plan: FilmPlan
    /// The items of `plan.shots`, in the same order.
    var items: [MediaItem]
    /// Live Photo motion files, by the still's file id.
    var motions: [FileID: MediaItem]
    var music: SlideshowMusic?
    /// The music as a file the app can read (nil for none and for Apple Music songs).
    var musicFile: URL?
    /// Shots whose item is not in this account's library (a film shared by someone else): loaded by file id alone.
    var remote: Set<Int> = []

    /// Loads the memory's items (archived ones are left out), finds the music's beat on the device and builds the plan in
    /// the chosen style.
    /// `waitsForScore`: the style's music is made first (the export needs the file); the player starts at once and the
    /// music joins when it is made (its tempo is known without it).
    @MainActor static func prepare(
        _ start: SlideshowStart, services: AccountServices, choice: FilmChoice, waitsForScore: Bool = false
    ) async -> FilmMaking {
        let map = (try? await services.library.fetchItems(start.ids)) ?? [:]
        let all = start.ids.compactMap { map[$0] }.filter { !$0.isLivePhotoVideo && !$0.isArchived }
        let peers = all.compactMap(\.livePhotoPeer)
        let peerMap = peers.isEmpty ? [:] : ((try? await services.library.fetchItems(peers)) ?? [:])
        var motions: [FileID: MediaItem] = [:]
        for item in all { if let peer = item.livePhotoPeer, let motion = peerMap[peer] { motions[item.fileId] = motion } }

        let (music, musicFile, rhythm) = await soundtrack(choice, playsMusic: start.playsMemoryMusic, waitsForScore: waitsForScore)
        let shots = all.map { item in
            var shot = FilmShot(item)
            // A Live Photo without its motion file is a still.
            if case .livePhoto = shot.kind, motions[item.fileId] == nil { shot.kind = .photo }
            return shot
        }
        let plan = FilmPlan(
            shots: shots, cover: start.cover, rhythm: rhythm, flights: start.isTrip, style: choice.style,
            keepsOrder: start.kind == .slideshow)
        let byId = Dictionary(all.map { ($0.fileId, $0) }, uniquingKeysWith: { first, _ in first })
        return FilmMaking(
            plan: plan, items: plan.shots.compactMap { byId[$0.fileId] }, motions: motions, music: music, musicFile: musicFile)
    }

    /// The music of a choice and the rhythm the film is cut to: the style's own score (its tempo is known), the user's
    /// music (its beat found on the device; the style sets only the pacing), or none (the style's steady rhythm).
    @MainActor static func soundtrack(_ choice: FilmChoice, playsMusic: Bool, waitsForScore: Bool = false) async -> (
        SlideshowMusic?, URL?, FilmRhythm
    ) {
        guard playsMusic else { return (nil, nil, choice.style.steadyRhythm) }
        switch choice.soundtrack {
        case .style:
            let mood = choice.style.score
            let file = waitsForScore ? await ScoreSynth.file(for: mood) : ScoreSynth.existingFile(for: mood)
            if waitsForScore && file == nil { return (nil, nil, choice.style.steadyRhythm) }
            return (choice.style.scoreMusic, file, FilmScore(mood: mood).rhythm)
        case .mine:
            guard let music = SlideshowMusicStore.current() else { return (nil, nil, choice.style.steadyRhythm) }
            let file = SlideshowMusicStore.readableURL(for: music)
            var rhythm = choice.style.steadyRhythm
            if let file { rhythm = await FilmRhythmCache.shared.rhythm(for: music, file: file) ?? rhythm }
            return (music, file, rhythm)
        case .none:
            return (nil, nil, choice.style.steadyRhythm)
        }
    }

    /// A film someone shared over SharePlay (SPEC §16.6): their timeline as it is; the pictures from this account's
    /// library where it has them, else asked for by file id (Nextcloud answers only for files shared with this account).
    @MainActor static func prepare(shared film: SharedFilm, services: AccountServices) async -> FilmMaking {
        let ids = film.pictures.map(\.fileId)
        let local = (try? await services.library.fetchItems(ids)) ?? [:]
        var items: [MediaItem] = []
        var remote: Set<Int> = []
        for (index, picture) in film.pictures.enumerated() {
            if let item = local[picture.fileId], !item.isArchived {
                items.append(item)
            } else {
                remote.insert(index)
                items.append(
                    MediaItem(
                        fileId: picture.fileId, path: "", name: "\(picture.fileId)", mimeType: picture.mimeType, etag: picture.etag,
                        hasPreview: picture.hasPreview))
            }
        }
        let peers = items.enumerated().filter { !remote.contains($0.offset) }.compactMap(\.element.livePhotoPeer)
        let peerMap = peers.isEmpty ? [:] : ((try? await services.library.fetchItems(peers)) ?? [:])
        var motions: [FileID: MediaItem] = [:]
        for item in items { if let peer = item.livePhotoPeer, let motion = peerMap[peer] { motions[item.fileId] = motion } }
        var music: SlideshowMusic?
        var musicFile: URL?
        if film.playsScore {
            music = film.plan.style.scoreMusic
            musicFile = ScoreSynth.existingFile(for: film.plan.style.score)
        }
        return FilmMaking(plan: film.plan, items: items, motions: motions, music: music, musicFile: musicFile, remote: remote)
    }

    /// The film as something to watch together: the timeline without places, and what the others need to load each
    /// picture from Nextcloud.
    func shared(kind: SharedFilm.Kind, title: String, subtitle: String?, server: URL) -> SharedFilm {
        SharedFilm(
            kind: kind, title: title, subtitle: subtitle, server: server, plan: plan,
            pictures: items.map { SharedFilm.Picture(fileId: $0.fileId, etag: $0.etag, mimeType: $0.mimeType, hasPreview: $0.hasPreview) },
            playsScore: music?.scoreMood != nil)
    }
}

/// The beat of each chosen music, found once per launch (decoding a song takes a moment).
actor FilmRhythmCache {
    static let shared = FilmRhythmCache()
    private var known: [String: FilmRhythm?] = [:]

    func rhythm(for music: SlideshowMusic, file: URL) async -> FilmRhythm? {
        if let cached = known[music.stored] { return cached }
        let found = await Task.detached(priority: .userInitiated) { await AudioRhythm.rhythm(of: file) }.value
        known[music.stored] = found
        return found
    }
}

/// The player's state (SPEC §15.1, §16.6): the plan in its style, the pictures loaded around the current time (graded
/// in the style's colours) with their focus, the clips, the map pictures of the flights, the clock and the music; and,
/// while watched together over SharePlay, the group's timing.
@MainActor @Observable final class MemoryFilmModel {
    private(set) var start: SlideshowStart
    private(set) var making: FilmMaking?
    var plan: FilmPlan? { making?.plan }
    private(set) var loaded = false
    /// The style and music (SPEC §16.6), remembered per memory.
    private(set) var choice: FilmChoice
    /// Watched together: the shared film (this device's own or someone else's).
    private(set) var shared: SharedFilm?
    /// The film came from someone else over SharePlay.
    private(set) var isGuest = false

    /// Pictures by shot index (in the style's colours), and a tiny copy of each that is drawn enlarged (a blur for free)
    /// behind pictures shown whole.
    private(set) var stills: [Int: CGImage] = [:]
    private(set) var fills: [Int: CGImage] = [:]
    private(set) var focus: [Int: FilmCrop] = [:]
    /// Pictures as loaded, before the style's colours: a change of style grades them again.
    private var originals: [Int: CGImage] = [:]
    /// The camera move of each segment, fixed when it first comes on screen.
    private(set) var motions: [Int: KenBurns.Motion] = [:]
    /// Map pictures of the flights, by segment index.
    private(set) var maps: [Int: FilmMapPicture] = [:]
    /// Clips (videos, Live Photo motion), by shot index.
    private(set) var videos: [Int: PlayableVideo] = [:]
    /// Pictures this account cannot load (a shared film's photos that are not shared with it), and how many were tried.
    private(set) var unavailable: Set<Int> = []
    private(set) var checked = 0
    /// The grain of the style, drawn over the film.
    private(set) var grain: CGImage?

    /// The clock: the film's time at `anchorDate` (nil while paused). A start planned for everyone has its anchor a
    /// moment in the future; the film waits until then.
    private(set) var anchorTime = 0.0
    private(set) var anchorDate: Date?
    /// The segment on screen (changes a few times a second at most; the frames themselves are drawn from the clock).
    private(set) var segment = 0
    private(set) var ended = false
    var muted = false {
        didSet { syncSound() }
    }
    var still = false
    var viewportAspect = 16.0 / 9.0

    private let music = SlideshowMusicPlayer()
    private var loading: Set<Int> = []
    private var loadingVideos: Set<Int> = []
    private var loadingMaps: Set<Int> = []
    private var failedMaps: Set<Int> = []
    private weak var session: SessionModel?

    init(start: SlideshowStart) {
        self.start = start
        choice = FilmChoiceStore.choice(for: start.id)
    }

    /// A film someone shared over SharePlay.
    init(shared film: SharedFilm) {
        start = SlideshowStart(shared: film)
        choice = FilmChoice(style: film.plan.style, soundtrack: film.playsScore ? .style : .none)
        shared = film
        isGuest = true
    }

    var isPlaying: Bool { anchorDate != nil }
    var duration: Double { plan?.duration ?? 0 }
    var hasMusic: Bool { making?.music != nil }
    var look: FilmLook { plan?.style.look ?? .none }

    func time(at date: Date) -> Double {
        guard let anchorDate else { return anchorTime }
        return min(duration, anchorTime + max(0, date.timeIntervalSince(anchorDate)))
    }

    var now: Double { time(at: Date()) }

    // MARK: Loading

    func load(session: SessionModel, autoplay: Bool) async {
        self.session = session
        guard let services = session.services else { return }
        let making: FilmMaking
        if let shared, isGuest {
            making = await FilmMaking.prepare(shared: shared, services: services)
        } else {
            making = await FilmMaking.prepare(start, services: services, choice: choice)
        }
        self.making = making
        grain = FilmLookFilter.grainTile(making.plan.style.look)
        makeScoreIfNeeded()
        // The opening pictures before the film starts, so it does not open on grey.
        let first = making.plan.upcomingShots(from: 0, within: 6)
        await withTaskGroup(of: Void.self) { group in
            for shot in first.prefix(3) { group.addTask { await self.loadStill(shot) } }
        }
        loaded = true
        tick()
        if isGuest {
            checkAvailability()
            attachToGroup(playing: false)
        } else if autoplay && !making.items.isEmpty {
            play()
        }
    }

    /// Another style or music (SPEC §16.6): the film is made again in it, from the picture it was at; the choice is
    /// remembered for this memory.
    func change(_ newChoice: FilmChoice) async {
        guard newChoice != choice, !isGuest, let services = session?.services, let old = plan else { return }
        let wasPlaying = isPlaying
        let shot = old.segments[safe: segment].flatMap { old.shotIndex(of: $0) }
        let fileId = shot.flatMap { old.shots[safe: $0]?.fileId }
        choice = newChoice
        FilmChoiceStore.save(newChoice, for: start.id)
        pause()
        let making = await FilmMaking.prepare(start, services: services, choice: newChoice)
        // The same pictures in the same order: loaded pictures, focus and clips stay; their colours and moves change.
        self.making = making
        music.stop()
        makeScoreIfNeeded()
        motions = [:]
        grain = FilmLookFilter.grainTile(making.plan.style.look)
        let look = making.plan.style.look
        for (index, image) in originals { show(image, for: index, look: look, first: true) }
        var resume = 0.0
        if let fileId, let index = making.plan.shots.firstIndex(where: { $0.fileId == fileId }),
            let target = making.plan.segments.first(where: { making.plan.shotIndex(of: $0) == index && $0.content != .title })
        {
            resume = target.start
        }
        anchorTime = min(resume, duration)
        ended = false
        tick()
        if shared != nil && !isGuest {
            // Watching together: the others get the film in its new style.
            await shareAgain()
        } else if wasPlaying {
            play()
        }
    }

    /// The style's music is made on first use (about a second); the film does not wait for it: the music joins at the
    /// film's time once it is there.
    private func makeScoreIfNeeded() {
        guard let mood = making?.music?.scoreMood, making?.musicFile == nil else { return }
        Task {
            guard let file = await ScoreSynth.file(for: mood), making?.music?.scoreMood == mood else { return }
            making?.musicFile = file
            music.stop()
            wasMusicPlaying = false
            syncSound(seeking: true)
        }
    }

    func loadStill(_ shot: Int) async {
        guard stills[shot] == nil, !loading.contains(shot), !unavailable.contains(shot), let item = making?.items[safe: shot],
            let services = session?.services
        else {
            return
        }
        loading.insert(shot)
        defer { loading.remove(shot) }
        let remote = making?.remote.contains(shot) == true
        let small = ImagePipeline.Request(
            fileId: item.fileId, etag: item.etag, bucket: 1024, hasPreview: remote || item.hasPreview, mimeType: item.mimeType,
            originalURL: remote ? nil : services.originalURL(for: item))
        guard let image = await services.images.preview(small) else {
            if remote { unavailable.insert(shot) }
            return
        }
        show(image, for: shot, look: look, first: originals[shot] == nil)
        // Sharper on large screens: the 4096 preview, decoded no larger than 2048.
        var large = small
        large.bucket = 4096
        large.maxPixelSize = 2048
        if let image = await services.images.preview(large) { show(image, for: shot, look: look, first: false) }
    }

    private func show(_ image: CGImage, for shot: Int, look: FilmLook, first: Bool) {
        let isNew = originals[shot] == nil
        originals[shot] = image
        let graded = FilmLookFilter.graded(image, look: look) ?? image
        stills[shot] = graded
        guard first else { return }
        fills[shot] = FilmPictures.thumbnail(graded, width: 48)
        guard isNew else { return }
        Task {
            let found = await Task.detached(priority: .utility) { await FrameFocus.focus(of: image) }.value
            if let found { self.focus[shot] = found }
        }
    }

    /// A shared film: which of its pictures this account can load (small previews of all of them, a few at a time); the
    /// others are told.
    private func checkAvailability() {
        guard let making, let services = session?.services else { return }
        let remote = making.remote.sorted()
        checked = making.items.count - remote.count
        report()
        Task {
            for chunk in stride(from: 0, to: remote.count, by: 6).map({ Array(remote[$0..<min($0 + 6, remote.count)]) }) {
                await withTaskGroup(of: (Int, Bool).self) { group in
                    for shot in chunk {
                        let item = making.items[shot]
                        group.addTask {
                            let request = ImagePipeline.Request(
                                fileId: item.fileId, etag: item.etag, bucket: 256, hasPreview: true, mimeType: item.mimeType,
                                originalURL: nil)
                            return (shot, await services.images.preview(request) != nil)
                        }
                    }
                    for await (shot, ok) in group where !ok { self.unavailable.insert(shot) }
                }
                checked += chunk.count
                report()
            }
        }
    }

    private func report() {
        guard isGuest, let making else { return }
        let total = making.items.count
        guard checked >= total else { return }
        WatchTogether.shared.report(
            SharedFilmReport(visible: total - unavailable.count, total: total, problem: unavailable.isEmpty ? nil : .notShared))
    }

    // MARK: Clock

    func play() {
        if isWatchedTogether {
            if ended || anchorTime >= duration - 0.05 { WatchTogether.shared.seek(to: 0) }
            WatchTogether.shared.play()
            return
        }
        startClock(at: ended || anchorTime >= duration - 0.05 ? 0 : anchorTime, delay: 0)
    }

    private func startClock(at time: Double, delay: Double) {
        guard let plan, !plan.segments.isEmpty else { return }
        anchorTime = min(max(0, time), duration)
        ended = false
        anchorDate = Date().addingTimeInterval(delay)
        syncSound(seeking: true)
        tick()
    }

    func pause() {
        if isWatchedTogether {
            WatchTogether.shared.pause()
            return
        }
        stopClock()
    }

    private func stopClock(at time: Double? = nil) {
        anchorTime = time ?? now
        anchorDate = nil
        syncSound()
        for video in videos.values { video.player.pause() }
    }

    func togglePlaying() {
        if isPlaying { pause() } else { play() }
    }

    func seek(to time: Double) {
        if isWatchedTogether {
            WatchTogether.shared.seek(to: time)
            return
        }
        moveClock(to: time)
    }

    private func moveClock(to time: Double) {
        anchorTime = min(max(0, time), duration)
        ended = false
        if anchorDate != nil { anchorDate = Date() }
        syncSound(seeking: true)
        tick()
    }

    func skip(_ forward: Bool) {
        guard let plan else { return }
        if forward {
            if let next = plan.nextStart(after: now) { seek(to: next) } else { seek(to: duration) }
        } else {
            seek(to: plan.previousStart(before: now))
        }
    }

    private func syncSound(seeking: Bool = false) {
        guard let music = making?.music else { return }
        if isPlaying && !muted {
            // A start planned for a moment from now: the music begins with the film.
            let position = max(0, time(at: Date()) - max(0, anchorDate.map { $0.timeIntervalSinceNow } ?? 0))
            self.music.play(music, at: seeking || !wasMusicPlaying ? position : nil)
            wasMusicPlaying = true
        } else {
            self.music.pause()
            wasMusicPlaying = false
        }
    }

    private var wasMusicPlaying = false

    func stop() {
        anchorDate = nil
        music.stop()
        for video in videos.values { video.release() }
        videos = [:]
        if WatchTogether.shared.isAttached(self) {
            WatchTogether.shared.detach(self)
            // A guest who closes the film leaves the session; whoever shared it stays in it for the others.
            if isGuest { WatchTogether.shared.leave() }
        }
    }

    // MARK: SharePlay

    /// In step with the people in the SharePlay session.
    var isWatchedTogether: Bool { shared != nil && WatchTogether.shared.isAttached(self) }

    /// Shares the film with the people in the call (SPEC §16.6). The user's own music cannot be shared: the film is made
    /// again with the style's music first.
    func shareWithGroup() async -> WatchTogether.StartResult {
        guard let session, making != nil, !isGuest else { return .cancelled }
        if choice.soundtrack == .mine {
            await change(FilmChoice(style: choice.style, soundtrack: .style))
        }
        guard let current = making else { return .cancelled }
        let film = current.shared(
            kind: start.kind == .slideshow ? .slideshow : .memory, title: start.title, subtitle: start.subtitle,
            server: session.account.serverURL)
        shared = film
        let result = await WatchTogether.shared.share(film)
        if result != .started { shared = nil }
        return result
    }

    private func shareAgain() async {
        guard let session, let making else { return }
        let film = making.shared(
            kind: start.kind == .slideshow ? .slideshow : .memory, title: start.title, subtitle: start.subtitle,
            server: session.account.serverURL)
        shared = film
        _ = await WatchTogether.shared.share(film)
    }

    /// Called by the player when the session's film is this one: joins the group's timing.
    func attachToGroup(playing: Bool? = nil) {
        guard let shared, WatchTogether.shared.film?.id == shared.id, loaded else { return }
        WatchTogether.shared.attach(self, film: shared, position: now, playing: playing ?? isPlaying)
    }

    /// The session ended or moved on to another film: the film goes on here alone, paused.
    func leaveGroup() {
        guard shared != nil else { return }
        if WatchTogether.shared.isAttached(self) { WatchTogether.shared.detach(self) }
        if !isGuest { shared = nil }
        stopClock()
    }

    // MARK: Ticks

    /// Runs a few times a second while the film is open: notices the segment on screen, loads what comes next, fixes the
    /// camera moves of segments about to appear, keeps the clips in step, and stops at the end.
    func tick() {
        guard let plan else { return }
        let time = now
        if let index = plan.segmentIndex(at: time), index != segment { segment = index }
        if isPlaying && time >= duration {
            anchorTime = duration
            anchorDate = nil
            ended = true
            syncSound()
        }
        for shot in plan.upcomingShots(from: time, within: 8) where stills[shot] == nil {
            Task { await loadStill(shot) }
        }
        // Pictures far from now are let go.
        let keep = Set(plan.upcomingShots(from: max(0, time - 4), within: 14))
        for shot in stills.keys where !keep.contains(shot) {
            stills[shot] = nil
            originals[shot] = nil
        }
        fixMotions(plan, time: time)
        if !isGuest { loadMaps(plan, time: time) }
        syncVideos(plan, time: time)
    }

    private func fixMotions(_ plan: FilmPlan, time: Double) {
        for (index, segment) in plan.segments.enumerated() where motions[index] == nil {
            guard segment.start <= time + 2.5, segment.end + 2 >= time, let shot = plan.shotIndex(of: segment),
                let item = making?.items[safe: shot]
            else { continue }
            // Wait briefly for the face detection, but never past the moment the segment appears.
            guard focus[shot] != nil || segment.start <= time + 0.4 else { continue }
            let aspect =
                stills[shot].map { Double($0.width) / Double($0.height) }
                ?? (plan.shots[shot].aspectRatio > 0 ? plan.shots[shot].aspectRatio : item.aspectRatio)
            if case .shot = segment.content, plan.shots[shot].isVideo {
                let base = KenBurns.base(imageAspect: aspect, viewportAspect: viewportAspect)
                motions[index] = KenBurns.Motion(from: base.crop, to: base.crop, fits: base.fits)
            } else {
                motions[index] = KenBurns.motion(
                    imageAspect: aspect, viewportAspect: viewportAspect, focus: focus[shot], seed: segment.seed, still: still,
                    closeness: plan.style.zoom)
            }
        }
    }

    /// The camera window of a segment at a progress (before its move is fixed: the picture's base window).
    func motion(for segmentIndex: Int, shot: Int) -> KenBurns.Motion {
        if let fixed = motions[segmentIndex] { return fixed }
        let aspect = stills[shot].map { Double($0.width) / Double($0.height) } ?? making?.items[safe: shot]?.aspectRatio ?? 1
        let base = KenBurns.base(imageAspect: aspect, viewportAspect: viewportAspect)
        return KenBurns.Motion(from: base.crop, to: base.crop, fits: base.fits)
    }

    /// The viewport changed (rotation, window size): moves are worked out again for it.
    func setViewport(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let aspect = size.width / size.height
        guard abs(aspect - viewportAspect) > 0.01 else { return }
        viewportAspect = aspect
        motions = [:]
        maps = [:]
        failedMaps = []
        tick()
    }

    private func loadMaps(_ plan: FilmPlan, time: Double) {
        for (index, segment) in plan.segments.enumerated() where maps[index] == nil && !loadingMaps.contains(index) {
            // A map that could not be made (offline, no map service) is not asked for again: the flight shows its caption.
            guard !failedMaps.contains(index) else { continue }
            guard case .flight(let from, let to, _, _) = segment.content, segment.start <= time + 20, segment.end >= time else {
                continue
            }
            loadingMaps.insert(index)
            let aspect = viewportAspect
            let look = plan.style.look
            Task {
                defer { self.loadingMaps.remove(index) }
                let size = CGSize(width: 1280, height: 1280 / aspect)
                if var picture = await FilmPictures.map(from: from, to: to, size: size) {
                    if let graded = FilmLookFilter.graded(picture.image, look: look) { picture.image = graded }
                    self.maps[index] = picture
                } else {
                    self.failedMaps.insert(index)
                }
            }
        }
    }

    // MARK: Clips

    private func syncVideos(_ plan: FilmPlan, time: Double) {
        guard let making, let services = session?.services else { return }
        var wanted: Set<Int> = []
        for segment in plan.segments where segment.end + 1 >= time && segment.start <= time + 5 {
            guard case .shot(let shot) = segment.content, !unavailable.contains(shot) else { continue }
            switch plan.shots[shot].kind {
            case .video, .livePhoto: wanted.insert(shot)
            case .photo: break
            }
        }
        // Load the clips needed soon.
        for shot in wanted where videos[shot] == nil && !loadingVideos.contains(shot) {
            guard let item = making.items[safe: shot] else { continue }
            let remote = making.remote.contains(shot)
            let source = plan.shots[shot].isVideo ? item : making.motions[item.fileId]
            guard let source else { continue }
            loadingVideos.insert(shot)
            let look = plan.style.look
            Task {
                defer { self.loadingVideos.remove(shot) }
                guard
                    let video = try? await PlayableVideo.load(
                        fileId: source.fileId, etag: remote ? nil : source.etag, name: remote ? "clip.mov" : source.name,
                        mimeType: source.mimeType, originalURL: remote ? nil : services.originalURL(for: source), services: services,
                        offline: session?.offline)
                else { return }
                video.player.isMuted = true
                video.player.actionAtItemEnd = .pause
                if let item = video.player.currentItem, let composition = await FilmLookFilter.videoComposition(for: item.asset, look: look)
                {
                    item.videoComposition = composition
                }
                self.videos[shot] = video
                self.tick()
            }
        }
        // Let go of clips that are over.
        for (shot, video) in videos where !wanted.contains(shot) {
            video.release()
            videos[shot] = nil
        }
        // Keep the clips on screen in step with the film.
        let onScreen = plan.layers(at: time)
        for (shot, video) in videos {
            guard let layer = onScreen.first(where: { plan.shotIndex(of: plan.segments[$0.segment]) == shot && isShot(plan, $0.segment) })
            else {
                video.player.pause()
                continue
            }
            let elapsed = max(0, layer.elapsed)
            var limit = FilmPlan.longestClip
            if case .livePhoto(let motion) = plan.shots[shot].kind { limit = motion }
            video.player.isMuted = muted || hasMusic || !plan.shots[shot].isVideo
            if elapsed >= limit || !isPlaying {
                video.player.pause()
                if !isPlaying { seekIfNeeded(video.player, to: min(elapsed, limit)) }
                continue
            }
            seekIfNeeded(video.player, to: elapsed)
            if video.player.rate == 0 { video.player.play() }
        }
    }

    private func isShot(_ plan: FilmPlan, _ segment: Int) -> Bool {
        if case .shot = plan.segments[segment].content { return true }
        return false
    }

    private func seekIfNeeded(_ player: AVPlayer, to seconds: Double) {
        let current = player.currentTime().seconds
        if !current.isFinite || abs(current - seconds) > 0.35 {
            player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    /// Whether a clip is showing for the shot of `layer` (a Live Photo's motion only while it plays).
    func showsClip(_ shot: Int, elapsed: Double) -> AVPlayer? {
        guard let plan, let video = videos[shot] else { return nil }
        if case .livePhoto(let motion) = plan.shots[shot].kind, elapsed > motion { return nil }
        return video.player
    }
}

extension MemoryFilmModel: WatchTogetherPlayer {
    func groupPlay(at time: Double, delay: Double) { startClock(at: time, delay: delay) }
    func groupPause(at time: Double) { stopClock(at: min(max(0, time), duration)) }
    func groupSeek(to time: Double) { moveClock(to: time) }
}

/// Pictures the film makes itself: the blur behind pictures shown whole, and the map pictures of flights.
enum FilmPictures {
    static let logger = Logger(subsystem: "com.nextcloud.photos", category: "film")

    /// A tiny copy of a picture; drawn enlarged it is a soft blur.
    static func thumbnail(_ image: CGImage, width: Int) -> CGImage? {
        let height = max(1, Int(Double(width) * Double(image.height) / Double(max(1, image.width))))
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// A satellite map with labels of the region between two stops (`MapFlight.region`), and where they are on it. The
    /// map comes from Apple Maps, like the app's Places map; nothing but the region is sent.
    static func map(from: GeoPoint, to: GeoPoint, size: CGSize) async -> FilmMapPicture? {
        let region = MapFlight.region(from: from, to: to, aspect: size.width / size.height)
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: region.centre.latitude, longitude: region.centre.longitude),
            span: MKCoordinateSpan(latitudeDelta: region.latitudeSpan, longitudeDelta: region.longitudeSpan))
        options.size = size
        options.preferredConfiguration = MKHybridMapConfiguration(elevationStyle: .flat)
        var made = try? await MKMapSnapshotter(options: options).start()
        if made == nil {
            // Satellite imagery is not available everywhere (the simulator, some regions): the standard map instead.
            options.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
            do {
                made = try await MKMapSnapshotter(options: options).start()
            } catch {
                logger.error("map flight picture failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard let snapshot = made else { return plain(from: from, to: to, region: region, size: size) }
        #if os(macOS)
            guard let image = snapshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        #else
            guard let image = snapshot.image.cgImage else { return nil }
        #endif
        func normalised(_ point: GeoPoint) -> CGPoint {
            let projected = snapshot.point(for: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude))
            #if os(macOS)
                // AppKit's snapshot points count from the bottom.
                return CGPoint(x: projected.x / size.width, y: 1 - projected.y / size.height)
            #else
                return CGPoint(x: projected.x / size.width, y: projected.y / size.height)
            #endif
        }
        return FilmMapPicture(image: image, from: normalised(from), to: normalised(to))
    }

    /// Without a map (offline, no map service): a night-blue background with a faint grid, the stops placed where they
    /// are in the region, so the flight still shows the way from one to the other.
    static func plain(
        from: GeoPoint, to: GeoPoint, region: (centre: GeoPoint, latitudeSpan: Double, longitudeSpan: Double), size: CGSize
    ) -> FilmMapPicture? {
        let width = Int(size.width)
        let height = Int(size.height)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let gradient = CGGradient(
                colorsSpace: space,
                colors: [CGColor(red: 0.04, green: 0.1, blue: 0.2, alpha: 1), CGColor(red: 0.01, green: 0.03, blue: 0.07, alpha: 1)]
                    as CFArray,
                locations: [0, 1])
        else { return nil }
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: .zero, options: [])
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.07))
        context.setLineWidth(1)
        for step in 1..<12 {
            let x = size.width * Double(step) / 12
            let y = size.height * Double(step) / 12
            context.strokeLineSegments(between: [CGPoint(x: x, y: 0), CGPoint(x: x, y: size.height)])
            context.strokeLineSegments(between: [CGPoint(x: 0, y: y), CGPoint(x: size.width, y: y)])
        }
        guard let image = context.makeImage() else { return nil }
        func place(_ point: GeoPoint) -> CGPoint {
            CGPoint(
                x: 0.5 + (point.longitude - region.centre.longitude) / region.longitudeSpan,
                y: 0.5 - (point.latitude - region.centre.latitude) / region.latitudeSpan)
        }
        return FilmMapPicture(image: image, from: place(from), to: place(to))
    }
}
