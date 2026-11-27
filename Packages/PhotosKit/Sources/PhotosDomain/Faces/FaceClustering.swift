// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Accelerate
import Foundation
import PhotosModel

/// People on this device, for servers without Recognize (SPEC §22.3): the maths that groups the faces Vision found.
///
/// Each face has a Vision feature print of its aligned head-and-shoulders crop (768 numbers). A feature print describes
/// a picture in general, not a face's identity, so two prints are compared after taking away what all faces of the
/// library have in common (their mean): what is left is what this face has of its own. Faces join the person whose
/// centre is nearest when it is near enough; a face never joins a person who already has a face in the same photo, nor
/// one the user said it is not. People whose centres come close are merged later, unless they have different names.
public enum FaceClustering {
    /// The least centered cosine between a face and a person's centre for the face to join. Measured on the test library
    /// (docs/STATUS.md §22.3): the same person in different photos ≥ 0.78, the nearest different people 0.74 and 0.76,
    /// most pairs of different people < 0.65.
    public static let joinThreshold: Float = 0.75
    /// The least centered cosine between two people's centres to merge them.
    public static let mergeThreshold: Float = 0.80
    /// Vision's face capture quality (0…1) below which a face is not used: dark, blurred, turned away, tiny.
    public static let minimumQuality: Float = 0.25
    /// The least width of a face in the analysed picture, in pixels.
    public static let minimumFaceSide: Double = 40
    /// A person is shown with faces in at least this many photos (or with a name).
    public static let minimumPhotos = 2

    /// `vector` scaled to unit length.
    public static func normalized(_ vector: [Float]) -> [Float] {
        var squares: Float = 0
        vDSP_svesq(vector, 1, &squares, vDSP_Length(vector.count))
        let length = squares.squareRoot()
        guard length > 0 else { return vector }
        var scale = 1 / length
        var result = [Float](repeating: 0, count: vector.count)
        vDSP_vsmul(vector, 1, &scale, &result, 1, vDSP_Length(vector.count))
        return result
    }

    /// `vector − mean`, of unit length: what a face has of its own.
    public static func centered(_ vector: [Float], mean: [Float]) -> [Float] {
        guard mean.count == vector.count else { return normalized(vector) }
        var difference = [Float](repeating: 0, count: vector.count)
        vDSP_vsub(mean, 1, vector, 1, &difference, 1, vDSP_Length(vector.count))
        return normalized(difference)
    }

    /// Dot product (the cosine of unit vectors).
    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(a.count))
        return result
    }

    /// Whether a face is good enough to group: clear enough and large enough in the analysed picture.
    public static func isUsable(quality: Float?, sideInPixels: Double) -> Bool {
        (quality ?? 0) >= minimumQuality && sideInPixels >= minimumFaceSide
    }

    /// How much two face boxes overlap (intersection over union): the same face found again, on this device after a
    /// change or on another device, overlaps its first box by far more than half.
    public static func overlap(_ a: FaceBox, _ b: FaceBox) -> Double {
        let left = max(a.x, b.x)
        let right = min(a.x + a.width, b.x + b.width)
        let top = max(a.y, b.y)
        let bottom = min(a.y + a.height, b.y + b.height)
        guard right > left, bottom > top else { return 0 }
        let intersection = (right - left) * (bottom - top)
        let union = a.width * a.height + b.width * b.height - intersection
        return union > 0 ? intersection / union : 0
    }

    /// The overlap from which two boxes are the same face.
    public static let sameFaceOverlap = 0.5
}

/// The running mean of all usable face prints of the library (what `FaceClustering.centered` takes away).
public struct FacePrintMean: Sendable, Equatable {
    public private(set) var sum: [Float]
    public private(set) var count: Int

    public init(sum: [Float] = [], count: Int = 0) {
        self.sum = sum
        self.count = count
    }

    public var mean: [Float] {
        guard count > 0 else { return sum }
        return sum.map { $0 / Float(count) }
    }

