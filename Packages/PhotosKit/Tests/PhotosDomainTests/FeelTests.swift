// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosDomain

/// Zoom levels, haptic ticks, key photos and the similarity maths (SPEC §15.5).
@Suite struct LibraryZoomTests {
    let ladder = LibraryZoomLadder(gridSteps: [1, 3, 5, 7, 9, 13])

    @Test func ladderRunsFromYearsToTheLargestTiles() {
        #expect(
            ladder.stops == [
                .years, .months, .days, .grid(step: 13), .grid(step: 9), .grid(step: 7), .grid(step: 5), .grid(step: 3), .grid(step: 1),
            ])
        #expect(ladder.densestGrid == .grid(step: 13))
        #expect(ladder.moved(.years, by: 1) == .months)
        #expect(ladder.moved(.days, by: 1) == .grid(step: 13))
        #expect(ladder.moved(.grid(step: 13), by: -1) == .days)
        #expect(ladder.moved(.grid(step: 5), by: -2) == .grid(step: 9))
        // Clamped at both ends.
        #expect(ladder.moved(.years, by: -3) == .years)
        #expect(ladder.moved(.grid(step: 3), by: 5) == .grid(step: 1))
        #expect(!ladder.canZoomOut(from: .years))
        #expect(!ladder.canZoomIn(from: .grid(step: 1)))
        // A stored step that is not on the ladder counts as the closest one.
        #expect(
            ladder.index(of: .grid(step: 6)) == ladder.index(of: .grid(step: 5))
                || ladder.index(of: .grid(step: 6)) == ladder.index(of: .grid(step: 7)))
        #expect(LibraryZoomStop.grid(step: 5).level == .all)
    }

    @Test func aPinchCommitsOnlyPastItsThreshold() {
        #expect(LibraryZoomGesture.steps(projectedScale: 1) == 0)
        #expect(LibraryZoomGesture.steps(projectedScale: 1.15) == 0)
        #expect(LibraryZoomGesture.steps(projectedScale: 1 / 1.15) == 0)
        #expect(LibraryZoomGesture.steps(projectedScale: 1.3) == 1)
        #expect(LibraryZoomGesture.steps(projectedScale: 1 / 1.3) == -1)
        // A long pinch moves further, but never more than three steps.
        #expect(LibraryZoomGesture.steps(projectedScale: 1.22 * 3.0 * 1.01) == 2)
        #expect(LibraryZoomGesture.steps(projectedScale: 2.2) == 1)
        #expect(LibraryZoomGesture.steps(projectedScale: 100) == 3)
        #expect(LibraryZoomGesture.steps(projectedScale: .nan) == 0)
    }

    @Test func momentumCarriesAQuickPinchFurther() {
        // Released at a scale that alone would spring back, but moving fast: it commits.
        let slow = LibraryZoomGesture.projectedScale(scale: 1.12, velocity: 0)
        let fast = LibraryZoomGesture.projectedScale(scale: 1.12, velocity: 3)
        #expect(LibraryZoomGesture.steps(projectedScale: slow) == 0)
        #expect(LibraryZoomGesture.steps(projectedScale: fast) == 1)
        // A pinch that is coming back loses its step.
        #expect(LibraryZoomGesture.steps(projectedScale: LibraryZoomGesture.projectedScale(scale: 1.3, velocity: -4)) == 0)
        #expect(LibraryZoomGesture.projectedScale(scale: 0, velocity: 1) == 1)
        // However fast, a pinch that alone is one step does not become two.
        #expect(LibraryZoomGesture.steps(projectedScale: LibraryZoomGesture.projectedScale(scale: 2.2, velocity: 40)) == 1)
    }

    @Test func theContentResistsAtTheEndsOfTheLadder() {
        #expect(abs(LibraryZoomGesture.displayScale(1.5, canZoomIn: true, canZoomOut: true) - 1.5) < 0.0001)
        #expect(LibraryZoomGesture.displayScale(10, canZoomIn: true, canZoomOut: true) <= 2.5001)
        let resisted = LibraryZoomGesture.displayScale(1.5, canZoomIn: false, canZoomOut: true)
        #expect(resisted > 1 && resisted <= 1.0801)
        let out = LibraryZoomGesture.displayScale(0.5, canZoomIn: true, canZoomOut: false)
        #expect(out < 1 && out >= 1 / 1.0801)
        #expect(LibraryZoomGesture.progress(scale: 1) == 0)
        #expect(LibraryZoomGesture.progress(scale: 3) == 1)
    }
}

