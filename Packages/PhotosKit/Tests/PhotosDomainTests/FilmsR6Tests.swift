// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosDomain
@testable import PhotosModel

/// Round 6 films (SPEC §16.6): film styles, their looks and scores, through the years, and watching together.
@Suite struct FilmStyleTests {
    func shots(_ count: Int, favourite: Int? = nil, days: Int = 1) -> [FilmShot] {
        (0..<count).map { (index: Int) -> FilmShot in
            let seconds: Double = 1_700_000_000 + Double(index % days) * 86_400 + Double(index) * 60
            return FilmShot(fileId: FileID(index + 1), date: Date(timeIntervalSince1970: seconds), isFavorite: index == favourite)
        }
    }

    func shotLengths(_ plan: FilmPlan) -> [Double] {
        plan.segments.compactMap { segment in
            if case .shot = segment.content { return segment.duration }
            return nil
        }
    }

    @Test func cinematicIsRoundFivesFilm() {
        let old = FilmPlan(shots: shots(5))
        let cinematic = FilmPlan(shots: shots(5), style: .cinematic)
        #expect(old.segments == cinematic.segments)
        #expect(FilmStyle.cinematic.steadyRhythm == .steady)
        #expect(FilmRhythm.steady.beatsPerShot(target: FilmStyle.cinematic.shotSeconds) == FilmRhythm.steady.beatsPerShot)
    }

    @Test func upbeatCutsFasterAndCalmSlowerThanCinematic() {
        func averageShot(_ style: FilmStyle) -> Double {
            let lengths = shotLengths(FilmPlan(shots: shots(8), rhythm: style.steadyRhythm, style: style)).dropLast()
            return lengths.reduce(0, +) / Double(lengths.count)
        }
        #expect(averageShot(.upbeat) < averageShot(.cinematic) * 0.7)
        #expect(averageShot(.calm) > averageShot(.cinematic) * 1.3)
        // With music of the same tempo the pacing differs too (only the pacing, for the user's own music).
        let music = FilmRhythm(beat: 0.5, phase: 0, isMusical: true)
        let upbeat = shotLengths(FilmPlan(shots: shots(4), rhythm: music, style: .upbeat)).first!
        let calm = shotLengths(FilmPlan(shots: shots(4), rhythm: music, style: .calm)).first!
        #expect(upbeat < calm)
        #expect((upbeat / 0.5).rounded() == upbeat / 0.5)
    }

    @Test func calmDissolvesEveryPictureEvenToMusicAndUpbeatCutsOnTheBeat() {
        let music = FilmRhythm(beat: 0.6, phase: 0, isMusical: true)
        let calm = FilmPlan(shots: shots(5), rhythm: music, style: .calm)
        let upbeat = FilmPlan(shots: shots(5), rhythm: music, style: .upbeat)
        let calmFades = calm.segments.dropFirst(2).map(\.transition)
        let upbeatFades = upbeat.segments.dropFirst(2).map(\.transition)
        #expect(calmFades.allSatisfy { $0 > 1 })
        #expect(upbeatFades.allSatisfy { $0 == 0 })
    }

    @Test func favouritesStayLongerExceptInTheCalmStyle() {
        let plain = shotLengths(FilmPlan(shots: shots(3, favourite: 1), style: .cinematic))
        #expect(plain[1] > plain[0])
        let calm = shotLengths(FilmPlan(shots: shots(3, favourite: 1), rhythm: FilmStyle.calm.steadyRhythm, style: .calm))
        #expect(calm[1] == calm[0])
    }

    @Test func aSlideshowKeepsAllItsPhotosInItsOrder() {
        let reversed = Array(shots(80).reversed())
        let plan = FilmPlan(shots: reversed, style: .cinematic, keepsOrder: true)
        #expect(plan.shots.map(\.fileId) == reversed.map(\.fileId))
        #expect(FilmPlan(shots: reversed).shots.count == FilmPlan.shotLimit)
    }

    @Test func eachStylesScoreGivesItsPacing() {
        for style in FilmStyle.allCases {
            let score = FilmScore(mood: style.score)
            let seconds = Double(score.rhythm.beatsPerShot(target: style.shotSeconds)) * score.beat
            #expect(abs(seconds - style.shotSeconds) < 0.8, "\(style) \(seconds)")
        }
    }

    // MARK: Looks