    public mutating func add(_ print: [Float]) {
        if sum.count != print.count {
            guard sum.isEmpty || count == 0 else { return }
            sum = [Float](repeating: 0, count: print.count)
        }
        vDSP_vadd(sum, 1, print, 1, &sum, 1, vDSP_Length(sum.count))
        count += 1
    }
}

/// Groups faces into people, one face at a time (`FaceClustering`).
public struct FaceClusterer: Sendable {
    /// A person as the grouping sees them.
    public struct Cluster: Sendable, Equatable {
        public var id: Int64
        /// The sum of the members' normalized prints; the centre is `sum / count`.
        public var sum: [Float]
        public var count: Int
        /// The photos the person has a face in: a second face of one photo is someone else.
        public var files: Set<FileID>
        /// Faces the user said are not this person.
        public var rejected: Set<Int64>
        public var name: String?

        public init(
            id: Int64, sum: [Float], count: Int, files: Set<FileID> = [], rejected: Set<Int64> = [], name: String? = nil
        ) {
            self.id = id
            self.sum = sum
            self.count = count
            self.files = files
            self.rejected = rejected
            self.name = name
        }

        public var centre: [Float] {
            guard count > 0 else { return sum }
            return sum.map { $0 / Float(count) }
        }
    }

    public private(set) var clusters: [Int64: Cluster] = [:]
    public var mean: [Float]
    public var joinThreshold: Float
    public var mergeThreshold: Float
    /// The centered centres, kept up to date as faces join.
    private var centres: [Int64: [Float]] = [:]

    public init(
        clusters: [Cluster] = [], mean: [Float] = [], joinThreshold: Float = FaceClustering.joinThreshold,
        mergeThreshold: Float = FaceClustering.mergeThreshold
    ) {
        self.mean = mean
        self.joinThreshold = joinThreshold
        self.mergeThreshold = mergeThreshold
        for cluster in clusters { set(cluster) }
    }

    mutating func set(_ cluster: Cluster) {
        clusters[cluster.id] = cluster
        centres[cluster.id] = cluster.count > 0 ? FaceClustering.centered(cluster.centre, mean: mean) : nil
    }

    /// Takes a new mean (more faces were analysed) and centres everyone again.
    public mutating func recentre(mean: [Float]) {
        self.mean = mean
        for cluster in clusters.values { set(cluster) }
    }

    /// The person a face belongs to, with the similarity, or nil when nobody is near enough.
    /// - Parameters:
    ///   - print: the face's normalized print.
    ///   - fileId: its photo (people with a face in it already are left out).
    ///   - faceId: the face (people it was rejected by are left out).
    public func bestMatch(for print: [Float], fileId: FileID, faceId: Int64? = nil) -> (id: Int64, similarity: Float)? {
        let face = FaceClustering.centered(print, mean: mean)
        var best: (Int64, Float)?
        for (id, centre) in centres {
            guard let cluster = clusters[id], !cluster.files.contains(fileId) else { continue }
            if let faceId, cluster.rejected.contains(faceId) { continue }
            let similarity = FaceClustering.dot(face, centre)
            if similarity >= joinThreshold, similarity > (best?.1 ?? -2) || (similarity == best?.1 && id < (best?.0 ?? .max)) {
                best = (id, similarity)
            }
        }
        return best.map { (id: $0.0, similarity: $0.1) }
    }

    /// Adds a face to a person (made when `id` is new).
    public mutating func add(_ print: [Float], fileId: FileID, to id: Int64) {
        var cluster = clusters[id] ?? Cluster(id: id, sum: [Float](repeating: 0, count: print.count), count: 0)
        if cluster.sum.count != print.count { cluster.sum = [Float](repeating: 0, count: print.count) }
        vDSP_vadd(cluster.sum, 1, print, 1, &cluster.sum, 1, vDSP_Length(print.count))
        cluster.count += 1
        cluster.files.insert(fileId)
        set(cluster)
    }

