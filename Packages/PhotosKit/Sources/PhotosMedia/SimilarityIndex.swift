// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import OSLog
import PhotosDomain
import PhotosModel
import PhotosStore
import Vision

/// "Show Similar" and the best shot of a series (SPEC §15.5).
///
/// - `SimilarityIndexer` works through the photos whose previews are cached, a batch at a time, in the background: a
///   Vision feature print and the aesthetics score of each, stored in the account's database (`SimilarityStore`). It
///   only ever looks at what is new or changed, so it is incremental.
/// - `SimilarityIndex` keeps a 128-byte sketch of every print in memory (12.8 MB for 100 000 photos), finds the nearest
///   sketches with one matrix product, and orders the best few hundred by their full prints.
///
/// Nothing leaves the device.
public enum SimilarityAnalysis {
    /// Previews looked for, smallest useful first (the grid's tiles are usually cached as 256).
    public static let buckets = [256, 1024]
    /// Vision scales its input down to a few hundred pixels anyway.
    public static let decodeSize = 384

    /// The feature print and the aesthetics score of a picture.
    public static func analyze(_ image: CGImage, sketcher: (Int) -> FeatureSketcher) async throws -> SimilarityStore.Analysis {
        #if targetEnvironment(simulator)
            // The simulator cannot run these models: on its GPU they fail, on its CPU they return the same print and score
            // for every picture. Nothing is stored there (UI checks use prints made on the Mac, docs/TESTING.md).
            throw SimulatorUnsupported()
        #else
            let observation = try await GenerateImageFeaturePrintRequest().perform(on: image)
            let print: [Float] = observation.data.withUnsafeBytes { raw in
                guard observation.elementType == .float else { return [] }
                return Array(raw.bindMemory(to: Float.self))
            }
            guard !print.isEmpty else { return .failed }
            let quality = try? await CalculateImageAestheticsScoresRequest().perform(on: image)
            return SimilarityStore.Analysis(
                print: print, sketch: sketcher(print.count).sketch(print), quality: quality?.overallScore,
                isUtility: quality?.isUtility ?? false)
        #endif
    }

    struct SimulatorUnsupported: Error {}
}

/// Indexes cached previews (see `SimilarityAnalysis`).
public struct SimilarityIndexer: Sendable {
    let store: SimilarityStore
    let cache: PreviewCache
    let index: SimilarityIndex?
    private let logger = Logger(subsystem: "com.nextcloud.photos", category: "similar")

    public init(database: AccountDatabase, cache: PreviewCache, index: SimilarityIndex? = nil) {
        store = SimilarityStore(database: database)
        self.cache = cache
        self.index = index
    }

    /// Indexes cached photos until there are none left or `shouldContinue` says stop. Returns how many were indexed.
    /// - Parameter pause: rest between batches, so that a run in the foreground never takes the device's attention.
    @discardableResult
    public func run(batchSize: Int = 32, pause: Duration = .zero, shouldContinue: @escaping @Sendable () -> Bool = { true }) async throws
        -> Int
    {
        var cursor: FileID?
        var indexed = 0
        var failures = 0
        let sketchers = SketcherCache()
        while shouldContinue(), !Task.isCancelled, failures < 3 {
            let batch = try store.candidates(limit: batchSize, before: cursor)
            guard let last = batch.last else { break }
            cursor = last.fileId
            var results: [(candidate: SimilarityStore.Candidate, analysis: SimilarityStore.Analysis)] = []
            for candidate in batch {
                guard shouldContinue(), !Task.isCancelled, failures < 3 else { break }
                // Not cached: left for a later run, after the photo has been on screen.
                guard
                    let url = cache.cachedPreviewURL(
                        fileId: candidate.fileId, etag: candidate.etag, buckets: SimilarityAnalysis.buckets)
                else { continue }
                guard let image = ImageDecoding.decode(url: url, maxPixelSize: SimilarityAnalysis.decodeSize) else {
                    results.append((candidate, .failed))
                    continue
                }
                do {
                    results.append((candidate, try await SimilarityAnalysis.analyze(image, sketcher: sketchers.sketcher)))
                } catch {
                    logger.error("analysing \(candidate.fileId) failed: \(error.localizedDescription, privacy: .public)")
                    failures += 1
                }
            }
            try store.save(results)
            await index?.add(results)
            indexed += results.count
            // Rests only after real work: a batch of uncached photos costs a few file lookups.
            if pause > .zero, !results.isEmpty { try? await Task.sleep(for: pause) } else { await Task.yield() }
        }
        if indexed > 0 { logger.info("indexed \(indexed) photos for Show Similar") }
        return indexed
    }
}

