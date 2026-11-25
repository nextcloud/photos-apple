// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosDomain
@testable import PhotosModel

/// Memory films (SPEC §15.1): camera moves, the plan cut to a rhythm, map flights.
@Suite struct MemoryFilmTests {
    func shot(_ id: FileID, _ date: Date, kind: FilmShot.Kind = .photo, favorite: Bool = false, at location: GeoPoint? = nil) -> FilmShot {
        FilmShot(fileId: id, kind: kind, aspectRatio: 4 / 3, date: date, isFavorite: favorite, location: location)
    }

    func inside(_ crop: FilmCrop, _ outer: FilmCrop, tolerance: Double = 1e-9) -> Bool {
        crop.x >= outer.x - tolerance && crop.y >= outer.y - tolerance && crop.maxX <= outer.maxX + tolerance
            && crop.maxY <= outer.maxY + tolerance
    }

    // MARK: Ken Burns

    @Test func landscapePhotosFillTheFrameWithTheFilmsShape() {
        let (crop, fits) = KenBurns.base(imageAspect: 4 / 3, viewportAspect: 16 / 9)
        #expect(!fits)
        #expect(crop.width == 1)
        // The window has the frame's shape in pixels.
        #expect(abs(crop.width * 4 / 3 / crop.height - 16 / 9) < 1e-9)
        #expect(abs(crop.midY - 0.5) < 1e-9)
    }

    @Test func portraitPhotosInALandscapeFilmAreShownWholeOverABlur() {
        let (crop, fits) = KenBurns.base(imageAspect: 3 / 4, viewportAspect: 16 / 9)
        #expect(fits)
        #expect(crop.height == 1)
        #expect(crop.width > 1)
        #expect(abs(crop.midX - 0.5) < 1e-9)
        // A portrait photo in a portrait (story) frame fills it.
        #expect(!KenBurns.base(imageAspect: 3 / 4, viewportAspect: 9 / 16).fits)
    }

    @Test func theCameraMovesTowardsTheFacesAndStaysInsideThePicture() {
        let face = FilmCrop(x: 0.7, y: 0.2, width: 0.12, height: 0.16)
        for seed in 0..<6 {
            let motion = KenBurns.motion(imageAspect: 4 / 3, viewportAspect: 16 / 9, focus: face, seed: seed, still: false)
            #expect(inside(motion.from, .full) && inside(motion.to, .full), "seed \(seed)")
            // The close window (start or end) is nearer the face than the middle of the picture.
            let close = motion.from.width < motion.to.width ? motion.from : motion.to
            #expect(close.midX > 0.5, "seed \(seed)")
            // Zooms and pans keep the frame's shape.
            #expect(abs(close.width * 4 / 3 / close.height - 16 / 9) < 1e-6)
        }
        // A zoom in ends on the face, a pull-back starts on it.
        let zoomIn = KenBurns.motion(imageAspect: 4 / 3, viewportAspect: 16 / 9, focus: face, seed: 0, still: false)
        #expect(zoomIn.to.width < zoomIn.from.width)
        let pullBack = KenBurns.motion(imageAspect: 4 / 3, viewportAspect: 16 / 9, focus: face, seed: 1, still: false)
        #expect(pullBack.from.width < pullBack.to.width)
    }

    @Test func aFocusTooLargeToZoomInOnKeepsItInView() {
        let group = FilmCrop(x: 0.05, y: 0.1, width: 0.9, height: 0.7)
        let motion = KenBurns.motion(imageAspect: 4 / 3, viewportAspect: 16 / 9, focus: group, seed: 0, still: false)
        #expect(motion.to.width >= 0.9 - 1e-9)
    }

    @Test func reduceMotionKeepsTheCameraStill() {
        let motion = KenBurns.motion(
            imageAspect: 4 / 3, viewportAspect: 16 / 9, focus: FilmCrop(x: 0.1, y: 0.1, width: 0.1, height: 0.1), seed: 2, still: true)
        #expect(motion.from == motion.to)
        #expect(motion.crop(at: 0.5) == motion.from)
    }