    @Test func theCinematicLookChangesNothing() {
        let look = FilmStyle.cinematic.look
        #expect(!look.gradesColour)
        #expect(!look.isAnimated)
        let colour = look.graded((0.2, 0.5, 0.9))
        #expect(abs(colour.0 - 0.2) < 1e-9 && abs(colour.1 - 0.5) < 1e-9 && abs(colour.2 - 0.9) < 1e-9)
    }

    @Test func blackAndWhiteHasNoColourAndSuperEightIsWarm() {
        let grey = FilmStyle.blackAndWhite.look.graded((0.8, 0.3, 0.1))
        #expect(abs(grey.0 - grey.1) < 1e-9 && abs(grey.1 - grey.2) < 1e-9)
        let warm = FilmStyle.superEight.look.graded((0.5, 0.5, 0.5))
        #expect(warm.0 > warm.2)
        // Faded blacks: black is lifted.
        #expect(FilmStyle.superEight.look.graded((0, 0, 0)).1 > 0.02)
    }

    @Test func theHomeMovieGateJittersAndFlickersTheSameEverywhere() {
        let look = FilmStyle.superEight.look
        var offsets: Set<String> = []
        for frame in 0..<60 {
            let time = Double(frame) / 30
            let jitter = look.jitterOffset(at: time)
            #expect(jitter == look.jitterOffset(at: time))
            #expect(abs(jitter.x) <= look.jitter && abs(jitter.y) <= look.jitter * 2.5)
            // The frame is drawn large enough that a jump never shows an edge.
            #expect((look.overscan - 1) / 2 >= abs(jitter.y))
            let light = look.light(at: time)
            #expect(light <= 1 && light >= 1 - look.flicker)
            offsets.insert("\(jitter.x),\(jitter.y)")
        }
        // 18 film frames a second: two video frames often show the same film frame, but it moves.
        #expect(offsets.count > 20 && offsets.count <= 36)
        #expect(FilmStyle.calm.look.jitterOffset(at: 1.3) == (0, 0) as (Double, Double))
    }

    // MARK: Score

    @Test func scoresLoopInsideTheirLengthInTune() {
        for mood in FilmScore.Mood.allCases {
            let score = FilmScore(mood: mood)
            #expect(score.length > 20 && score.length < 80, "\(mood)")
            #expect(!score.notes.isEmpty)
            for note in score.notes {
                #expect(note.start >= 0 && note.start < score.length)
                #expect(note.length > 0)
                #expect(note.velocity > 0 && note.velocity <= 1)
                if note.instrument != .kick && note.instrument != .hat && note.instrument != .shaker {
                    #expect((24...96).contains(note.pitch))
                }
            }
            // The first beat is the film's: cuts land on the music.
            #expect(score.rhythm.isMusical && score.rhythm.phase == 0)
            #expect(score.notes.contains { $0.start == 0 })
        }
        #expect(FilmScore(mood: .upbeat) == FilmScore(mood: .upbeat))
        #expect(abs(FilmScore.frequency(69) - 440) < 1e-9)
    }
}

