// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// Bursts (SPEC TL-6 a, §21.4): those the device or the camera marked as one, and quick runs of alike photos.
///
/// Photos only stacks a burst when the file says it belongs to one. Apple keeps that in the burst identifier of its
/// maker note, which a stock server does not hand out (the timeline's SEARCH has no EXIF, and the server's
/// `photos-exif` drops entries over 1000 bytes and stores the maker note only as an opaque blob). Stacking by time alone
/// (the web's "≤ 3 s apart" rule in `Stacks`) would also fold up quick series of single shots, which Photos never does.
///
/// What is left and reliable is the file name of cameras that name burst frames: Google Camera and other Android
/// cameras write `IMG_20171007_141256_BURST001_COVER.jpg`, `IMG_20171007_141256_BURST002.jpg`, …,
/// `00000IMG_00000_BURST20180120152403_COVER.jpg`, `00001IMG_00001_BURST20180120152403.jpg`, … or
/// `PXL_20210727_172005836.BURST-01.COVER.jpg`. Frames are stacked when they carry the same burst marker, are images in
/// the same folder and were taken within `maximumSpan` of the burst's newest frame.
///
/// Since round 11 (SPEC §21.4) two more kinds are stacked: photos of this device that PhotoKit says belong to one burst
/// (`CopyStackCandidate.burstIdentifier`), and bursts that nothing marks but their timing and looks (`TimeBursts`, from
/// what "Show Similar" worked out on this device). A burst shows its best shot (`BestShot`) once its frames are analysed.
public enum BurstStacks {
    /// All frames of one burst lie within this time of its newest frame; a marker that comes back later is another burst.
    public static let maximumSpan: TimeInterval = 60

    /// What a file name says about the burst it belongs to.
    public struct Marker: Hashable, Sendable {
        /// The same for all frames of one burst (in one folder).
        public var key: String
        /// The frame the camera chose to show (`…_COVER`).
        public var isCover: Bool
    }

    /// Long digit runs after `BURST` identify the burst (a capture time, the frame number is in front);
    /// short ones are the frame number (the burst is identified by what comes before).
    static let identifierDigits = 12

    /// The burst marker in a file name: `BURST`, in capitals, at the start of the name or after `_`, `.` or `-`, then an
    /// optional `-` or `_` and at least one digit. `sunburst.jpg`, `Burst.jpg` or `BURST.jpg` have none.
    public static func marker(_ fileName: String) -> Marker? {
        // Most names have no marker: one cheap search before anything is taken apart.
        guard fileName.utf8.count >= 6, fileName.contains("BURST") else { return nil }
        let dot = fileName.lastIndex(of: ".")
        let base = String(dot.map { fileName[..<$0] } ?? fileName[...])
        let characters = Array(base.unicodeScalars)
        let token = Array("BURST".unicodeScalars)
        var start = 0
        while start + token.count <= characters.count {
            defer { start += 1 }
            guard Array(characters[start..<start + token.count]) == token else { continue }
            if start > 0, !["_", ".", "-"].contains(characters[start - 1]) { continue }
            var index = start + token.count
            if index < characters.count, characters[index] == "-" || characters[index] == "_" { index += 1 }
            let digitsStart = index
            while index < characters.count, ("0"..."9").contains(characters[index]) { index += 1 }
            let digits = String(String.UnicodeScalarView(characters[digitsStart..<index]))
            guard !digits.isEmpty else { continue }
            let rest = String(String.UnicodeScalarView(characters[index...])).uppercased()
            let isCover = rest.contains("COVER")
            if digits.count >= identifierDigits {
                return Marker(key: "BURST" + digits, isCover: isCover)
            }
            let prefix = String(String.UnicodeScalarView(characters[..<start]))
            return Marker(key: prefix.precomposedStringWithCanonicalMapping.lowercased() + "BURST", isCover: isCover)
        }
        return nil
    }

