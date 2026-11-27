// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// What stacking needs to know about a timeline item.
public protocol CopyStackCandidate {
    var fileId: FileID { get }
    var name: String { get }
    var directory: String { get }
    var timestamp: Date { get }
    var mimeType: String { get }
    var isVideo: Bool { get }
    var hasPreview: Bool { get }
    /// A favourite frame of a burst is its cover (`BurstStacks`). False where unknown.
    var isFavorite: Bool { get }
    /// The burst a photo of this device belongs to (PhotoKit's `burstIdentifier`); nil for files on the server, which do
    /// not carry it (`BurstStacks`).
    var burstIdentifier: String? { get }
}

extension CopyStackCandidate {
    public var isFavorite: Bool { false }
    public var burstIdentifier: String? { nil }
}

/// Copies of one shot that the timeline shows as one tile (SPEC TL-6, the conservative part): `IMG_1234.HEIC` next to
/// `IMG_1234.JPG`, or a RAW file next to the JPEG the camera wrote with it.
///
/// Deliberately strict, so two different photos are never hidden behind each other: the files must be images in the same
/// folder, with the same name apart from the extension (ignoring case), taken at most `maximumGap` apart. Bursts are not
/// stacked: their files have different names, and the server does not report Apple's burst identifier.
public enum CopyStacks {
    /// Capture times of the copies of one shot differ by at most this (cameras write RAW and JPEG a moment apart).
    public static let maximumGap: TimeInterval = 2

    /// Extensions of camera RAW files; such a copy is never the one shown when there is a JPEG or HEIC beside it.
    static let rawExtensions: Set<String> = [
        "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "pef", "srw", "x3f", "3fr", "iiq", "erf", "kdc",
        "mos", "mrw", "raw", "rwl",
    ]

    /// The name without extension, lower-cased and in canonical Unicode form: `IMG_1234.HEIC` and `img_1234.jpg` match.
    public static func baseName(_ fileName: String) -> String {
        let dot = fileName.lastIndex(of: ".")
        let base = dot.map { fileName[..<$0] } ?? fileName[...]
        return String(base).precomposedStringWithCanonicalMapping.lowercased()
    }

    static func fileExtension(_ fileName: String) -> String {
        guard let dot = fileName.lastIndex(of: ".") else { return "" }
        return fileName[fileName.index(after: dot)...].lowercased()
    }

    /// Which copy the tile shows, lower is better: one with a preview, then JPEG, then HEIC and other images, RAW last.
    static func rank(_ item: some CopyStackCandidate) -> Int {
        let format: Int
        if item.mimeType == "image/jpeg" {
            format = 0
        } else if rawExtensions.contains(fileExtension(item.name)) {
            format = 3
        } else if item.mimeType == "image/heic" || item.mimeType == "image/heif" {
            format = 1
        } else {
            format = 2
        }
        return (item.hasPreview ? 0 : 10) + format
    }

    /// The stacks among `items` (in timeline order, newest first): positions in `items`, the copy to show first and the
    /// others after it in timeline order. Items that are in no stack are not listed. Linear in the number of items: only
    /// items taken within `maximumGap` of each other are compared at all.
    public static func stacks<Item: CopyStackCandidate>(_ items: [Item]) -> [[Int]] {
        var result: [[Int]] = []
        var run: [Int] = []
        func flush() {
            defer { run.removeAll(keepingCapacity: true) }
            guard run.count > 1 else { return }
            result.append(contentsOf: stacks(inRun: run, items))
        }
        for index in items.indices {
            if let previous = run.last, abs(items[previous].timestamp.timeIntervalSince(items[index].timestamp)) <= maximumGap {
                run.append(index)
            } else {
                flush()
                run.append(index)
            }
        }
        flush()
        return result.sorted { $0.min() ?? 0 < $1.min() ?? 0 }
    }

    /// Stacks inside a run of items taken close together.
    private static func stacks<Item: CopyStackCandidate>(inRun run: [Int], _ items: [Item]) -> [[Int]] {
        var groups: [String: [Int]] = [:]
        var order: [String] = []
        for index in run where !items[index].isVideo {
            let key = items[index].directory + "/" + baseName(items[index].name)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(index)
        }
        var result: [[Int]] = []
        for key in order {
            guard let members = groups[key], members.count > 1 else { continue }
            // A long run can hold the same name twice only far apart: cut where the copies are more than the gap apart.
            var part: [Int] = []
            for index in members {
                if let first = part.first, abs(items[first].timestamp.timeIntervalSince(items[index].timestamp)) > maximumGap {
                    if part.count > 1 { result.append(ordered(part, items)) }
                    part = []
                }
                part.append(index)
            }
            if part.count > 1 { result.append(ordered(part, items)) }
        }
        return result
    }

    /// The copy shown first, then the others in timeline order.
    private static func ordered<Item: CopyStackCandidate>(_ members: [Int], _ items: [Item]) -> [Int] {
        guard let leader = members.min(by: { (rank(items[$0]), $0) < (rank(items[$1]), $1) }) else { return members }
        return [leader] + members.filter { $0 != leader }
    }
}
