// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Accelerate
import Foundation

/// The maths of "Show Similar" (SPEC §15.5): Vision feature prints (768 numbers of unit length, computed on this device),
/// a short sketch of each that fits 100 000 photos in a few megabytes of memory, and the search over those sketches.
///
/// Two photos are as similar as the cosine of their prints. A search scores every sketch (a matrix product, a few
/// milliseconds for 100 000 photos), keeps the best candidates and orders those by their full prints.
public enum Similarity {
    /// Cosine of prints at and above which a photo is offered as similar. Calibrated on the test library: unrelated
    /// photos are below 0.56 in 99 % of pairs, strong crops of one photo above 0.74.
    public static let similarThreshold: Float = 0.62
    /// Cosine at and above which photos are shots of one scene (a series, a burst, a retake).
    public static let seriesThreshold: Float = 0.84
    /// Photos further apart than this (seconds) are not one series, however alike.
    public static let seriesGap: TimeInterval = 10 * 60

    /// Cosine similarity of two prints (both of unit length, as Vision's revision 2 makes them; normalised here anyway).
    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &normA, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &normB, vDSP_Length(b.count))
        let norms = (normA * normB).squareRoot()
        return norms > 0 ? dot / norms : 0
    }
}

/// Turns a feature print into a 128-byte sketch: a fixed random projection (which keeps cosines close, the
/// Johnson–Lindenstrauss lemma) quantised to one signed byte per dimension.
public struct FeatureSketcher: Sendable {
    public static let dimensions = 128
    /// Quantisation: a projected unit vector has components of about ±1 (standard normal); ×40 uses the byte's range.
    static let quantisation: Float = 40

    public let inputDimensions: Int
    /// `dimensions` × `inputDimensions`, row-major.
    private let matrix: [Float]

    /// The projection is the same on every device and in every run (a fixed seed), so stored sketches stay valid.
    public init(inputDimensions: Int, seed: UInt64 = 0x5EED_F00D) {
        self.inputDimensions = inputDimensions
        var state = seed
        func next() -> UInt64 {
            // SplitMix64.
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        func uniform() -> Double { (Double(next() >> 11) + 0.5) / Double(1 << 53) }
        let count = Self.dimensions * inputDimensions
        var values = [Float](repeating: 0, count: count)
        var index = 0
        while index < count {
            // Box–Muller: two standard normal numbers from two uniform ones.
            let radius = (-2 * log(uniform())).squareRoot()
            let angle = 2 * Double.pi * uniform()
            values[index] = Float(radius * cos(angle))
            if index + 1 < count { values[index + 1] = Float(radius * sin(angle)) }
            index += 2
        }
        // Standard normal entries: a unit vector projects to components of variance 1.
        matrix = values
    }

    /// The projected print, not quantised (queries).
    public func project(_ print: [Float]) -> [Float] {
        guard print.count == inputDimensions else { return [] }
        let unit = Self.normalised(print)
        var output = [Float](repeating: 0, count: Self.dimensions)
        // output (128×1) = matrix (128×D) · unit (D×1)
        vDSP_mmul(matrix, 1, unit, 1, &output, 1, vDSP_Length(Self.dimensions), 1, vDSP_Length(inputDimensions))
        return output
    }

    /// The stored sketch of a print.
    public func sketch(_ print: [Float]) -> [Int8] {
        project(print).map { Int8(max(min(($0 * Self.quantisation).rounded(), 127), -127)) }
    }

    static func normalised(_ vector: [Float]) -> [Float] {
        var norm: Float = 0
        vDSP_svesq(vector, 1, &norm, vDSP_Length(vector.count))
        norm = norm.squareRoot()
        guard norm > 0 else { return vector }
        var scale = 1 / norm
        var output = [Float](repeating: 0, count: vector.count)
        vDSP_vsmul(vector, 1, &scale, &output, 1, vDSP_Length(vector.count))
        return output
    }
}

/// The sketches of a library in one contiguous buffer, searched by score.
public struct SketchMatrix: Sendable {
    public private(set) var ids: [Int64] = []
    /// `ids.count` × `FeatureSketcher.dimensions` bytes.
    public private(set) var bytes: [Int8] = []
    private var positions: [Int64: Int] = [:]

    public init() {}

    public var count: Int { ids.count }

    /// Adds or replaces the sketch of `id`.
    public mutating func set(_ id: Int64, sketch: [Int8]) {
        guard sketch.count == FeatureSketcher.dimensions else { return }
        if let position = positions[id] {
            bytes.replaceSubrange(position * sketch.count..<(position + 1) * sketch.count, with: sketch)
        } else {
            positions[id] = ids.count
            ids.append(id)
            bytes.append(contentsOf: sketch)
        }
    }

    public mutating func reserve(_ count: Int) {
        ids.reserveCapacity(count)
        bytes.reserveCapacity(count * FeatureSketcher.dimensions)
        positions.reserveCapacity(count)
    }

    public func contains(_ id: Int64) -> Bool { positions[id] != nil }

    /// The sketch of `id`, as stored.
    public func sketch(of id: Int64) -> [Int8]? {
        guard let position = positions[id] else { return nil }
        let width = FeatureSketcher.dimensions
        return Array(bytes[position * width..<(position + 1) * width])
    }

    /// Removes the sketches of `gone` (deleted photos). Rebuilds the buffer: done rarely, in the background.
    public mutating func remove(_ gone: Set<Int64>) {
        guard !gone.isEmpty, ids.contains(where: gone.contains) else { return }
        let width = FeatureSketcher.dimensions
        var next = SketchMatrix()
        next.reserve(ids.count)
        for (position, id) in ids.enumerated() where !gone.contains(id) {
            next.set(id, sketch: Array(bytes[position * width..<(position + 1) * width]))
        }
        self = next
    }

