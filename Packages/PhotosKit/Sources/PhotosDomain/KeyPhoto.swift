// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Which photo stands for a year, a month or a day in the Library's zoom levels (SPEC §15.5), and which few photos a day
/// shows: favourites first, then the photos this device rated best (`SimilarityIndex`: Vision's aesthetics score), then
/// what is known without looking at the picture.
public enum KeyPhoto {
    /// What the choice looks at; cheap to collect for 100 000 photos.
    public struct Traits: Sendable, Equatable {
        public var isFavorite: Bool
        public var isVideo: Bool
        public var hasPreview: Bool
        /// Width / height; 1 when unknown.
        public var aspectRatio: Double
        /// A PNG: more often a screenshot or a graphic than a photo.
        public var isPNG: Bool
        /// Vision's overall aesthetics score (−1 … 1) where this device computed it.
        public var quality: Float?
        /// Vision says the picture is a document, a receipt, a screenshot… rather than a memorable photo.
        public var isUtility: Bool
        /// The server made a BlurHash of it: its preview is known to exist (servers that make none have none for every
        /// photo, so this changes nothing there).
        public var hasBlurhash: Bool

        public init(
            isFavorite: Bool, isVideo: Bool = false, hasPreview: Bool = true, aspectRatio: Double = 1, isPNG: Bool = false,
            quality: Float? = nil, isUtility: Bool = false, hasBlurhash: Bool = true
        ) {
            self.isFavorite = isFavorite
            self.isVideo = isVideo
            self.hasPreview = hasPreview
            self.aspectRatio = aspectRatio
            self.isPNG = isPNG
            self.quality = quality
            self.isUtility = isUtility
            self.hasBlurhash = hasBlurhash
        }
    }

    /// Higher is a better key photo.
    public static func score(_ traits: Traits) -> Float {
        var score: Float = 0
        // Nothing to show is never the key photo while there is something else.
        if !traits.hasPreview { score -= 10 }
        if traits.isFavorite { score += 2 }
        if let quality = traits.quality, quality.isFinite { score += max(min(quality, 1), -1) }
        if traits.isUtility { score -= 1.5 }
        if !traits.hasBlurhash { score -= 0.5 }
        if traits.isVideo { score -= 0.3 }
        if traits.isPNG { score -= 0.4 }
        // Panoramas and phone-screen shapes look poor in a card.
        let ratio = traits.aspectRatio.isFinite && traits.aspectRatio > 0 ? traits.aspectRatio : 1
        if ratio > 2.2 || ratio < 0.5 { score -= 0.3 }
        return score
    }

    /// The index of the best-scored item in `range`; ties go to the first (the newest).
    public static func best(in range: Range<Int>, scores: [Float]) -> Int? {
        var best: Int?
        var bestScore = -Float.infinity
        for index in range where index < scores.count && scores[index] > bestScore {
            best = index
            bestScore = scores[index]
        }
        return best
    }

    /// Up to `count` best-scored items of `range`, in their order in the range (newest first). The key photo is first.
    public static func highlights(in range: Range<Int>, scores: [Float], count: Int) -> [Int] {
        guard count > 0, !range.isEmpty else { return [] }
        let clamped = range.clamped(to: 0..<scores.count)
        if clamped.count <= count {
            guard let key = best(in: clamped, scores: scores) else { return [] }
            return [key] + clamped.filter { $0 != key }
        }
        // A small selection: keep the `count` best seen so far (ranges are a day of photos, rarely more than a few hundred).
        var kept: [(index: Int, score: Float)] = []
        kept.reserveCapacity(count + 1)
        for index in clamped {
            let score = scores[index]
            if kept.count == count, let worst = kept.last, worst.score >= score { continue }
            let position = kept.firstIndex { $0.score < score } ?? kept.count
            kept.insert((index, score), at: position)
            if kept.count > count { kept.removeLast() }
        }
        guard let key = kept.first?.index else { return [] }
        return [key] + kept.dropFirst().map(\.index).sorted()
    }
}
