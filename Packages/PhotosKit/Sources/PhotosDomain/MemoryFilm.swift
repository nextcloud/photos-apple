// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// The beat a memory film is cut to (SPEC §15.1): the music's tempo and the time of its first beat, or a steady rhythm
/// when no music is chosen or no clear beat was found.
public struct FilmRhythm: Hashable, Sendable {
    /// Seconds per beat.
    public var beat: Double
    /// The time of a beat (film time; the music starts with the film).
    public var phase: Double
    /// Taken from the music: cuts land on its beats. Otherwise the film cross-fades in a calm steady rhythm.
    public var isMusical: Bool

    public init(beat: Double, phase: Double, isMusical: Bool) {
        self.beat = beat
        self.phase = phase
        self.isMusical = isMusical
    }

    /// 75 beats a minute, four to a picture: 3.2 s per picture.
    public static let steady = FilmRhythm(beat: 0.8, phase: 0, isMusical: false)

    /// Beats per minute.
    public var tempo: Double { 60 / beat }

    /// How long a picture is shown, in beats: a whole number of beats (2, 4, 8 or 16) closest to about 3.4 s, so cuts
    /// fall on the beat and the film keeps a calm pace whatever the tempo.
    public var beatsPerShot: Int {
        [2, 4, 8, 16].min { abs(Double($0) * beat - 3.4) < abs(Double($1) * beat - 3.4) }!
    }

    /// The first beat at or after `time`.
    public func beat(atOrAfter time: Double) -> Double {
        guard beat > 0 else { return time }
        let count = ((time - phase) / beat).rounded(.up)
        return phase + count * beat
    }
}

/// A picture or clip of a memory film.
public struct FilmShot: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case photo
        /// A Live Photo: its motion (this long, seconds) plays at the start of its shot.
        case livePhoto(motion: Double)
        /// A video, played inline for up to `FilmPlan.longestClip` seconds.
        case video(duration: Double)
    }

    public var fileId: FileID
    public var kind: Kind
    /// Width / height of the picture.
    public var aspectRatio: Double
    public var date: Date
    public var isFavorite: Bool
    public var location: GeoPoint?
    public var place: String?

    public init(
        fileId: FileID, kind: Kind = .photo, aspectRatio: Double = 4 / 3, date: Date, isFavorite: Bool = false,
        location: GeoPoint? = nil, place: String? = nil
    ) {
        self.fileId = fileId
        self.kind = kind
        self.aspectRatio = aspectRatio
        self.date = date
        self.isFavorite = isFavorite
        self.location = location
        self.place = place
    }

    public init(_ item: MediaItem) {
        let kind: Kind
        switch item.kind {
        case .video where !MimeTypes.unplayableVideos.contains(item.mimeType):
            kind = .video(duration: item.duration ?? FilmPlan.longestClip)
        case .video: kind = .photo
        case .image: kind = item.isLivePhoto ? .livePhoto(motion: FilmPlan.liveMotion) : .photo
        }
        self.init(
            fileId: item.fileId, kind: kind, aspectRatio: item.aspectRatio, date: item.timestamp, isFavorite: item.isFavorite,
            location: GeoPoint(latitude: item.latitude, longitude: item.longitude), place: item.place)
    }

    public var isVideo: Bool {
        if case .video = kind { return true }
        return false
    }
}

/// One part of a film: the title, a picture or clip, a map flight between two stops of a trip, or a card (year in
/// review).
public struct FilmSegment: Hashable, Sendable {
    public enum Content: Hashable, Sendable {
        /// The title over the cover picture (`FilmPlan.cover`).
        case title
        /// `FilmPlan.shots[index]`.
        case shot(Int)
        /// A flight over the map from one stop of a trip to the next.
        case flight(from: GeoPoint, to: GeoPoint, fromName: String?, toName: String?)
        /// The year in review's card at this index.
        case card(Int)
    }

    public var content: Content
    public var start: Double
    public var duration: Double
    /// The segment fades in over the previous one for this long (0: a cut on the beat).
    public var transition: Double
    /// Varies the camera move from segment to segment.
    public var seed: Int

    public var end: Double { start + duration }
}