@Suite struct YearBoundaryTickerTests {
    /// Feeds the ticker one scroll position after another; true where it ticked.
    func ticks(_ ticker: inout YearBoundaryTicker, _ steps: [(year: Int?, offset: Double, time: TimeInterval, user: Bool, scrub: Bool)])
        -> [Bool]
    {
        steps.map { ticker.update(year: $0.year, offset: $0.offset, time: $0.time, isUserScrolling: $0.user, isScrubbing: $0.scrub) }
    }

    @Test func ticksOnlyWhenAFastScrollCrossesAYear() {
        var ticker = YearBoundaryTicker(minimumSpeed: 2000, minimumInterval: 0.05)
        let result = ticks(
            &ticker,
            [
                // Slow reading: no tick when the year changes.
                (2026, 0, 0, true, false), (2025, 50, 0.1, true, false),
                // Fast: 5000 points per second, into 2024.
                (2025, 550, 0.2, true, false), (2024, 1050, 0.3, true, false),
                // Too soon after the last tick.
                (2023, 1150, 0.32, true, false),
                // Same year: nothing.
                (2023, 1650, 0.42, true, false),
                // A programmatic jump (a relayout) does not tick.
                (2020, 9000, 1, false, false),
            ])
        #expect(result == [false, false, false, true, false, false, false])
    }

    @Test func scrubbingTicksAtEveryYear() {
        var ticker = YearBoundaryTicker()
        #expect(
            ticks(&ticker, [(2026, 0, 0, false, true), (2020, 9000, 1, false, true), (2019, 9001, 2, false, true)]) == [false, true, true])
        ticker.reset()
        // After a reset the first year seen is not a crossing.
        #expect(ticks(&ticker, [(2010, 0, 3, false, true), (nil, 0, 4, false, true)]) == [false, false])
    }
}

@Suite struct KeyPhotoTests {
    @Test func favouritesAndGoodPhotosWin() {
        let plain = KeyPhoto.score(.init(isFavorite: false))
        #expect(KeyPhoto.score(.init(isFavorite: true)) > plain)
        #expect(KeyPhoto.score(.init(isFavorite: false, quality: 0.8)) > plain)
        #expect(KeyPhoto.score(.init(isFavorite: false, quality: -0.8)) < plain)
        #expect(KeyPhoto.score(.init(isFavorite: false, isUtility: true)) < plain)
        #expect(KeyPhoto.score(.init(isFavorite: false, isVideo: true)) < plain)
        #expect(KeyPhoto.score(.init(isFavorite: false, aspectRatio: 3)) < plain)
        #expect(KeyPhoto.score(.init(isFavorite: false, isPNG: true)) < plain)
        // Nothing to show loses even as a favourite.
        #expect(KeyPhoto.score(.init(isFavorite: true, hasPreview: false)) < plain)
        #expect(KeyPhoto.score(.init(isFavorite: false, hasBlurhash: false)) < plain)
        // A favourite beats a well rated photo.
        #expect(KeyPhoto.score(.init(isFavorite: true)) > KeyPhoto.score(.init(isFavorite: false, quality: 1)))
    }