    /// The `limit` ids whose sketches score highest against `query` (a projected print), best first.
    /// - Parameter excluding: left out (the photo searched from).
    public func nearest(to query: [Float], limit: Int, excluding: Set<Int64> = []) -> [(id: Int64, score: Float)] {
        let width = FeatureSketcher.dimensions
        guard query.count == width, limit > 0, !ids.isEmpty else { return [] }
        let unit = FeatureSketcher.normalised(query)
        // Scored a chunk at a time: the bytes are widened to floats (vDSP) and multiplied with the query (vDSP), which is
        // as fast in a debug build as in a release build.
        let chunk = 4096
        var floats = [Float](repeating: 0, count: chunk * width)
        var scores = [Float](repeating: 0, count: chunk)
        var kept: [(id: Int64, score: Float)] = []
        kept.reserveCapacity(limit + 1)
        var start = 0
        while start < ids.count {
            let rows = min(chunk, ids.count - start)
            bytes.withUnsafeBufferPointer { source in
                floats.withUnsafeMutableBufferPointer { target in
                    vDSP_vflt8(source.baseAddress! + start * width, 1, target.baseAddress!, 1, vDSP_Length(rows * width))
                }
            }
            vDSP_mmul(floats, 1, unit, 1, &scores, 1, vDSP_Length(rows), 1, vDSP_Length(width))
            for row in 0..<rows {
                let score = scores[row]
                if kept.count == limit, let worst = kept.last, worst.score >= score { continue }
                let id = ids[start + row]
                if excluding.contains(id) { continue }
                let position = kept.firstIndex { $0.score < score } ?? kept.count
                kept.insert((id, score), at: position)
                if kept.count > limit { kept.removeLast() }
            }
            start += rows
        }
        // Scores of quantised sketches: divide by their scale to read them as approximate cosines.
        return kept.map { ($0.id, $0.score / (FeatureSketcher.quantisation * Float(width).squareRoot())) }
    }
}

/// Series of shots of one scene (a burst, a retake, a dozen tries at the same sunset) and the best shot of each.
public enum SimilarSeries {
    public struct Member: Sendable, Equatable {
        public var id: Int64
        public var date: Date
        /// Projected print (`FeatureSketcher.project`) or sketch widened to floats.
        public var vector: [Float]
        public var quality: Float?
        public var isFavorite: Bool

        public init(id: Int64, date: Date, vector: [Float], quality: Float?, isFavorite: Bool) {
            self.id = id
            self.date = date
            self.vector = vector
            self.quality = quality
            self.isFavorite = isFavorite
        }
    }

    public struct Series: Sendable, Equatable, Identifiable {
        /// Members in time order.
        public var ids: [Int64]
        public var best: Int64
        public var id: Int64 { ids.first ?? best }
    }

    /// Cuts members (in any order) into series: photos taken within `gap` of the one before and at least `threshold`
    /// alike to it. Only series of two or more are returned, newest first.
    public static func series(
        _ members: [Member], threshold: Float = Similarity.seriesThreshold, gap: TimeInterval = Similarity.seriesGap
    ) -> [Series] {
        let sorted = members.sorted { ($0.date, $0.id) < ($1.date, $1.id) }
        var result: [Series] = []
        var current: [Member] = []
        func close() {
            if current.count >= 2, let best = best(of: current) { result.append(Series(ids: current.map(\.id), best: best)) }
            current = []
        }
        for member in sorted {
            if let last = current.last,
                member.date.timeIntervalSince(last.date) <= gap,
                Similarity.cosine(last.vector, member.vector) >= threshold
            {
                current.append(member)
            } else {
                close()
                current = [member]
            }
        }
        close()
        return result.reversed()
    }

    /// The moment a photo was taken in, among the results of a search from it: the results at least `threshold` alike to
    /// it, taken in a chain of shots no more than `gap` apart that reaches the photo. In time order, the photo included;
    /// just the photo when it was the only shot.
    public static func moment(
        of source: (id: Int64, date: Date), in matches: [(id: Int64, date: Date, similarity: Float)],
        threshold: Float = Similarity.seriesThreshold, gap: TimeInterval = Similarity.seriesGap
    ) -> [Int64] {
        let alike = matches.filter { $0.similarity >= threshold && $0.id != source.id }.map { (id: $0.id, date: $0.date) }
        let sorted = (alike + [source]).sorted { ($0.date, $0.id) < ($1.date, $1.id) }
        guard let position = sorted.firstIndex(where: { $0.id == source.id }) else { return [source.id] }
        var lower = position
        while lower > 0, sorted[lower].date.timeIntervalSince(sorted[lower - 1].date) <= gap { lower -= 1 }
        var upper = position
        while upper < sorted.count - 1, sorted[upper + 1].date.timeIntervalSince(sorted[upper].date) <= gap { upper += 1 }
        return sorted[lower...upper].map(\.id)
    }

    /// The shot to keep: a favourite, else the best aesthetics score, else the middle one (often the steadiest of a burst).
    public static func best(of members: [Member]) -> Int64? {
        guard !members.isEmpty else { return nil }
        let favorites = members.filter(\.isFavorite)
        let pool = favorites.isEmpty ? members : favorites
        let rated = pool.filter { $0.quality != nil }
        if let top = rated.max(by: { ($0.quality ?? 0) < ($1.quality ?? 0) }) { return top.id }
        return pool[pool.count / 2].id
    }
}