/// What is on screen at one moment of a film.
public struct FilmLayer: Hashable, Sendable {
    public var segment: Int
    /// 0…1; the incoming segment of a cross-fade is drawn over the outgoing one.
    public var opacity: Double
    /// 0…1 through the segment's time on screen (including the cross-fades at both ends): drives the camera move.
    public var progress: Double
    /// Seconds since the segment started (a clip's playback position).
    public var elapsed: Double
}

/// A memory film's timeline (SPEC §15.1): which picture is on screen when, cut to the music's beat or a steady rhythm,
/// with a title first and, for trips, map flights between the stops. Pure timing: the player and the video export both
/// render it with `layers(at:)`, so they show the same film.
public struct FilmPlan: Hashable, Sendable {
    public var shots: [FilmShot]
    public var segments: [FilmSegment]
    public var rhythm: FilmRhythm
    /// The picture under the title.
    public var cover: Int?

    /// At most this many pictures: a film is a highlight, not the whole memory.
    public static let shotLimit = 60
    /// Clips play at most this long.
    public static let longestClip = 10.0
    /// Clips play at least this long (shorter ones play to their end and hold their last frame).
    public static let shortestClip = 2.0
    /// A Live Photo's motion: about three seconds.
    public static let liveMotion = 3.0
    /// At most this many map flights in a film.
    public static let flightLimit = 6
    /// Stops closer than this are not worth a flight.
    public static let flightMinimumKilometres = 30.0
    /// The film fades in from black and out to black at the end.
    public static let fade = 1.2

    public var duration: Double { segments.last?.end ?? 0 }

    /// Builds the film of a memory's pictures (in the order they were taken). `flights`: trips fly over the map between
    /// their stops.
    public init(shots allShots: [FilmShot], cover: FileID? = nil, rhythm: FilmRhythm = .steady, flights: Bool = false) {
        self.rhythm = rhythm
        let shots = Self.select(allShots, limit: Self.shotLimit)
        self.shots = shots
        self.cover = cover.flatMap { id in shots.firstIndex { $0.fileId == id } } ?? (shots.isEmpty ? nil : shots.count / 2)
        segments = []
        guard !shots.isEmpty else { return }

        let beat = rhythm.beat
        let shotBeats = rhythm.beatsPerShot
        let crossfade = rhythm.isMusical ? beat : 0.8
        // The first cut lands on a beat, after a title that lasts about one and a half pictures.
        var time = rhythm.beat(atOrAfter: Double(shotBeats) * beat * 1.5)
        segments.append(FilmSegment(content: .title, start: 0, duration: time, transition: 0, seed: 0))

        let stopOf = flights ? Self.stopIndexes(shots) : [:]
        var flightsLeft = Self.flightLimit
        for (index, shot) in shots.enumerated() {
            let previous = index > 0 ? shots[index - 1] : nil
            // A new day or a new stop is a new chapter: it dissolves in; within a chapter, music cuts on the beat.
            let newChapter = previous.map { !Calendar.current.isDate($0.date, inSameDayAs: shot.date) } ?? true
            if flightsLeft > 0, let previous, let from = stopOf[index - 1], let to = stopOf[index], from.stop != to.stop,
                TravelRoute.distance(from.centre, to.centre) >= Self.flightMinimumKilometres
            {
                flightsLeft -= 1
                let length = Double(shotBeats) * beat
                segments.append(
                    FilmSegment(
                        content: .flight(from: from.centre, to: to.centre, fromName: previous.place, toName: shot.place),
                        start: time, duration: length, transition: crossfade, seed: segments.count))
                time += length
            }
            var beats = shotBeats
            if shot.isFavorite && Double(beats * 2) * beat <= 7 { beats *= 2 }
            var length = Double(beats) * beat
            switch shot.kind {
            case .video(let clip):
                // The clip's length, in whole beats, between the shortest and longest clip.
                let wanted = min(max(clip, Self.shortestClip), Self.longestClip)
                length = max(beat, (wanted / beat).rounded(.down) * beat)
            case .livePhoto(let motion):
                length = max(length, (motion / beat).rounded(.up) * beat + beat)
            case .photo: break
            }
            let transition = !rhythm.isMusical || newChapter || index == 0 ? crossfade : 0
            segments.append(FilmSegment(content: .shot(index), start: time, duration: length, transition: transition, seed: index))
            time += length
        }
        // The last picture stays a little longer while the film fades out.
        segments[segments.count - 1].duration += Self.fade
    }

