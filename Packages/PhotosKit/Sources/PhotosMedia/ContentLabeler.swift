// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import OSLog
import PhotosModel
import PhotosStore
import Vision

/// Recognises what photos show ("dog", "beach") on this device, so that search finds them without the server
/// (SPEC SR-7). Opt-in (Settings › Search).
///
/// - Only previews already in the cache are looked at; nothing is downloaded for it.
/// - The labels are stored in the account's database on this device and never sent anywhere.
/// - It runs when the system says the device is idle and charging (`ContentLabelingScheduler`), in small batches
///   that stop as soon as the system takes the time back.
/// - The classifier's labels are English words; they are searched like every other indexed text.
public struct ContentLabeler: Sendable {
    let store: LabelStore
    let cache: PreviewCache
    private let logger = Logger(subsystem: "com.nextcloud.photos", category: "labels")

    /// Preview sizes looked for, smallest useful first: the grid's tiles are usually there.
    static let buckets = [256, 1024]
    /// A label must be this reliable to be kept (precision at a minimal recall, as Apple recommends for search).
    static let minimumPrecision: Float = 0.9
    static let maximumLabels = 10

    public init(database: AccountDatabase, cache: PreviewCache) {
        self.store = LabelStore(database: database)
        self.cache = cache
    }

    /// Labels cached photos until there are none left or `shouldContinue` says stop. Returns how many were labelled.
    @discardableResult
    public func run(batchSize: Int = 40, shouldContinue: @escaping @Sendable () -> Bool = { true }) async throws -> Int {
        var cursor: FileID?
        var labelled = 0
        var failures = 0
        while shouldContinue(), !Task.isCancelled, failures < 3 {
            let batch = try store.visionCandidates(limit: batchSize, before: cursor)
            guard let last = batch.last else { break }
            cursor = last.fileId
            var results: [(candidate: LabelStore.VisionCandidate, labels: [String])] = []
            for candidate in batch {
                guard shouldContinue(), !Task.isCancelled, failures < 3 else { break }
                // Not cached: left for a later run, after the photo has been on screen.
                guard let url = cache.cachedPreviewURL(fileId: candidate.fileId, etag: candidate.etag, buckets: Self.buckets),
                    let image = ImageDecoding.decode(url: url, maxPixelSize: 512)
                else { continue }
                do {
                    results.append((candidate, try await Self.labels(for: image)))
                } catch {
                    // Not stored: tried again by a later run. Repeated failures end this one (the classifier is not
                    // available right now).
                    logger.error("labelling \(candidate.fileId) failed: \(error.localizedDescription, privacy: .public)")
                    failures += 1
                }
            }
            try store.setVisionLabels(results)
            labelled += results.count
            await Task.yield()
        }
        if labelled > 0 { logger.info("labelled \(labelled) photos on this device") }
        return labelled
    }

    /// The labels the classifier is confident about, as words ("sports_car" becomes "sports car").
    static func labels(for image: CGImage) async throws -> [String] {
        let observations = try await ClassifyImageRequest().perform(on: image)
        return Self.words(
            observations.filter { $0.hasMinimumRecall(0.01, forPrecision: minimumPrecision) }.map { ($0.identifier, $0.confidence) })
    }

    /// The most confident identifiers as lower-case words, without duplicates.
    static func words(_ observations: [(identifier: String, confidence: Float)]) -> [String] {
        var seen = Set<String>()
        return observations.sorted { $0.confidence > $1.confidence }
            .map { $0.identifier.replacingOccurrences(of: "_", with: " ").lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(maximumLabels).map { $0 }
    }
}

extension PreviewCache {
    /// The file of a cached preview of this version, in the first of `buckets` that has one. Not decoded, and not
    /// counted as a use (the background labelling must not keep previews from being trimmed).
    func cachedPreviewURL(fileId: FileID, etag: String, buckets: [Int]) -> URL? {
        for bucket in buckets {
            let url = fileURL(key: Self.key(fileId: fileId, etag: etag, bucket: bucket))
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) { return url }
        }
        return nil
    }
}
