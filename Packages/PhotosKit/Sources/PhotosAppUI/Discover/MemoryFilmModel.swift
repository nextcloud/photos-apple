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
/// and the music (SPEC §15.1). Shared by the player and the video export.
struct FilmMaking {
    var plan: FilmPlan
    /// The items of `plan.shots`, in the same order.
    var items: [MediaItem]
    /// Live Photo motion files, by the still's file id.
    var motions: [FileID: MediaItem]
    var music: SlideshowMusic?
    /// The music as a file the app can read (nil for none and for Apple Music songs).
    var musicFile: URL?

    /// Loads the memory's items (archived ones are left out), finds the music's beat on the device and builds the plan.
    static func prepare(_ start: SlideshowStart, services: AccountServices) async -> FilmMaking {
        let map = (try? await services.library.fetchItems(start.ids)) ?? [:]
        let all = start.ids.compactMap { map[$0] }.filter { !$0.isLivePhotoVideo && !$0.isArchived }
        let peers = all.compactMap(\.livePhotoPeer)
        let peerMap = peers.isEmpty ? [:] : ((try? await services.library.fetchItems(peers)) ?? [:])
        var motions: [FileID: MediaItem] = [:]
        for item in all { if let peer = item.livePhotoPeer, let motion = peerMap[peer] { motions[item.fileId] = motion } }

        let music = start.playsMemoryMusic ? await SlideshowMusicStore.current() : nil
        var musicFile: URL?
        if let music { musicFile = await SlideshowMusicStore.readableURL(for: music) }
        var rhythm = FilmRhythm.steady
        if let music, let musicFile {
            rhythm = await FilmRhythmCache.shared.rhythm(for: music, file: musicFile) ?? .steady
        }
        let shots = all.map { item in
            var shot = FilmShot(item)
            // A Live Photo without its motion file is a still.
            if case .livePhoto = shot.kind, motions[item.fileId] == nil { shot.kind = .photo }
            return shot
        }
        let plan = FilmPlan(shots: shots, cover: start.cover, rhythm: rhythm, flights: start.isTrip)
        let byId = Dictionary(all.map { ($0.fileId, $0) }, uniquingKeysWith: { first, _ in first })
        return FilmMaking(
            plan: plan, items: plan.shots.compactMap { byId[$0.fileId] }, motions: motions, music: music, musicFile: musicFile)
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

/// The player's state (SPEC §15.1): the plan, the pictures loaded around the current time with their focus, the clips,
/// the map pictures of the flights, the clock and the music.
@MainActor @Observable final class MemoryFilmModel {
    let start: SlideshowStart
    private(set) var making: FilmMaking?
    var plan: FilmPlan? { making?.plan }
    private(set) var loaded = false

    /// Pictures by shot index, and a tiny copy of each that is drawn enlarged (a blur for free) behind pictures shown whole.
    private(set) var stills: [Int: CGImage] = [:]
    private(set) var fills: [Int: CGImage] = [:]
    private(set) var focus: [Int: FilmCrop] = [:]
    /// The camera move of each segment, fixed when it first comes on screen.
    private(set) var motions: [Int: KenBurns.Motion] = [:]
    /// Map pictures of the flights, by segment index.
    private(set) var maps: [Int: FilmMapPicture] = [:]
    /// Clips (videos, Live Photo motion), by shot index.
    private(set) var videos: [Int: PlayableVideo] = [:]

    /// The clock: the film's time at `anchorDate` (nil while paused).
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
    }

    var isPlaying: Bool { anchorDate != nil }
    var duration: Double { plan?.duration ?? 0 }
    var hasMusic: Bool { making?.music != nil }

    func time(at date: Date) -> Double {
        guard let anchorDate else { return anchorTime }
        return min(duration, anchorTime + date.timeIntervalSince(anchorDate))
    }

    var now: Double { time(at: Date()) }

    // MARK: Loading

    func load(session: SessionModel, autoplay: Bool) async {
        self.session = session
        guard let services = session.services else { return }
        let making = await FilmMaking.prepare(start, services: services)
        self.making = making
        // The opening pictures before the film starts, so it does not open on grey.
        if let plan = making.plan as FilmPlan? {
            let first = plan.upcomingShots(from: 0, within: 6)
            await withTaskGroup(of: Void.self) { group in
                for shot in first.prefix(3) { group.addTask { await self.loadStill(shot) } }
            }
        }
        loaded = true
        tick()
        if autoplay && !making.items.isEmpty { play() }
    }

    func loadStill(_ shot: Int) async {
        guard stills[shot] == nil, !loading.contains(shot), let item = making?.items[safe: shot], let services = session?.services else {
            return
        }
        loading.insert(shot)
        defer { loading.remove(shot) }
        let small = ImagePipeline.Request(
            fileId: item.fileId, etag: item.etag, bucket: 1024, hasPreview: item.hasPreview, mimeType: item.mimeType,
            originalURL: services.originalURL(for: item))
        if let image = await services.images.preview(small) { show(image, for: shot) }
        // Sharper on large screens: the 4096 preview, decoded no larger than 2048.
        var large = small
        large.bucket = 4096
        large.maxPixelSize = 2048
        if let image = await services.images.preview(large) { show(image, for: shot) }
    }

    private func show(_ image: CGImage, for shot: Int) {
        let first = stills[shot] == nil
        stills[shot] = image
        guard first else { return }
        fills[shot] = FilmPictures.thumbnail(image, width: 48)
        Task {
            let found = await Task.detached(priority: .utility) { await FrameFocus.focus(of: image) }.value
            if let found { self.focus[shot] = found }
        }
    }

    // MARK: Clock

    func play() {
        guard let plan, !plan.segments.isEmpty else { return }
        if ended || anchorTime >= duration - 0.05 { anchorTime = 0 }
        ended = false
        anchorDate = Date()
        syncSound()
        tick()
    }

    func pause() {
        anchorTime = now
        anchorDate = nil
        syncSound()
        for video in videos.values { video.player.pause() }
    }

    func togglePlaying() {
        if isPlaying { pause() } else { play() }
    }

    func seek(to time: Double) {
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
            self.music.play(music, at: seeking || !wasMusicPlaying ? now : nil)
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
        }
        fixMotions(plan, time: time)
        loadMaps(plan, time: time)
        syncVideos(plan, time: time)
    }