    /// A film of prepared cards (the year in review): each card about one picture long, cross-faded.
    public init(cards count: Int, rhythm: FilmRhythm = .steady) {
        self.rhythm = rhythm
        shots = []
        cover = nil
        segments = []
        let length = Double(rhythm.beatsPerShot) * rhythm.beat
        let crossfade = rhythm.isMusical ? rhythm.beat : 0.8
        var time = 0.0
        for index in 0..<count {
            segments.append(
                FilmSegment(content: .card(index), start: time, duration: length, transition: index == 0 ? 0 : crossfade, seed: index))
            time += length
        }
        if !segments.isEmpty { segments[segments.count - 1].duration += Self.fade }
    }

    /// The pictures of a long memory: favourites first, then evenly through the rest, in the order they were taken.
    public static func select(_ shots: [FilmShot], limit: Int) -> [FilmShot] {
        let sorted = shots.sorted { $0.date < $1.date }
        guard sorted.count > limit else { return sorted }
        var chosen = Set(sorted.indices.filter { sorted[$0].isFavorite }.prefix(limit / 2))
        let rest = sorted.indices.filter { !chosen.contains($0) }
        let wanted = limit - chosen.count
        for step in 0..<wanted {
            chosen.insert(rest[step * rest.count / wanted])
        }
        return chosen.sorted().map { sorted[$0] }
    }

    struct StopRef {
        var stop: Int
        var centre: GeoPoint
    }

    /// The stop of each located picture.
    static func stopIndexes(_ shots: [FilmShot]) -> [Int: StopRef] {
        var located: [Int] = []
        var points: [TravelRoute.Point] = []
        for (index, shot) in shots.enumerated() {
            if let location = shot.location {
                located.append(index)
                points.append(TravelRoute.Point(location: location, date: shot.date, name: shot.place))
            }
        }
        var result: [Int: StopRef] = [:]
        for (number, stop) in TravelRoute.stops(points).enumerated() {
            for member in stop.members { result[located[member]] = StopRef(stop: number, centre: stop.centre) }
        }
        return result
    }

    // MARK: Playback

    /// The segment on screen at `time` (the incoming one during a cross-fade).
    public func segmentIndex(at time: Double) -> Int? {
        guard !segments.isEmpty else { return nil }
        if time <= 0 { return 0 }
        return segments.lastIndex { $0.start <= time } ?? 0
    }

    /// The layers to draw at `time`, bottom first: the outgoing segment under a fading-in one, or one segment.
    public func layers(at time: Double) -> [FilmLayer] {
        guard let index = segmentIndex(at: time) else { return [] }
        let current = segments[index]
        var result: [FilmLayer] = []
        let intoTransition = time - current.start
        if index > 0, current.transition > 0, intoTransition < current.transition {
            result.append(layer(index - 1, at: time, opacity: 1))
            result.append(layer(index, at: time, opacity: max(0, intoTransition / current.transition)))
        } else {
            result.append(layer(index, at: time, opacity: 1))
        }
        return result
    }

    /// How bright the film is at `time`: it fades in from black at the start and out to black at the end.
    public func brightness(at time: Double) -> Double {
        let total = duration
        guard total > 0 else { return 0 }
        let fadeIn = min(1, max(0, time / 0.6))
        let fadeOut = min(1, max(0, (total - time) / Self.fade))
        return min(fadeIn, fadeOut)
    }

    func layer(_ index: Int, at time: Double, opacity: Double) -> FilmLayer {
        let segment = segments[index]
        // On screen from its start to the end of the next segment's cross-fade.
        let next = index + 1 < segments.count ? segments[index + 1].transition : 0
        let visible = segment.duration + next
        let elapsed = time - segment.start
        return FilmLayer(segment: index, opacity: opacity, progress: visible > 0 ? min(1, max(0, elapsed / visible)) : 0, elapsed: elapsed)
    }

    /// The start of the segment after the one at `time` (Skip), or nil at the last one.
    public func nextStart(after time: Double) -> Double? {
        guard let index = segmentIndex(at: time), index + 1 < segments.count else { return nil }
        return segments[index + 1].start
    }

