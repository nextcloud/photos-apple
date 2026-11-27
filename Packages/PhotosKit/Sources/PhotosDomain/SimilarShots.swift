// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// "Similar shots" of Clean up (SPEC §19.3): series of shots of one scene across the whole library (a burst, a retake, a
/// dozen tries at one sunset), the best shot of each, and what deleting the others frees.
///
/// Built from what "Show Similar" already worked out on this device (`SimilarityIndex`): photos in time order, each
/// compared with the one before (`Similarity.seriesThreshold`, `Similarity.seriesGap`), so the whole library is one pass
/// with one shot's sketch in memory at a time.
///
/// Conservative like the rest of Clean up: copies of one shot are never offered against each other. A HEIC and the JPEG
/// beside it (`CopyStacks`), or the same file in two folders (same size and capture second: those are for Duplicates),
/// are one shot; the shot that is kept keeps all its copies.
public enum SimilarShots {
    /// One indexed photo, as the grouping needs it.
    public struct Photo: Sendable, Equatable {
        public var id: FileID
        public var date: Date
        /// The sketch widened to floats (or a projected print); only compared by cosine, so the scale does not matter.
        public var vector: [Float]
        public var quality: Float?
        public var isFavorite: Bool
        public var size: Int64
        public var name: String
        public var directory: String
        public var canDelete: Bool
        /// What the best-shot analysis found (SPEC §21.4); nil while the photo is not analysed.
        public var signals: BestShot.Signals?

        public init(
            id: FileID, date: Date, vector: [Float], quality: Float? = nil, isFavorite: Bool = false, size: Int64, name: String,
            directory: String, canDelete: Bool = true, signals: BestShot.Signals? = nil
        ) {
            self.id = id
            self.date = date
            self.vector = vector
            self.quality = quality
            self.isFavorite = isFavorite
            self.size = size
            self.name = name
            self.directory = directory
            self.canDelete = canDelete
            self.signals = signals
        }
    }

    /// A series of two or more shots, with the one suggested to keep.
    public struct Group: Sendable, Equatable, Identifiable {
        /// Every file of the series, in time order.
        public var ids: [FileID]
        /// The shots: the files of each, in time order. Two or more.
        public var shots: [[FileID]]
        /// The file shown for the best shot.
        public var best: FileID
        /// The files of the best shot (it and its copies): never offered for deletion.
        public var kept: [FileID]
        /// The files of the other shots the user may delete, in time order.
        public var others: [FileID]
        /// What deleting `others` frees, in bytes.
        public var bytes: Int64
        /// Why the best shot was chosen (`BestShot.Choice.reasons`).
        public var reasons: [BestShot.Reason] = []
        /// The photos of the series that were analysed for the best shot, and all of them (one file per shot): fewer
        /// analysed means the choice may still change.
        public var analysed = 0

        public var id: FileID { ids.first ?? best }
    }

    /// Cuts photos, fed in time order, into series.
    public struct Builder: Sendable {
        let threshold: Float
        let gap: TimeInterval
        private var current: [[Photo]] = []
        private var last: Photo?
        private var groups: [Group] = []

        public init(threshold: Float = Similarity.seriesThreshold, gap: TimeInterval = Similarity.seriesGap) {
            self.threshold = threshold
            self.gap = gap
        }

        /// Adds the next photo. Photos must come in order of (date, id); one out of order starts a new series.
        public mutating func add(_ photo: Photo) {
            guard let last, photo.date >= last.date, photo.date.timeIntervalSince(last.date) <= gap else {
                close()
                current = [[photo]]
                self.last = photo
                return
            }
            if SimilarShots.isCopy(photo, of: last) {
                current[current.count - 1].append(photo)
            } else if Similarity.cosine(last.vector, photo.vector) >= threshold {
                current.append([photo])
            } else {
                close()
                current = [[photo]]
            }
            self.last = photo
        }

        /// Ends the last series and returns every series, newest first (and starts over).
        public mutating func finish() -> [Group] {
            close()
            last = nil
            defer { groups = [] }
            return groups.reversed()
        }

        private mutating func close() {
            defer { current = [] }
            guard current.count >= 2, let group = SimilarShots.group(current) else { return }
            groups.append(group)
        }
    }

    /// All series among `photos` (any order), newest first.
    public static func groups(
        _ photos: [Photo], threshold: Float = Similarity.seriesThreshold, gap: TimeInterval = Similarity.seriesGap
    ) -> [Group] {
        var builder = Builder(threshold: threshold, gap: gap)
        for photo in photos.sorted(by: { ($0.date, $0.id) < ($1.date, $1.id) }) { builder.add(photo) }
        return builder.finish()
    }

    /// Two files of one shot: a copy in another format beside it (`CopyStacks`), or the same file elsewhere (same size,
    /// same capture second).
    static func isCopy(_ photo: Photo, of other: Photo) -> Bool {
        if photo.size > 0, photo.size == other.size, Int64(photo.date.timeIntervalSince1970) == Int64(other.date.timeIntervalSince1970) {
            return true
        }
        return photo.directory == other.directory && abs(photo.date.timeIntervalSince(other.date)) <= CopyStacks.maximumGap
            && CopyStacks.baseName(photo.name) == CopyStacks.baseName(other.name)
    }

    /// The group of some shots: the best shot (`BestShot.choose`) of the shots, with a shot counting as favourite when
    /// any of its files is one, and analysed as the file it shows. Nil when the user may delete none of the other shots
    /// (nothing to clean up).
    static func group(_ shots: [[Photo]]) -> Group? {
        let candidates: [BestShot.Candidate] = shots.compactMap { files in
            guard let first = files.first else { return nil }
            return BestShot.Candidate(
                id: first.id, signals: files.first(where: { $0.signals != nil })?.signals, isFavorite: files.contains(where: \.isFavorite),
                quality: files.compactMap(\.quality).max())
        }
        guard let choice = BestShot.choose(candidates), let bestShot = shots.first(where: { $0.first?.id == choice.best }) else {
            return nil
        }
        let keptIds = bestShot.map(\.id)
        let others = shots.filter { $0.first?.id != choice.best }.flatMap { $0 }.filter(\.canDelete)
        guard !others.isEmpty else { return nil }
        // The best shot's own file is the one shown: a favourite file, else the analysed one, else the best-rated, else
        // the first.
        let shown =
            bestShot.first(where: \.isFavorite)?.id ?? bestShot.first(where: { $0.signals != nil })?.id
            ?? bestShot.max(by: { ($0.quality ?? -1) < ($1.quality ?? -1) })?.id ?? choice.best
        return Group(
            ids: shots.flatMap { $0.map(\.id) }, shots: shots.map { $0.map(\.id) }, best: shown, kept: keptIds,
            others: others.map(\.id), bytes: others.reduce(0) { $0 + $1.size }, reasons: choice.reasons,
            analysed: candidates.filter { $0.signals != nil }.count)
    }
}

/// What the Clean up screen adds up (SPEC §19.3).
public enum CleanUpTotals {
    /// Bytes freed by deleting all of `files`, each file counted once: a large video can also be a duplicate copy.
    public static func bytes(_ files: [(id: FileID, size: Int64)]) -> Int64 {
        var seen = Set<FileID>()
        var total: Int64 = 0
        for file in files where seen.insert(file.id).inserted { total += file.size }
        return total
    }
}