    /// The bursts among `items` (timeline order, newest first): positions in `items`, the frame shown first, then the
    /// others in timeline order. Copies of a frame (`…_BURST001.dng` beside `…_BURST001.jpg`) belong to the burst like
    /// any frame. Linear in the items, apart from the few runs that `evidence` is asked about.
    ///
    /// Three kinds, most certain first: photos of this device with the same `burstIdentifier`; frames the camera named
    /// (`marker`); and, only with `evidence` (the sketches this device made for "Show Similar"), quick runs of alike
    /// photos (`TimeBursts`). The frame shown is the best shot (`BestShot`) where `evidence` has analysed the frames,
    /// else a favourite, else the camera's cover, else the newest frame.
    public static func stacks<Item: CopyStackCandidate>(_ items: [Item], evidence: (any BurstEvidence)? = nil) -> [[Int]] {
        var open: [String: Group] = [:]
        var result: [[Int]] = []
        func close(_ group: Group) {
            // At least two frames: copies of a single frame are left to `CopyStacks`.
            let frames = Set(group.members.lazy.map { CopyStacks.baseName(items[$0].name) })
            if frames.count > 1 || group.isDevice && group.members.count > 1 { result.append(group.members) }
        }
        for index in items.indices where !items[index].isVideo {
            if let identifier = items[index].burstIdentifier, !identifier.isEmpty {
                // PhotoKit says so: no rule about names, folders or time.
                open["device:" + identifier, default: Group(members: [], newest: items[index].timestamp, isDevice: true)].members.append(
                    index)
                continue
            }
            guard let marker = marker(items[index].name) else { continue }
            let key = items[index].directory + "/" + marker.key
            let time = items[index].timestamp
            if let group = open[key], abs(group.newest.timeIntervalSince(time)) <= maximumSpan {
                open[key]?.members.append(index)
            } else {
                if let group = open[key] { close(group) }
                open[key] = Group(members: [index], newest: time)
            }
        }
        for group in open.values { close(group) }
        if let evidence {
            var taken = Set<Int>()
            for stack in result { taken.formUnion(stack) }
            result += TimeBursts.runs(items, excluding: taken, evidence: evidence)
        }
        return result.map { ordered($0, items, evidence: evidence) }.sorted { ($0.min() ?? 0) < ($1.min() ?? 0) }
    }

    /// A burst being collected: its frames so far and the time of the newest.
    private struct Group {
        var members: [Int]
        var newest: Date
        var isDevice = false
    }

    /// The frame shown first, then the others in timeline order.
    static func ordered<Item: CopyStackCandidate>(_ members: [Int], _ items: [Item], evidence: (any BurstEvidence)?) -> [Int] {
        let sorted = members.sorted()
        // The copy of each frame that would be shown (`CopyStacks.rank`), by frame.
        var frames: [String: Int] = [:]
        var frameOrder: [String] = []
        for index in sorted {
            let key = CopyStacks.baseName(items[index].name)
            if let known = frames[key] {
                if (CopyStacks.rank(items[index]), index) < (CopyStacks.rank(items[known]), known) { frames[key] = index }
            } else {
                frames[key] = index
                frameOrder.append(key)
            }
        }
        let shown = frameOrder.compactMap { frames[$0] }
        var leader: Int?
        if let evidence {
            let signals = evidence.signals(of: shown.map { items[$0].fileId })
            if !signals.isEmpty {
                // Oldest first, as a burst was taken.
                let candidates = shown.reversed().map { index in
                    BestShot.Candidate(id: items[index].fileId, signals: signals[items[index].fileId], isFavorite: items[index].isFavorite)
                }
                if let best = BestShot.choose(candidates)?.best { leader = shown.first { items[$0].fileId == best } }
            }
        }
        if leader == nil {
            leader = shown.min { first, second in
                let a = (items[first].isFavorite ? 0 : 1, marker(items[first].name)?.isCover == true ? 0 : 1)
                let b = (items[second].isFavorite ? 0 : 1, marker(items[second].name)?.isCover == true ? 0 : 1)
                return (a.0, a.1, CopyStacks.rank(items[first]), first) < (b.0, b.1, CopyStacks.rank(items[second]), second)
            }
        }
        guard let leader else { return sorted }
        return [leader] + sorted.filter { $0 != leader }
    }
}

/// What this device worked out about some photos, for bursts that no file name marks (`TimeBursts`) and for the frame
/// a burst shows (`BestShot`). Read from the account's database (`BestShotStore`); nothing is computed while asked.
public protocol BurstEvidence: Sendable {
    /// The sketches of the indexed photos among `ids` ("Show Similar"), widened to floats.
    func sketches(of ids: [FileID]) -> [FileID: [Float]]
    /// The best-shot analysis of the analysed photos among `ids`.
    func signals(of ids: [FileID]) -> [FileID: BestShot.Signals]
}

/// Bursts no file name marks, such as the frames of an iPhone burst uploaded one by one (`IMG_4410.HEIC` …
/// `IMG_4425.HEIC`): images in one folder, each taken at most `maximumGap` after the one before, at least
/// `minimumFrames` frames and `minimumRate` frames a second on average, and every frame alike to the one before
/// (`Similarity.seriesThreshold`, by the sketches "Show Similar" made). A few quick single shots of one scene are slower
/// than that and stay apart, as in Photos; a run whose photos were not compared yet is not stacked until they are.
public enum TimeBursts {
    /// Seconds between two frames (capture times on the server are whole seconds).
    public static let maximumGap: TimeInterval = 1
    public static let minimumFrames = 3
    /// Frames a second over the burst: a burst shoots ten, a quick thumb two at most.
    public static let minimumRate: Double = 2