    /// Back: the start of the segment on screen, or of the one before when it has just begun (as in a music player).
    public func previousStart(before time: Double) -> Double {
        guard let index = segmentIndex(at: time) else { return 0 }
        if time - segments[index].start > 1 || index == 0 { return segments[index].start }
        return segments[index - 1].start
    }

    /// The pictures needed soon after `time`, for loading ahead.
    public func upcomingShots(from time: Double, within seconds: Double) -> [Int] {
        var result: [Int] = []
        for segment in segments where segment.end >= time && segment.start <= time + seconds {
            switch segment.content {
            case .shot(let index): result.append(index)
            case .title: if let cover { result.append(cover) }
            case .flight, .card: break
            }
        }
        return result
    }

    /// The shot a segment shows (the cover for the title).
    public func shotIndex(of segment: FilmSegment) -> Int? {
        switch segment.content {
        case .shot(let index): index
        case .title: cover
        case .flight, .card: nil
        }
    }
}

/// The camera and the plane of a map flight (SPEC §15.1), over a map picture that shows both stops with room around them
/// (`region`). The camera starts close over the first stop, pulls back until both are in view, and comes down over the
/// second; the route is drawn as an arc behind the plane. Positions are in the map picture's coordinates (0…1, top left).
public enum MapFlight {
    /// How close the camera is over a stop, compared with the whole map.
    public static let closeZoom = 1.8

    /// The map region (centre and span in degrees) a flight's picture shows: both stops with a margin, never smaller than
    /// a city, with the span's aspect matching the film's frame (longitude span in degrees is wider per degree near the
    /// equator; good enough for the short spans of a trip, and the picture is made by MapKit for exactly this region).
    public static func region(from: GeoPoint, to: GeoPoint, aspect: Double) -> (
        centre: GeoPoint, latitudeSpan: Double, longitudeSpan: Double
    ) {
        let centre = GeoPoint(latitude: (from.latitude + to.latitude) / 2, longitude: (from.longitude + to.longitude) / 2)
        let squeeze = max(0.2, cos(centre.latitude * .pi / 180))
        var latitudeSpan = max(abs(from.latitude - to.latitude) * 1.8, 0.3)
        var longitudeSpan = max(abs(from.longitude - to.longitude) * 1.8, 0.3)
        // Make the region's shape on screen match the frame.
        if longitudeSpan * squeeze / latitudeSpan < aspect {
            longitudeSpan = latitudeSpan * aspect / squeeze
        } else {
            latitudeSpan = longitudeSpan * squeeze / aspect
        }
        return (centre, min(latitudeSpan, 170), min(longitudeSpan, 350))
    }

    /// The camera's window at `progress` (0…1).
    public static func camera(at progress: Double, from: (x: Double, y: Double), to: (x: Double, y: Double), still: Bool) -> FilmCrop {
        let whole = FilmCrop.full
        guard !still else { return whole }
        let start = KenBurns.window(in: whole, zoom: closeZoom, around: FilmCrop(x: from.x, y: from.y, width: 0, height: 0))
        let end = KenBurns.window(in: whole, zoom: closeZoom, around: FilmCrop(x: to.x, y: to.y, width: 0, height: 0))
        let value = min(max(progress, 0), 1)
        if value < 0.5 { return start.interpolated(to: whole, KenBurns.ease(value * 2)) }
        return whole.interpolated(to: end, KenBurns.ease((value - 0.5) * 2))
    }

    /// How far along the route the plane is at `progress`: it waits a moment at both ends.
    public static func travelled(at progress: Double) -> Double {
        KenBurns.ease(min(max((progress - 0.15) / 0.7, 0), 1))
    }

    /// A point of the route's arc (`amount` 0…1): a quadratic curve bowing to the side by a fifth of its length.
    public static func point(at amount: Double, from: (x: Double, y: Double), to: (x: Double, y: Double)) -> (x: Double, y: Double) {
        let control = (x: (from.x + to.x) / 2 - (to.y - from.y) * 0.2, y: (from.y + to.y) / 2 + (to.x - from.x) * 0.2 - 0.04)
        let t = min(max(amount, 0), 1)
        let a = (1 - t) * (1 - t)
        let b = 2 * (1 - t) * t
        let c = t * t
        return (a * from.x + b * control.x + c * to.x, a * from.y + b * control.y + c * to.y)
    }
}