@Suite struct ThroughTheYearsTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    func date(_ year: Int, _ month: Int, _ day: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    func sample(_ id: FileID, _ date: Date, face: Double = 0.2, favourite: Bool = false, x: Double = 0.4) -> ThroughTheYears.Sample {
        ThroughTheYears.Sample(
            fileId: id, date: date, face: FilmCrop(x: x, y: 0.3, width: face, height: face * 1.3), isFavorite: favourite, aspectRatio: 1)
    }

    @Test func theYearsAreDividedSoTheFilmHasAGoodLength() {
        let short = [sample(1, date(2020, 1)), sample(2, date(2023, 6))]
        #expect(ThroughTheYears.period(spanning: short, calendar: calendar) == .month)
        let medium = [sample(1, date(2014, 1)), sample(2, date(2023, 6))]
        #expect(ThroughTheYears.period(spanning: medium, calendar: calendar) == .season)
        let long = [sample(1, date(1990, 1)), sample(2, date(2023, 6))]
        #expect(ThroughTheYears.period(spanning: long, calendar: calendar) == .year)
        #expect(ThroughTheYears.periodStart(of: date(2021, 8, 20), period: .season, calendar: calendar) == date(2021, 7, 1))
        #expect(ThroughTheYears.periodStart(of: date(2021, 8, 20), period: .year, calendar: calendar) == date(2021, 1, 1))
    }

    @Test func eachPeriodGetsItsClearestFaceOldestFirst() {
        let samples = [
            sample(1, date(2021, 3, 1), face: 0.05),
            sample(2, date(2021, 3, 5), face: 0.25),
            sample(3, date(2021, 3, 9), face: 0.2, x: 0.0),
            sample(4, date(2021, 1, 9), face: 0.1),
            sample(5, date(2021, 2, 9), face: 0.1),
            sample(6, date(2021, 2, 10), face: 0.1, favourite: true),
        ]
        let picks = ThroughTheYears.pick(samples, period: .month, calendar: calendar)
        #expect(picks.map(\.sample.fileId) == [4, 6, 2])
        #expect(picks.map(\.period) == [date(2021, 1, 1), date(2021, 2, 1), date(2021, 3, 1)])
        // The runners-up of each period, best first, for faces that cannot be lined up.
        let candidates = ThroughTheYears.candidates(samples, period: .month, calendar: calendar)
        #expect(candidates.map { $0.map(\.sample.fileId) } == [[4], [6, 5], [2, 3, 1]])
        // A photo without a face box is a last resort.
        #expect(ThroughTheYears.score(ThroughTheYears.Sample(fileId: 9, date: date(2021, 1), face: nil)) == 0)
    }

    @Test func longLivesAreThinnedEvenlyKeepingFirstAndLast() {
        let samples = (0..<300).map { sample(FileID($0), calendar.date(byAdding: .month, value: $0, to: date(2000, 1))!) }
        let picks = ThroughTheYears.pick(samples, period: .month, limit: 50, calendar: calendar)
        #expect(picks.count == 50)
        #expect(picks.first?.sample.fileId == 0 && picks.last?.sample.fileId == 299)
        #expect(zip(picks, picks.dropFirst()).allSatisfy { $0.period < $1.period })
    }

    @Test func theEyesLandLevelOnTheEyeLineAtTheSameDistance() {
        // A tilted face: the right eye lower.
        let eyes = ThroughTheYears.Eyes(
            left: ThroughTheYears.Point(x: 300, y: 400), right: ThroughTheYears.Point(x: 400, y: 450))
        let transform = ThroughTheYears.alignment(eyes, width: 1920, height: 1080)
        let left = transform.apply(eyes.left)
        let right = transform.apply(eyes.right)
        #expect(abs(left.y - right.y) < 1e-6)
        #expect(abs(hypot(right.x - left.x, right.y - left.y) - ThroughTheYears.eyeDistance * 1080) < 1e-6)
        #expect(abs((left.x + right.x) / 2 - 960) < 1e-6)
        #expect(abs((left.y + right.y) / 2 - ThroughTheYears.eyeLine.y * 1080) < 1e-6)
        #expect(left.x < right.x)
    }

    @Test func eyesAreLeftAndRightAsSeenWhateverTheDetectorCallsThem() {
        let eyes = ThroughTheYears.Eyes(left: ThroughTheYears.Point(x: 500, y: 10), right: ThroughTheYears.Point(x: 100, y: 12))
        #expect(eyes.left.x == 100 && eyes.right.x == 500)
        let estimated = ThroughTheYears.Eyes.estimated(
            in: FilmCrop(x: 0.25, y: 0.25, width: 0.5, height: 0.5), imageWidth: 1000, imageHeight: 800)
        #expect(estimated.left.y == estimated.right.y)
        #expect(estimated.middle.x == 500)
    }

    @Test func coverageTellsHowMuchOfTheFrameThePhotoFills() {
        let centred = ThroughTheYears.Eyes(left: ThroughTheYears.Point(x: 450, y: 420), right: ThroughTheYears.Point(x: 550, y: 420))
        let full = ThroughTheYears.coverage(
            ThroughTheYears.alignment(centred, width: 500, height: 500), imageWidth: 1000, imageHeight: 1000, width: 500, height: 500)
        #expect(full == 1)
        let edge = ThroughTheYears.Eyes(left: ThroughTheYears.Point(x: 0, y: 420), right: ThroughTheYears.Point(x: 100, y: 420))
        let partial = ThroughTheYears.coverage(
            ThroughTheYears.alignment(edge, width: 500, height: 500), imageWidth: 1000, imageHeight: 1000, width: 500, height: 500)
        #expect(partial < 0.8)
    }

    @Test func theFilmHasATitleThenOneCardPerFace() {
        let plan = ThroughTheYears.plan(frames: 10, speed: .normal)
        #expect(plan.segments.count == 11)
        #expect(plan.segments[0].duration > ThroughTheYears.Speed.normal.hold)
        #expect(plan.segments[2].transition == ThroughTheYears.Speed.normal.crossfade)
        #expect(ThroughTheYears.plan(frames: 10, speed: .fast).duration < plan.duration)
        #expect(ThroughTheYears.plan(frames: 10, speed: .slow).duration > plan.duration)
    }

    @Test func theAgeIsInMonthsForBabiesAndYearsAfterwards() {
        let birthday = date(2020, 5, 3)
        #expect(ThroughTheYears.age(on: date(2020, 11, 3), birthday: birthday, calendar: calendar) == DateComponents(month: 6))
        #expect(ThroughTheYears.age(on: date(2021, 8, 3), birthday: birthday, calendar: calendar) == DateComponents(month: 15))
        #expect(ThroughTheYears.age(on: date(2026, 5, 2), birthday: birthday, calendar: calendar) == DateComponents(year: 5))
        #expect(ThroughTheYears.age(on: date(2019, 1, 1), birthday: birthday, calendar: calendar) == nil)
    }
}