    /// Takes a face away from a person; `rejected`: the user said it is not them, so it never joins them again.
    public mutating func remove(_ print: [Float], fileId: FileID, faceId: Int64, from id: Int64, rejected: Bool) {
        guard var cluster = clusters[id] else { return }
        if cluster.sum.count == print.count, cluster.count > 0 {
            vDSP_vsub(print, 1, cluster.sum, 1, &cluster.sum, 1, vDSP_Length(print.count))
            cluster.count -= 1
        }
        cluster.files.remove(fileId)
        if rejected { cluster.rejected.insert(faceId) }
        set(cluster)
    }

    public mutating func rename(_ id: Int64, to name: String?) {
        guard var cluster = clusters[id] else { return }
        cluster.name = name
        clusters[id] = cluster
    }

    /// Puts person `from` into `into`.
    public mutating func merge(_ from: Int64, into: Int64) {
        guard from != into, let source = clusters[from], var target = clusters[into] else { return }
        if target.sum.count == source.sum.count {
            vDSP_vadd(target.sum, 1, source.sum, 1, &target.sum, 1, vDSP_Length(target.sum.count))
        } else if target.count == 0 {
            target.sum = source.sum
        }
        target.count += source.count
        target.files.formUnion(source.files)
        target.rejected.formUnion(source.rejected)
        if target.name == nil { target.name = source.name }
        clusters[from] = nil
        centres[from] = nil
        set(target)
    }

    public mutating func delete(_ id: Int64) {
        clusters[id] = nil
        centres[id] = nil
    }

    /// Pairs of people near enough to be one, nearest first: never two with different names, nor two with faces in one
    /// photo. The first of each pair is the one to keep (named, else larger, else older).
    /// - Parameter touched: only pairs with one of these people (the ones that changed); nil for all pairs.
    public func mergeCandidates(touched: Set<Int64>? = nil) -> [(keep: Int64, merge: Int64, similarity: Float)] {
        let ids = centres.keys.sorted()
        var result: [(Int64, Int64, Float)] = []
        for (index, a) in ids.enumerated() {
            guard let first = clusters[a], let centreA = centres[a] else { continue }
            for b in ids[(index + 1)...] {
                if let touched, !touched.contains(a), !touched.contains(b) { continue }
                guard let second = clusters[b], let centreB = centres[b] else { continue }
                if let nameA = first.name, let nameB = second.name, nameA != nameB { continue }
                guard first.files.isDisjoint(with: second.files) else { continue }
                let similarity = FaceClustering.dot(centreA, centreB)
                guard similarity >= mergeThreshold else { continue }
                let keepFirst: Bool
                if (first.name != nil) != (second.name != nil) {
                    keepFirst = first.name != nil
                } else if first.count != second.count {
                    keepFirst = first.count > second.count
                } else {
                    keepFirst = a < b
                }
                result.append(keepFirst ? (a, b, similarity) : (b, a, similarity))
            }
        }
        return result.sorted { $0.2 != $1.2 ? $0.2 > $1.2 : ($0.0, $0.1) < ($1.0, $1.1) }
            .map { (keep: $0.0, merge: $0.1, similarity: $0.2) }
    }

    /// Merges the people `mergeCandidates` finds, nearest first, in rounds until none are left; returns the merges done
    /// (kept, merged).
    @discardableResult
    public mutating func consolidate(touched: Set<Int64>? = nil) -> [(keep: Int64, merge: Int64)] {
        var done: [(keep: Int64, merge: Int64)] = []
        var changed = touched
        for _ in 0..<16 {
            var used = Set<Int64>()
            var round: [(keep: Int64, merge: Int64)] = []
            for pair in mergeCandidates(touched: changed) where !used.contains(pair.keep) && !used.contains(pair.merge) {
                // Checked again: an earlier merge of this round may have changed what the two are.
                guard let keep = clusters[pair.keep], let other = clusters[pair.merge], keep.files.isDisjoint(with: other.files)
                else { continue }
                used.formUnion([pair.keep, pair.merge])
                round.append((pair.keep, pair.merge))
            }
            guard !round.isEmpty else { break }
            for pair in round { merge(pair.merge, into: pair.keep) }
            done += round
            changed = Set(round.map(\.keep))
        }
        return done
    }
}
