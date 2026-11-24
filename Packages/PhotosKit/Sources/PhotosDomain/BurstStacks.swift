// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// Bursts the camera itself marked as one (SPEC TL-6 a, the conservative part).
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
/// the same folder and were taken within `maximumSpan` of the burst's newest frame. The `COVER` frame is shown.
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

    /// The bursts among `items` (timeline order, newest first): positions in `items`, the frame shown first (the cover,
    /// else the newest frame; of its copies the one `CopyStacks` would show), then the others in timeline order. Copies
    /// of a frame (`…_BURST001.dng` beside `…_BURST001.jpg`) belong to the burst like any frame. Linear in the items.
    public static func stacks<Item: CopyStackCandidate>(_ items: [Item]) -> [[Int]] {
        var open: [String: Group] = [:]
        var result: [[Int]] = []
        func close(_ group: Group) {
            // At least two frames: copies of a single frame are left to `CopyStacks`.
            let frames = Set(group.members.lazy.map { CopyStacks.baseName(items[$0].name) })
            if frames.count > 1 { result.append(ordered(group.members, items)) }
        }
        for index in items.indices where !items[index].isVideo {
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
        return result.sorted { ($0.min() ?? 0) < ($1.min() ?? 0) }
    }

    /// A burst being collected: its frames so far and the time of the newest.
    private struct Group {
        var members: [Int]
        var newest: Date
    }

    private static func ordered<Item: CopyStackCandidate>(_ members: [Int], _ items: [Item]) -> [Int] {
        let leader = members.min { first, second in
            let a = (marker(items[first].name)?.isCover == true ? 0 : 1, CopyStacks.rank(items[first]), first)
            let b = (marker(items[second].name)?.isCover == true ? 0 : 1, CopyStacks.rank(items[second]), second)
            return a < b
        }
        guard let leader else { return members }
        return [leader] + members.filter { $0 != leader }
    }
}

/// Everything the timeline stacks: bursts the camera marked (`BurstStacks`) and copies of one shot (`CopyStacks`).
public enum TimelineStacks {
    /// The stacks among `items` (newest first), each as positions with the one shown first. A copy stack whose files
    /// are frames of a burst is part of that burst.
    public static func stacks<Item: CopyStackCandidate>(_ items: [Item], bursts: Bool = true) -> [[Int]] {
        let copies = CopyStacks.stacks(items)
        guard bursts else { return copies }
        let burstStacks = BurstStacks.stacks(items)
        guard !burstStacks.isEmpty else { return copies }
        var inBurst = Set<Int>()
        for stack in burstStacks { inBurst.formUnion(stack) }
        let merged = burstStacks + copies.filter { stack in !stack.contains { inBurst.contains($0) } }
        return merged.sorted { ($0.min() ?? 0) < ($1.min() ?? 0) }
    }

    /// Whether the tile `leader` stands for a burst (its VoiceOver label says so).
    public static func isBurst(leaderName: String) -> Bool {
        BurstStacks.marker(leaderName) != nil
    }
}