    private func fixMotions(_ plan: FilmPlan, time: Double) {
        for (index, segment) in plan.segments.enumerated() where motions[index] == nil {
            guard segment.start <= time + 2.5, segment.end + 2 >= time, let shot = plan.shotIndex(of: segment),
                let item = making?.items[safe: shot]
            else { continue }
            // Wait briefly for the face detection, but never past the moment the segment appears.
            guard focus[shot] != nil || segment.start <= time + 0.4 else { continue }
            let aspect = stills[shot].map { Double($0.width) / Double($0.height) } ?? item.aspectRatio
            if case .shot = segment.content, plan.shots[shot].isVideo {
                let base = KenBurns.base(imageAspect: aspect, viewportAspect: viewportAspect)
                motions[index] = KenBurns.Motion(from: base.crop, to: base.crop, fits: base.fits)
            } else {
                motions[index] = KenBurns.motion(
                    imageAspect: aspect, viewportAspect: viewportAspect, focus: focus[shot], seed: segment.seed, still: still)
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
            Task {
                defer { self.loadingMaps.remove(index) }
                let size = CGSize(width: 1280, height: 1280 / aspect)
                if let picture = await FilmPictures.map(from: from, to: to, size: size) {
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
            guard case .shot(let shot) = segment.content else { continue }
            switch plan.shots[shot].kind {
            case .video, .livePhoto: wanted.insert(shot)
            case .photo: break
            }
        }
        // Load the clips needed soon.
        for shot in wanted where videos[shot] == nil && !loadingVideos.contains(shot) {
            guard let item = making.items[safe: shot] else { continue }
            let source = plan.shots[shot].isVideo ? item : making.motions[item.fileId]
            guard let source else { continue }
            loadingVideos.insert(shot)
            Task {
                defer { self.loadingVideos.remove(shot) }
                guard
                    let video = try? await PlayableVideo.load(
                        fileId: source.fileId, etag: source.etag, name: source.name, mimeType: source.mimeType,
                        originalURL: services.originalURL(for: source), services: services, offline: session?.offline)
                else { return }
                video.player.isMuted = true
                video.player.actionAtItemEnd = .pause
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
