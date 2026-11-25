// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// The capture time as the camera recorded it. Nextcloud reads an EXIF time without an offset as UTC (the server always
/// runs in UTC), so the recorded wall-clock time of a photo is its capture time in its own offset, or in UTC when it
/// has none.
public enum RecordedTime {
    public static func offset(of item: MediaItem) -> Int { item.captureOffset ?? 0 }

    /// The calendar of a fixed offset.
    public static func calendar(offset: Int) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: offset) ?? .gmt
        return calendar
    }
}

/// Moves capture times (SPEC §16.4 batch fixes): a shift for a camera clock that was wrong, and a time zone for one that
/// was right but in another zone than recorded.
public struct DateAdjustment: Hashable, Sendable {
    /// Seconds added to every capture time.
    public var shift: TimeInterval
    /// The time zone the photos were taken in: the recorded wall-clock time stays, read in this zone. Nil keeps the zone.
    public var timeZone: TimeZone?

    public init(shift: TimeInterval = 0, timeZone: TimeZone? = nil) {
        self.shift = shift
        self.timeZone = timeZone
    }

    public var isEmpty: Bool { shift == 0 && timeZone == nil }

    /// The new capture time of a photo.
    public func adjusted(_ item: MediaItem) -> Date {
        var date = item.timestamp
        if let timeZone {
            let recorded = RecordedTime.offset(of: item)
            // Same wall clock, other zone: the instant moves by the difference of the two offsets.
            date = date.addingTimeInterval(TimeInterval(recorded - timeZone.secondsFromGMT(for: wallClockDate(item))))
        }
        return date.addingTimeInterval(shift)
    }

    /// The UTC offset of the new capture time, when the adjustment sets a zone; else the photo's own.
    public func adjustedOffset(_ item: MediaItem) -> Int? {
        guard let timeZone else { return item.captureOffset }
        return timeZone.secondsFromGMT(for: adjusted(item))
    }

    /// The recorded wall-clock time as if it were UTC (for asking a zone its offset on that day).
    func wallClockDate(_ item: MediaItem) -> Date {
        item.timestamp.addingTimeInterval(TimeInterval(RecordedTime.offset(of: item)))
    }

    /// The shift that makes `first` become `target`: "set the date of the first photo, keep the intervals".
    public static func shift(from first: Date, to target: Date) -> TimeInterval {
        target.timeIntervalSince(first).rounded()
    }
}

/// File names from a pattern (SPEC §16.4): `{date} {place} {counter}` → `2024-06-14 Rome 001.jpg`.
///
/// Tokens: `{name}` (the name without extension), `{date}` (yyyy-MM-dd), `{time}` (HH-mm-ss), `{year}`, `{month}`,
/// `{day}`, `{hour}`, `{minute}`, `{second}`, `{place}`, `{country}`, `{camera}`, `{counter}` and `{counter:N}` (N
/// digits, zero-padded; default 3). Times are the recorded wall-clock times (`RecordedTime`), as in the camera's own
/// file names. The extension stays. Unknown tokens stay as they are typed, so a typo is visible in the preview.
public struct RenamePattern: Hashable, Sendable {
    public var pattern: String
    /// The first counter value.
    public var start: Int

    public init(_ pattern: String, start: Int = 1) {
        self.pattern = pattern
        self.start = start
    }

    public static let tokens = [
        "{date}", "{time}", "{name}", "{place}", "{country}", "{camera}", "{counter}", "{year}", "{month}", "{day}",
    ]

    /// Characters Nextcloud or other systems do not take in a file name.
    static let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")

    /// The new names, in the order of `items`. The counter follows the capture time (oldest first); names are unique
    /// within the batch and against `existing` (other files' names in the same folders, by folder), with " (2)" etc.
    public func names(
        for items: [MediaItem], camera: [FileID: CameraDetails] = [:], existing: [String: Set<String>] = [:]
    ) -> [FileID: String] {
        let ordered = items.enumerated().sorted { ($0.element.timestamp, $0.offset) < ($1.element.timestamp, $1.offset) }
        var counters: [FileID: Int] = [:]
        for (position, entry) in ordered.enumerated() { counters[entry.element.fileId] = start + position }
        var taken: [String: Set<String>] = existing.mapValues { Set($0.map { $0.lowercased() }) }
        // A file keeps its own name free: renaming a file to the name it has is no collision.
        let batchIds = Set(items.map(\.fileId))
        for item in items where batchIds.contains(item.fileId) {
            taken[item.directory, default: []].remove(item.name.lowercased())
        }
        var result: [FileID: String] = [:]
        for item in items {
            let base = render(item, counter: counters[item.fileId] ?? start, camera: camera[item.fileId])
            let ext = (item.name as NSString).pathExtension
            var candidate = Self.join(base, ext)
            var suffix = 2
            while taken[item.directory, default: []].contains(candidate.lowercased()) {
                candidate = Self.join("\(base) (\(suffix))", ext)
                suffix += 1
            }
            taken[item.directory, default: []].insert(candidate.lowercased())
            result[item.fileId] = candidate
        }
        return result
    }

    static func join(_ base: String, _ ext: String) -> String { ext.isEmpty ? base : "\(base).\(ext)" }

    /// The name without extension for one photo.
    public func render(_ item: MediaItem, counter: Int, camera: CameraDetails? = nil) -> String {
        let calendar = RecordedTime.calendar(offset: RecordedTime.offset(of: item))
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: item.timestamp)
        func two(_ value: Int?) -> String { String(format: "%02d", value ?? 0) }
        let year = String(format: "%04d", parts.year ?? 0)
        var values: [String: String] = [
            "name": (item.name as NSString).deletingPathExtension,
            "year": year, "month": two(parts.month), "day": two(parts.day),
            "hour": two(parts.hour), "minute": two(parts.minute), "second": two(parts.second),
            "date": "\(year)-\(two(parts.month))-\(two(parts.day))",
            "time": "\(two(parts.hour))-\(two(parts.minute))-\(two(parts.second))",
            "place": item.place ?? "", "country": item.placeCountry.flatMap { Locale.current.localizedString(forRegionCode: $0) } ?? "",
            "camera": camera?.cameraName ?? "",
        ]
        values["counter"] = String(format: "%03d", counter)
        var output = ""
        var rest = Substring(pattern)
        while let open = rest.firstIndex(of: "{") {
            output += rest[rest.startIndex..<open]
            guard let close = rest[open...].firstIndex(of: "}") else {
                output += rest[open...]
                rest = ""
                break
            }
            let token = String(rest[rest.index(after: open)..<close])
            if token.hasPrefix("counter:"), let digits = Int(token.dropFirst("counter:".count)), (1...9).contains(digits) {
                output += String(format: "%0\(digits)d", counter)
            } else if let value = values[token.lowercased()] {
                output += value
            } else {
                output += rest[open...close]
            }
            rest = rest[rest.index(after: close)...]
        }
        output += rest
        return Self.sanitized(output, fallback: (item.name as NSString).deletingPathExtension)
    }

    /// A name the server takes: forbidden characters become "-", spaces collapse, no leading/trailing spaces or dots.
    static func sanitized(_ name: String, fallback: String) -> String {
        var cleaned = String(String.UnicodeScalarView(name.unicodeScalars.map { forbidden.contains($0) ? "-" : $0 }))
        while cleaned.contains("  ") { cleaned = cleaned.replacingOccurrences(of: "  ", with: " ") }
        cleaned = cleaned.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".-_ ")))
        return cleaned.isEmpty ? fallback : String(cleaned.prefix(200))
    }
}