    @Test func theMoveIsEasedAndClamped() {
        let motion = KenBurns.Motion(from: .full, to: FilmCrop(x: 0.5, y: 0.5, width: 0.5, height: 0.5), fits: false)
        #expect(motion.crop(at: -1) == .full)
        #expect(motion.crop(at: 2) == motion.to)
        #expect(abs(motion.crop(at: 0.5).x - 0.25) < 1e-9)
        // Slow at the start.
        #expect(motion.crop(at: 0.1).x < 0.05)
    }

    @Test func facesInRoundPicturesAreSquareAndInsideThePhoto() {
        let face = FilmCrop(x: 0.6, y: 0.1, width: 0.2, height: 0.3)
        for aspect in [4.0 / 3, 3.0 / 4, 1, 3] {
            let square = KenBurns.square(around: face, imageAspect: aspect)
            #expect(abs(square.width * aspect - square.height) < 1e-9, "aspect \(aspect)")
            #expect(inside(square, .full), "aspect \(aspect)")
        }
        let whole = KenBurns.square(around: .full, imageAspect: 2)
        #expect(whole.height == 1 && whole.width == 0.5)
    }

    // MARK: Rhythm and plan

    @Test func shotsLastAWholeNumberOfBeatsAtACalmPace() {
        #expect(FilmRhythm.steady.beatsPerShot == 4)
        #expect(FilmRhythm(beat: 0.5, phase: 0, isMusical: true).beatsPerShot == 8)  // 120 BPM: 4 s
        #expect(FilmRhythm(beat: 60.0 / 90, phase: 0, isMusical: true).beatsPerShot == 4)  // 90 BPM: 2.7 s
        #expect(FilmRhythm(beat: 0.25, phase: 0, isMusical: true).beatsPerShot == 16)
        let rhythm = FilmRhythm(beat: 0.5, phase: 0.2, isMusical: true)
        #expect(abs(rhythm.beat(atOrAfter: 1.0) - 1.2) < 1e-9)
        #expect(abs(rhythm.beat(atOrAfter: 1.2) - 1.2) < 1e-9)
    }