    /// The bursts among `items` (timeline order) that are in no stack yet, as positions in time order (newest first).
    static func runs<Item: CopyStackCandidate>(_ items: [Item], excluding taken: Set<Int>, evidence: any BurstEvidence) -> [[Int]] {
        var result: [[Int]] = []
        var run: [Int] = []
        func flush() {
            defer { run.removeAll(keepingCapacity: true) }
            guard isFast(run, items) else { return }
            result += confirmed(run, items, evidence: evidence)
        }
        for index in items.indices where !items[index].isVideo && !taken.contains(index) {
            if let last = run.last, items[last].directory == items[index].directory,
                abs(items[last].timestamp.timeIntervalSince(items[index].timestamp)) <= maximumGap
            {
                run.append(index)
            } else {
                flush()
                run.append(index)
            }
        }
        flush()
        return result
    }

    /// Enough frames, quickly enough. Copies of a frame (HEIC + JPEG) count once.
    static func isFast<Item: CopyStackCandidate>(_ run: [Int], _ items: [Item]) -> Bool {
        let frames = Set(run.map { CopyStacks.baseName(items[$0].name) }).count
        guard frames >= minimumFrames, let first = run.first, let last = run.last else { return false }
        let span = abs(items[first].timestamp.timeIntervalSince(items[last].timestamp))
        // Whole seconds: a span of 0 s is up to one second.
        return Double(frames) / (span.rounded(.down) + 1) >= minimumRate
    }

    /// The parts of a fast run whose frames are alike, each again fast enough.
    static func confirmed<Item: CopyStackCandidate>(_ run: [Int], _ items: [Item], evidence: any BurstEvidence) -> [[Int]] {
        let sketches = evidence.sketches(of: run.map { items[$0].fileId })
        var result: [[Int]] = []
        var part: [Int] = []
        var lastSketch: [Float]?
        func close() {
            if isFast(part, items) { result.append(part) }
            part = []
        }
        for index in run {
            // Copies of the frame before (same name, another format) belong to it whatever their sketch.
            if let previous = part.last, CopyStacks.baseName(items[previous].name) == CopyStacks.baseName(items[index].name) {
                part.append(index)
                continue
            }
            guard let sketch = sketches[items[index].fileId] else {
                // Not compared yet: no stack across it.
                close()
                lastSketch = nil
                continue
            }
            if let lastSketch, Similarity.cosine(lastSketch, sketch) < Similarity.seriesThreshold { close() }
            part.append(index)
            lastSketch = sketch
        }
        close()
        return result
    }
}

/// Everything the timeline stacks: bursts (`BurstStacks`) and copies of one shot (`CopyStacks`).
public enum TimelineStacks {
    /// A stack and what kind it is.
    public struct Stack: Sendable, Equatable {
        /// Positions in the items, the one shown first.
        public var members: [Int]
        public var isBurst: Bool
    }

    /// The stacks among `items` (newest first), each as positions with the one shown first. A copy stack whose files
    /// are frames of a burst is part of that burst.
    public static func stacks<Item: CopyStackCandidate>(_ items: [Item], bursts: Bool = true, evidence: (any BurstEvidence)? = nil)
        -> [[Int]]
    {
        classified(items, bursts: bursts, evidence: evidence).map(\.members)
    }

    /// The same, saying which stacks are bursts (VoiceOver says "Burst of 5 photos" rather than "5 copies").
    public static func classified<Item: CopyStackCandidate>(_ items: [Item], bursts: Bool = true, evidence: (any BurstEvidence)? = nil)
        -> [Stack]
    {
        let copies = CopyStacks.stacks(items)
        guard bursts else { return copies.map { Stack(members: $0, isBurst: false) } }
        let burstStacks = BurstStacks.stacks(items, evidence: evidence)
        guard !burstStacks.isEmpty else { return copies.map { Stack(members: $0, isBurst: false) } }
        var inBurst = Set<Int>()
        for stack in burstStacks { inBurst.formUnion(stack) }
        let merged =
            burstStacks.map { Stack(members: $0, isBurst: true) }
            + copies.filter { stack in !stack.contains { inBurst.contains($0) } }.map { Stack(members: $0, isBurst: false) }
        return merged.sorted { ($0.members.min() ?? 0) < ($1.members.min() ?? 0) }
    }

    /// Whether the tile `leader` stands for a burst the camera named (its VoiceOver label says so).
    public static func isBurst(leaderName: String) -> Bool {
        BurstStacks.marker(leaderName) != nil
    }
}