/// One `FeatureSketcher` per print size, made once (the projection matrix takes a moment to generate).
final class SketcherCache: @unchecked Sendable {
    // `@unchecked Sendable`: the dictionary is only touched under `lock`.
    private let lock = NSLock()
    private var sketchers: [Int: FeatureSketcher] = [:]

    func sketcher(_ dimensions: Int) -> FeatureSketcher {
        lock.lock()
        defer { lock.unlock() }
        if let known = sketchers[dimensions] { return known }
        let made = FeatureSketcher(inputDimensions: dimensions)
        sketchers[dimensions] = made
        return made
    }
}

/// The sketches of one account's library in memory, and the searches over them.
public actor SimilarityIndex {
    /// A photo found similar.
    public struct Match: Sendable, Hashable {
        public var fileId: FileID
        /// Cosine of the full prints (1: the same picture).
        public var similarity: Float
    }

    let store: SimilarityStore
    private var matrix = SketchMatrix()
    private var loadedUpTo: Date?
    private let sketchers = SketcherCache()

    public init(database: AccountDatabase) {
        store = SimilarityStore(database: database)
    }

    public var count: Int { matrix.count }

    /// Reads what was indexed since the last call (all of it the first time) and forgets changed versions.
    public func refresh() throws {
        let first = loadedUpTo == nil
        let rows = try store.sketches(since: loadedUpTo)
        if first { matrix.reserve(rows.count) }
        for row in rows { matrix.set(row.fileId, sketch: row.sketch) }
        if let last = rows.last?.indexedAt { loadedUpTo = last }
        if !first { matrix.remove(try store.staleIds()) }
    }

    /// Forgets what is in memory (the stored index was deleted).
    public func reset() {
        matrix = SketchMatrix()
        loadedUpTo = nil
    }

    /// Takes what an indexer run just stored.
    func add(_ results: [(candidate: SimilarityStore.Candidate, analysis: SimilarityStore.Analysis)]) {
        for (candidate, analysis) in results {
            if let sketch = analysis.sketch { matrix.set(candidate.fileId, sketch: sketch) }
        }
    }

    /// The print of a photo: stored, else worked out now from `image` (and stored for next time).
    public func featurePrint(of candidate: SimilarityStore.Candidate, image: @Sendable () async -> CGImage?) async throws -> [Float]? {
        if let stored = try store.prints(of: [candidate.fileId])[candidate.fileId] { return stored }
        guard let picture = await image() else { return nil }
        let analysis = try await SimilarityAnalysis.analyze(picture, sketcher: sketchers.sketcher)
        try store.save([(candidate, analysis)])
        add([(candidate, analysis)])
        return analysis.print
    }

    /// Photos like the one with `featurePrint`, most similar first.
    /// - Parameters:
    ///   - limit: at most this many.
    ///   - threshold: the least similarity (cosine) shown.
    public func similar(
        to featurePrint: [Float], excluding: FileID, limit: Int = 120, threshold: Float = Similarity.similarThreshold
    ) throws -> [Match] {
        let sketcher = sketchers.sketcher(featurePrint.count)
        // The sketches pick the candidates; their full prints decide the order.
        let candidates = matrix.nearest(to: sketcher.project(featurePrint), limit: max(limit * 3, 200), excluding: [excluding])
        let prints = try store.prints(of: candidates.map(\.id))
        return
            candidates
            .compactMap { candidate -> Match? in
                guard let other = prints[candidate.id] else { return nil }
                return Match(fileId: candidate.id, similarity: Similarity.cosine(featurePrint, other))
            }
            .filter { $0.similarity >= threshold }
            .sorted { ($0.similarity, $1.fileId) > ($1.similarity, $0.fileId) }
            .prefix(limit).map { $0 }
    }

    /// The projected print (or the widened sketch) of each id that is indexed, for grouping into series.
    public func vectors(of ids: [FileID]) -> [FileID: [Float]] {
        var result: [FileID: [Float]] = [:]
        for id in ids {
            if let sketch = matrix.sketch(of: id) { result[id] = sketch.map(Float.init) }
        }
        return result
    }
}