    @Test func aFilmOpensWithItsTitleAndCutsOnTheBeat() {
        let rhythm = FilmRhythm(beat: 0.5, phase: 0.1, isMusical: true)
        let shots = (0..<6).map { shot(FileID($0 + 1), day(2025, 7, 1, 10 + $0)) }
        let plan = FilmPlan(shots: shots, cover: 3, rhythm: rhythm)
        #expect(plan.segments.first?.content == .title)
        #expect(plan.cover == 2)
        // Every cut is on a beat; the first picture dissolves in after the title, the next ones (same day) are cuts.
        for segment in plan.segments.dropFirst() {
            let beats = (segment.start - rhythm.phase) / rhythm.beat
            #expect(abs(beats - beats.rounded()) < 1e-6, "\(segment.start)")
        }
        #expect(plan.segments[1].transition == rhythm.beat)
        #expect(plan.segments[2].transition == 0)
        // Segments follow each other without gaps; the last one stays a little longer for the fade-out.
        for (a, b) in zip(plan.segments, plan.segments.dropFirst()) { #expect(abs(a.end - b.start) < 1e-9) }
        #expect(plan.segments.last!.duration == 8 * 0.5 + FilmPlan.fade)
    }

    @Test func withoutMusicEveryPictureDissolvesInASteadyRhythm() {
        let plan = FilmPlan(shots: (0..<4).map { shot(FileID($0 + 1), day(2025, 7, 1, 10 + $0)) })
        for segment in plan.segments.dropFirst() {
            #expect(segment.transition == 0.8)
        }
        #expect(plan.segments[2].duration == 3.2)
    }

    @Test func favouritesStayLongerAndVideosPlayTheirLength() {
        let shots = [
            shot(1, day(2025, 7, 1, 10), favorite: true), shot(2, day(2025, 7, 1, 11), kind: .video(duration: 5.3)),
            shot(3, day(2025, 7, 1, 12), kind: .video(duration: 60)), shot(4, day(2025, 7, 1, 13), kind: .video(duration: 0.5)),
            shot(5, day(2025, 7, 1, 14), kind: .livePhoto(motion: 3)),
        ]
        let plan = FilmPlan(shots: shots)
        let lengths = Dictionary(
            uniqueKeysWithValues: plan.segments.compactMap { segment -> (Int, Double)? in
                if case .shot(let index) = segment.content { return (index, segment.duration) }
                return nil
            })
        #expect(abs(lengths[0]! - 6.4) < 1e-9)  // 8 beats
        #expect(abs(lengths[1]! - 4.8) < 1e-9)  // 5.3 s → whole beats
        #expect(abs(lengths[2]! - 9.6) < 1e-9)  // at most 10 s
        #expect(abs(lengths[3]! - 1.6) < 1e-9)  // at least 2 s → whole beats
        #expect(lengths[4]! >= 3.2 && lengths[4]! < 3.2 + 1 + FilmPlan.fade + 0.01)
    }

    @Test func longMemoriesKeepTheirFavouritesAndASpreadOfTheRest() {
        let shots = (0..<200).map { shot(FileID($0), day(2025, 1, 1).addingTimeInterval(Double($0) * 3600), favorite: $0 % 50 == 7) }
        let chosen = FilmPlan.select(shots, limit: 60)
        #expect(chosen.count == 60)
        #expect(Set(chosen.filter(\.isFavorite).map(\.fileId)) == [7, 57, 107, 157])
        #expect(chosen == chosen.sorted { $0.date < $1.date })
        #expect(chosen.first!.fileId == 0)
        #expect(chosen.last!.fileId > 180)
    }

    @Test func layersCrossFadeAndTheFilmFadesInAndOut() {
        let plan = FilmPlan(shots: (0..<3).map { shot(FileID($0 + 1), day(2025, 7, 1, 10 + $0)) })
        let second = plan.segments[2]
        let during = plan.layers(at: second.start + second.transition / 2)
        #expect(during.map(\.segment) == [1, 2])
        #expect(abs(during[1].opacity - 0.5) < 1e-9)
        #expect(during[0].opacity == 1)
        let after = plan.layers(at: second.start + second.transition + 0.1)
        #expect(after.map(\.segment) == [2])
        // The outgoing picture keeps moving until it is gone: its progress counts the next cross-fade.
        let outgoing = during[0]
        #expect(outgoing.progress > 0.5 && outgoing.progress < 1)
        #expect(plan.brightness(at: 0) == 0)
        #expect(plan.brightness(at: 1) == 1)
        #expect(plan.brightness(at: plan.duration) == 0)
    }

    @Test func skipAndBackMoveBetweenSegments() {
        let plan = FilmPlan(shots: (0..<3).map { shot(FileID($0 + 1), day(2025, 7, 1, 10 + $0)) })
        let first = plan.segments[1]
        #expect(plan.nextStart(after: 0) == first.start)
        #expect(plan.previousStart(before: first.start + 2) == first.start)
        #expect(plan.previousStart(before: first.start + 0.5) == 0)
        #expect(plan.nextStart(after: plan.duration - 0.1) == nil)
        #expect(plan.segmentIndex(at: -1) == 0)
        #expect(plan.upcomingShots(from: 0, within: 1) == [plan.cover!])
    }

    @Test func tripsFlyBetweenDistantStopsOnly() {
        let lisbon = GeoPoint(latitude: 38.72, longitude: -9.14)
        let sintra = GeoPoint(latitude: 38.80, longitude: -9.38)  // 22 km: the same stop
        let porto = GeoPoint(latitude: 41.15, longitude: -8.61)
        var shots = (0..<4).map { shot(FileID($0 + 1), day(2025, 7, 1, 8 + $0), at: lisbon) }
        shots.append(shot(5, day(2025, 7, 1, 13), at: sintra))
        shots += (0..<3).map { shot(FileID($0 + 6), day(2025, 7, 3, 10 + $0), at: porto) }
        let plan = FilmPlan(shots: shots, rhythm: .steady, flights: true)
        let flights = plan.segments.filter {
            if case .flight = $0.content { return true }
            return false
        }
        #expect(flights.count == 1)
        guard case .flight(let from, let to, _, _) = flights[0].content else { return }
        #expect(TravelRoute.distance(from, lisbon) < 25)
        #expect(TravelRoute.distance(to, porto) < 1)
        // The flight comes right before the first photo in Porto.
        let index = plan.segments.firstIndex(of: flights[0])!
        #expect(plan.segments[index + 1].content == .shot(5))
        #expect(FilmPlan(shots: shots, rhythm: .steady, flights: false).segments.count == plan.segments.count - 1)
    }

    @Test func cardFilmsShowEachCardForAboutAPicture() {
        let plan = FilmPlan(cards: 5)
        #expect(plan.segments.count == 5)
        #expect(plan.segments.map(\.content) == (0..<5).map { .card($0) })
        #expect(plan.segments[0].transition == 0)
        #expect(abs(plan.duration - (5 * 3.2 + FilmPlan.fade)) < 1e-9)
    }

    @Test func filmShotsComeFromIndexItems() {
        var video = MediaItem(fileId: 1, path: "/v.mov", mimeType: "video/quicktime", width: 1920, height: 1080, duration: 7)
        #expect(FilmShot(video).kind == .video(duration: 7))
        video.mimeType = "video/webm"
        #expect(FilmShot(video).kind == .photo)
        let live = MediaItem(fileId: 2, path: "/l.heic", mimeType: "image/heic", latitude: 0, longitude: 0, livePhotoPeer: 3)
        #expect(FilmShot(live).kind == .livePhoto(motion: FilmPlan.liveMotion))
        #expect(FilmShot(live).location == nil)
    }

    // MARK: Map flight

    @Test func theFlightStartsOverTheFirstStopAndEndsOverTheSecond() {
        let from = (x: 0.2, y: 0.6)
        let to = (x: 0.8, y: 0.4)
        let start = MapFlight.camera(at: 0, from: from, to: to, still: false)
        let middle = MapFlight.camera(at: 0.5, from: from, to: to, still: false)
        let end = MapFlight.camera(at: 1, from: from, to: to, still: false)
        #expect(start.width < 1 && abs(start.midX - 0.2) < 0.1)
        #expect(middle == .full)
        #expect(abs(end.midX - 0.8) < 0.1)
        #expect(MapFlight.camera(at: 0.3, from: from, to: to, still: true) == .full)
        #expect(MapFlight.travelled(at: 0) == 0 && MapFlight.travelled(at: 1) == 1)
        let head = MapFlight.point(at: 1, from: from, to: to)
        #expect(abs(head.x - 0.8) < 1e-9 && abs(head.y - 0.4) < 1e-9)
    }

    @Test func theFlightsRegionHasTheFramesShapeAndRoomAroundTheStops() {
        let region = MapFlight.region(
            from: GeoPoint(latitude: 38.72, longitude: -9.14), to: GeoPoint(latitude: 41.15, longitude: -8.61), aspect: 16 / 9)
        #expect(region.latitudeSpan >= (41.15 - 38.72) * 1.8 - 1e-9)
        let squeeze = cos(region.centre.latitude * .pi / 180)
        #expect(abs(region.longitudeSpan * squeeze / region.latitudeSpan - 16 / 9) < 1e-6)
    }
}