@Suite struct SharedFilmTests {
    func plan() -> FilmPlan {
        let shots: [FilmShot] = (0..<4).map { (index: Int) -> FilmShot in
            let step = Double(index)
            let date = Date(timeIntervalSince1970: 1_700_000_000 + step * 90_000)
            let location = GeoPoint(latitude: 48 + step, longitude: 11 + step * 2)
            return FilmShot(fileId: FileID(index + 1), date: date, location: location, place: "Place \(index)")
        }
        return FilmPlan(shots: shots, rhythm: FilmStyle.upbeat.steadyRhythm, flights: true, style: .upbeat)
    }

    @Test func aSharedFilmKeepsItsTimelineButNotItsPlaces() throws {
        let original = plan()
        let film = SharedFilm(
            kind: .memory, title: "Trip", subtitle: "May 2024", server: URL(string: "https://Cloud.Example.org/nc/")!, plan: original,
            pictures: [], playsScore: true)
        #expect(film.plan.segments.map(\.start) == original.segments.map(\.start))
        #expect(film.plan.duration == original.duration)
        #expect(film.plan.shots.allSatisfy { $0.location == nil && $0.place == nil })
        for segment in film.plan.segments {
            if case .flight(let from, _, let name, _) = segment.content {
                #expect(from == GeoPoint(latitude: 0, longitude: 0))
                #expect(name == nil)
            }
        }
        // It survives the trip through SharePlay.
        let decoded = try JSONDecoder().decode(SharedFilm.self, from: JSONEncoder().encode(film))
        #expect(decoded == film)
        #expect(decoded.plan.style == .upbeat)
    }

    @Test func serversAreComparedInOneForm() {
        let key = SharedFilm.serverKey(URL(string: "https://alice@Cloud.Example.org:443/nc/")!)
        #expect(key == "https://cloud.example.org/nc")
        let film = SharedFilm(
            kind: .slideshow, title: "A", subtitle: nil, server: URL(string: "https://cloud.example.org/nc")!, plan: plan(), pictures: [],
            playsScore: false)
        #expect(film.isOn(URL(string: "https://CLOUD.example.org/nc/")!))
        #expect(!film.isOn(URL(string: "https://cloud.example.org/")!))
        #expect(!film.isOn(URL(string: "http://cloud.example.org/nc")!))
        #expect(film.serverName == "cloud.example.org")
    }

    @Test func theAudienceIsSummedUp() {
        let audience = SharedFilmAudience([
            SharedFilmReport(visible: 10, total: 10, problem: nil),
            SharedFilmReport(visible: 7, total: 10, problem: .notShared),
            SharedFilmReport(visible: 0, total: 10, problem: .noAccount),
            SharedFilmReport(visible: 0, total: 10, problem: .notShared),
        ])
        #expect(audience.complete == 1 && audience.partial == 1 && audience.blind == 2)
        #expect(!audience.everyoneSeesEverything)
        #expect(SharedFilmAudience([]).everyoneSeesEverything)
    }

    @Test func theGroupsTimingIsTurnedIntoThisDevicesClock() {
        // Started 2 s ago at 10 s: now at 12 s.
        let past = FilmSync.position(itemTime: 10, hostTime: 100, now: 102)
        #expect(past.time == 12 && past.delay == 0)
        // Planned for half a second from now: wait, then start at 10 s.
        let future = FilmSync.position(itemTime: 10, hostTime: 100.5, now: 100)
        #expect(future.time == 10 && future.delay == 0.5)
        #expect(FilmSync.position(itemTime: 3, hostTime: nil, now: 50) == (3, 0))
        #expect(FilmSync.position(itemTime: -1, hostTime: .nan, now: 50).time == 0)
    }
}