    @Test func bestAndHighlights() {
        let scores: [Float] = [0, 3, 1, 3, -1, 2, 0.5]
        #expect(KeyPhoto.best(in: 0..<7, scores: scores) == 1)
        #expect(KeyPhoto.best(in: 2..<5, scores: scores) == 3)
        #expect(KeyPhoto.best(in: 4..<4, scores: scores) == nil)
        // The key photo first, then the others in grid order.
        #expect(KeyPhoto.highlights(in: 0..<7, scores: scores, count: 3) == [1, 3, 5])
        #expect(KeyPhoto.highlights(in: 4..<7, scores: scores, count: 5) == [5, 4, 6])
        #expect(KeyPhoto.highlights(in: 0..<7, scores: scores, count: 0) == [])
    }
}

@Suite struct SimilarityMathTests {
    /// Random unit vectors of 768 dimensions (like Vision's prints) from a fixed seed.
    struct Vectors {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53) - 0.5
        }
        mutating func vector(_ count: Int = 768) -> [Float] { FeatureSketcher.normalised((0..<count).map { _ in Float(next()) }) }
        /// A vector at about `similarity` (cosine) from `base`.
        mutating func near(_ base: [Float], similarity: Float) -> [Float] {
            let noise = vector(base.count)
            let mixed = zip(base, noise).map { similarity * $0 + (1 - similarity * similarity).squareRoot() * $1 }
            return FeatureSketcher.normalised(mixed)
        }
    }

    @Test func cosine() {
        #expect(Similarity.cosine([1, 0], [1, 0]) == 1)
        #expect(Similarity.cosine([1, 0], [0, 2]) == 0)
        #expect(Similarity.cosine([1], [1, 2]) == 0)
        #expect(abs(Similarity.cosine([1, 1], [2, 2]) - 1) < 0.0001)
    }

    @Test func sketchesAreStableAndKeepCosines() {
        var vectors = Vectors(state: 1)
        let base = vectors.vector()
        let near = vectors.near(base, similarity: 0.9)
        let far = vectors.vector()
        let sketcher = FeatureSketcher(inputDimensions: 768)
        // Same seed, same sketch: what was stored stays comparable.
        #expect(FeatureSketcher(inputDimensions: 768).sketch(base) == sketcher.sketch(base))
        #expect(sketcher.sketch(base).count == FeatureSketcher.dimensions)
        let projected = sketcher.project(base)
        #expect(abs(Similarity.cosine(projected, sketcher.project(near)) - Similarity.cosine(base, near)) < 0.12)
        #expect(abs(Similarity.cosine(projected, sketcher.project(far)) - Similarity.cosine(base, far)) < 0.2)
        #expect(sketcher.project([1, 2, 3]).isEmpty)
    }

    /// The sketches find the true nearest neighbours among many unrelated photos.
    @Test func sketchSearchFindsTheNeighbours() {
        var vectors = Vectors(state: 2)
        let sketcher = FeatureSketcher(inputDimensions: 768)
        let query = vectors.vector()
        var matrix = SketchMatrix()
        let neighbours: [Int64: Float] = [1: 0.95, 2: 0.85, 3: 0.75]
        for (id, similarity) in neighbours { matrix.set(id, sketch: sketcher.sketch(vectors.near(query, similarity: similarity))) }
        for id in 100..<3000 { matrix.set(Int64(id), sketch: sketcher.sketch(vectors.vector())) }
        let found = matrix.nearest(to: sketcher.project(query), limit: 5)
        #expect(Array(found.prefix(3).map(\.id)) == [1, 2, 3])
        #expect(abs(found[0].score - 0.95) < 0.1)
        #expect(!matrix.nearest(to: sketcher.project(query), limit: 5, excluding: [1]).contains { $0.id == 1 })
        // Replacing and removing.
        matrix.set(1, sketch: sketcher.sketch(vectors.vector()))
        #expect(matrix.nearest(to: sketcher.project(query), limit: 1).first?.id == 2)
        matrix.remove([2, 3])
        #expect(!matrix.contains(2) && matrix.contains(1))
        #expect(matrix.count == 2901)
        #expect(matrix.sketch(of: 1)?.count == FeatureSketcher.dimensions)
    }

    /// SPEC §15.5: a search over the sketches of a 100 000-photo library takes milliseconds (it runs on every "Show
    /// Similar"). Prints the time.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PHOTOS_SKIP_PERFORMANCE"] == nil, "PHOTOS_SKIP_PERFORMANCE is set"))
    func sketchSearchPerformance100k() {
        var vectors = Vectors(state: 4)
        let sketcher = FeatureSketcher(inputDimensions: 768)
        var matrix = SketchMatrix()
        matrix.reserve(100_000)
        // Random sketches (projecting 100 000 prints would only slow the test down).
        var bytes = [Int8](repeating: 0, count: FeatureSketcher.dimensions)
        for id in 0..<100_000 {
            for index in bytes.indices { bytes[index] = Int8(max(-127, min(127, (vectors.next() * 160).rounded()))) }
            matrix.set(Int64(id), sketch: bytes)
        }
        let query = sketcher.project(vectors.vector())
        let clock = ContinuousClock()
        var best = Duration.seconds(1000)
        var found: [(id: Int64, score: Float)] = []
        for _ in 0..<3 { best = min(best, clock.measure { found = matrix.nearest(to: query, limit: 360) }) }
        print("PERF sketch search 100k: \(best)")
        #expect(found.count == 360)
        #expect(best < .milliseconds(250))
    }

    @Test func seriesAreCloseInTimeAndAlike() {
        var vectors = Vectors(state: 3)
        let scene = vectors.vector(128)
        let other = vectors.vector(128)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        func member(_ id: Int64, _ seconds: Double, _ vector: [Float], quality: Float? = nil, favorite: Bool = false)
            -> SimilarSeries.Member
        {
            SimilarSeries.Member(id: id, date: start.addingTimeInterval(seconds), vector: vector, quality: quality, isFavorite: favorite)
        }
        let members = [
            member(1, 0, vectors.near(scene, similarity: 0.97), quality: 0.1),
            member(2, 2, vectors.near(scene, similarity: 0.97), quality: 0.6),
            member(3, 4, vectors.near(scene, similarity: 0.97), quality: 0.3),
            // Another subject right after: not part of it.
            member(4, 6, other),
            // The same scene, but a day later: a series of its own (alone: none).
            member(5, 86400, vectors.near(scene, similarity: 0.97)),
        ]
        let series = SimilarSeries.series(members)
        #expect(series.count == 1)
        #expect(series.first?.ids == [1, 2, 3])
        #expect(series.first?.best == 2)
        // A favourite is the best shot, whatever the scores say.
        #expect(SimilarSeries.best(of: [members[1], member(9, 1, scene, quality: -0.5, favorite: true)]) == 9)
        // Without scores: the middle shot.
        #expect(SimilarSeries.best(of: [member(1, 0, scene), member(2, 1, scene), member(3, 2, scene)]) == 2)
        #expect(SimilarSeries.best(of: []) == nil)
    }

    @Test func theMomentOfAPhoto() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let source = (id: Int64(1), date: start)
        let matches: [(id: Int64, date: Date, similarity: Float)] = [
            (2, start.addingTimeInterval(-60), 0.95),
            // Reached through 2.
            (3, start.addingTimeInterval(-60 - 500), 0.9),
            (4, start.addingTimeInterval(30), 0.88),
            // Alike, but hours later: another moment.
            (5, start.addingTimeInterval(7200), 0.97),
            // Close in time, but another subject.
            (6, start.addingTimeInterval(10), 0.7),
        ]
        #expect(SimilarSeries.moment(of: source, in: matches) == [3, 2, 1, 4])
        #expect(SimilarSeries.moment(of: source, in: []) == [1])
    }
}
