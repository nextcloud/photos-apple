// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import PhotosModel

/// Where photos come from (SPEC §15.7).
public enum ImportSourceKind: String, Codable, Sendable, CaseIterable, Hashable {
    case googlePhotos, iCloudPhotos, facebook, instagram, photosLibrary, files

    /// The folder below the destination that the source's photos go to. Not translated: it is a folder on the server
    /// that every device and the web see under the same name, like the services' own names.
    public var folderName: String {
        switch self {
        case .googlePhotos: "Google Photos"
        case .iCloudPhotos: "iCloud Photos"
        case .facebook: "Facebook"
        case .instagram: "Instagram"
        case .photosLibrary: "Photos Library"
        case .files: "Imported"
        }
    }

    /// The service keeps reduced copies (smaller, re-encoded, metadata removed): a copy of a photo already in the
    /// library is not the same file, so `ImportMatcher` looks for it by its capture time alone.
    var keepsReducedCopies: Bool { self == .facebook || self == .instagram }
}

/// What an export says about a photo or video beyond the file itself.
public struct ImportMetadata: Hashable, Sendable, Codable {
    /// How exact `takenAt` is.
    public enum TimeSource: String, Hashable, Sendable, Codable {
        /// The capture time to the second (a Takeout sidecar, EXIF data the service kept, PhotoKit).
        case capture
        /// The capture time to the minute (Apple's data export drops the seconds).
        case captureMinute
        /// When the photo was posted, not when it was taken (Facebook, Instagram without camera data).
        case posted
    }

    public var takenAt: Date?
    public var timeSource: TimeSource = .capture
    public var latitude: Double?
    public var longitude: Double?
    public var altitude: Double?
    /// The caption or description the user wrote.
    public var caption: String?
    public var favorite = false
    /// Hidden or archived in the service: goes to the archive (SPEC §7.13).
    public var hidden = false
    /// Pixel size before the service reduced the photo, when the export says it.
    public var originalWidth: Int?
    public var originalHeight: Int?

    public init(
        takenAt: Date? = nil, timeSource: TimeSource = .capture, latitude: Double? = nil, longitude: Double? = nil,
        altitude: Double? = nil, caption: String? = nil, favorite: Bool = false, hidden: Bool = false
    ) {
        self.takenAt = takenAt
        self.timeSource = timeSource
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.caption = caption
        self.favorite = favorite
        self.hidden = hidden
    }

    public var hasLocation: Bool { latitude != nil && longitude != nil }
    /// The time is when the photo was taken (not when it was posted).
    public var isCaptureTime: Bool { takenAt != nil && timeSource != .posted }

    /// Adds what `other` knows and this does not; the capture time wins over a posting time, seconds over minutes.
    mutating func merge(_ other: ImportMetadata) {
        if let time = other.takenAt, takenAt == nil || other.timeSource.rank > timeSource.rank {
            takenAt = time
            timeSource = other.timeSource
        }
        if !hasLocation, other.hasLocation {
            latitude = other.latitude
            longitude = other.longitude
            altitude = other.altitude
        }
        if caption == nil { caption = other.caption }
        favorite = favorite || other.favorite
        hidden = hidden || other.hidden
        if originalWidth == nil {
            originalWidth = other.originalWidth
            originalHeight = other.originalHeight
        }
    }
}

extension ImportMetadata.TimeSource {
    var rank: Int {
        switch self {
        case .capture: 2
        case .captureMinute: 1
        case .posted: 0
        }
    }
}

/// One photo or video to import.
public struct ImportItem: Hashable, Sendable, Identifiable {
    public enum Origin: Hashable, Sendable {
        /// A file of an export.
        case file(ExportFiles.File)
        /// A resource of an asset of the Mac's Photos library.
        case asset(BackupResource)
    }

    /// Stable across runs of the same export (source, name, size and capture time), for resuming.
    public var id: String
    public var origin: Origin
    public var name: String
    public var size: UInt64
    public var kind: MediaKind
    public var source: ImportSourceKind
    public var metadata: ImportMetadata
    /// Titles of the albums it is in.
    public var albums: [String]
    /// Other sources that had the same photo (it is imported once).
    public var alsoIn: Set<ImportSourceKind> = []

    public init(
        id: String? = nil, origin: Origin, name: String, size: UInt64, kind: MediaKind, source: ImportSourceKind,
        metadata: ImportMetadata = ImportMetadata(), albums: [String] = []
    ) {
        self.origin = origin
        self.name = name
        self.size = size
        self.kind = kind
        self.source = source
        self.metadata = metadata
        self.albums = albums
        self.id = id ?? Self.key(source: source, name: name, size: size, takenAt: metadata.takenAt)
    }

    public var takenAt: Date? { metadata.takenAt }

    static func key(source: ImportSourceKind, name: String, size: UInt64, takenAt: Date?) -> String {
        "\(source.rawValue)|\(name.lowercased())|\(size)|\(takenAt.map { String(Int64($0.timeIntervalSince1970)) } ?? "-")"
    }
}

/// An album of an export, recreated as a Photos album.
public struct ImportAlbum: Hashable, Sendable {
    public var title: String
    public var source: ImportSourceKind

    public init(title: String, source: ImportSourceKind) {
        self.title = title
        self.source = source
    }
}

/// Why something in an export is not imported. The summary and the report list each reason with its count.
public enum ImportSkipReason: String, Codable, Sendable, CaseIterable, Comparable {
    /// In the service's trash ("Recently Deleted", "Trash", `trashed`, `deleted=yes`).
    case deleted
    /// Photos in conversations (Facebook and Instagram messages): mostly other people's.
    case messages
    /// The export's index names a file that is in none of the chosen files (a ZIP part is missing).
    case missingFile
    /// A file the Photos app cannot show (other than the export's own index files).
    case unsupportedType
    /// An index file of the export could not be read.
    case unreadableIndex
    /// Apple's export lists photos without their files (Advanced Data Protection is on).
    case listedWithoutFile

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// What the chosen exports hold, ready to import.
public struct ImportPlan: Sendable {
    public var items: [ImportItem]
    /// Album titles in the order they first appear (with the source they come from).
    public var albums: [ImportAlbum]
    /// Things that are not imported, by reason, with a few example names each.
    public var skipped: [ImportSkipReason: Int]
    public var skippedExamples: [ImportSkipReason: [String]]
    /// Copies of the same file within one export (a year folder and album folders), imported once.
    public var duplicatesInExport: Int
    /// The same photo in two of the chosen exports (Google and Apple), imported once.
    public var duplicatesAcrossSources: Int
    /// Photos and videos the export has no details for (they keep the date in their own metadata).
    public var withoutDetails: Int
    /// Identifies the plan for the resume journal.
    public var key: String

    public init(
        items: [ImportItem], albums: [ImportAlbum] = [], skipped: [ImportSkipReason: Int] = [:],
        skippedExamples: [ImportSkipReason: [String]] = [:], duplicatesInExport: Int = 0, duplicatesAcrossSources: Int = 0,
        withoutDetails: Int = 0
    ) {
        self.items = items
        self.albums = albums
        self.skipped = skipped
        self.skippedExamples = skippedExamples
        self.duplicatesInExport = duplicatesInExport
        self.duplicatesAcrossSources = duplicatesAcrossSources
        self.withoutDetails = withoutDetails
        let digest = SHA256.hash(data: Data(items.map(\.id).sorted().joined(separator: "\n").utf8))
        key = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    public var totalBytes: UInt64 { items.reduce(0) { $0 + $1.size } }
    public var photoCount: Int { items.count { $0.kind == .image } }
    public var videoCount: Int { items.count { $0.kind == .video } }

    /// The sources in the plan, the biggest first.
    public var sources: [(source: ImportSourceKind, count: Int)] {
        let counts = Dictionary(grouping: items, by: \.source).mapValues(\.count)
        return counts.map { ($0.key, $0.value) }.sorted { ($0.count, $1.source.rawValue) > ($1.count, $0.source.rawValue) }
    }

    /// The first and last capture year (posting times count too: they are the best date there is for those).
    public var years: ClosedRange<Int>? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let years = items.compactMap { $0.takenAt.map { calendar.component(.year, from: $0) } }
        guard let first = years.min(), let last = years.max() else { return nil }
        return first...last
    }
}

/// What one source adapter found in the files it recognised.
struct ImportFindings {
    var items: [ImportItem] = []
    var albums: [ImportAlbum] = []
    var skipped: [ImportSkipReason: Int] = [:]
    var skippedExamples: [ImportSkipReason: [String]] = [:]
    var duplicates = 0
    var withoutDetails = 0
    /// Files of the export the adapter read or imports; the next adapters leave them alone.
    var claimed = Set<Int>()

    mutating func skip(_ reason: ImportSkipReason, _ name: String, count: Int = 1) {
        skipped[reason, default: 0] += count
        if skippedExamples[reason, default: []].count < 5 { skippedExamples[reason, default: []].append(name) }
    }

    mutating func addAlbum(_ title: String, source: ImportSourceKind) {
        if !albums.contains(where: { $0.title == title }) { albums.append(ImportAlbum(title: title, source: source)) }
    }

    /// Adds an item unless the same file (name, size, time) was added already; then only its albums and details are
    /// added to the first one. Returns whether the item is new.
    @discardableResult
    mutating func add(_ item: ImportItem, index: inout [String: Int]) -> Bool {
        if let existing = index[item.id] {
            duplicates += 1
            for album in item.albums where !items[existing].albums.contains(album) { items[existing].albums.append(album) }
            items[existing].metadata.merge(item.metadata)
            return false
        }
        index[item.id] = items.count
        items.append(item)
        return true
    }
}

/// A source adapter: recognises the files of one service's export and turns them into items and albums.
protocol ExportAdapter {
    static var source: ImportSourceKind { get }
    /// Reads the files not claimed by an adapter before it.
    static func read(_ files: ExportFiles, unclaimed: [Int]) throws -> ImportFindings
}

/// Builds the plan for what the user picked: every adapter looks at the files the ones before it left (Meta's indexes
/// name their media, so they go first; Apple's CSV files claim their folders; Google's sidecars and folders next; any
/// other photo is imported as a plain file). The same photo found in two exports is imported once.
public enum ImportPlanner {
    static let adapters: [any ExportAdapter.Type] = [
        InstagramExport.self, FacebookExport.self, AppleICloudExport.self, GoogleTakeoutExport.self, PlainFilesExport.self,
    ]

    public static func plan(_ files: ExportFiles, extra: [ImportItem] = [], extraAlbums: [ImportAlbum] = []) throws -> ImportPlan {
        var unclaimed = Array(files.files.indices)
        var findings: [ImportFindings] = []
        for adapter in adapters {
            try Task.checkCancellation()
            let found = try adapter.read(files, unclaimed: unclaimed)
            if !found.claimed.isEmpty { unclaimed.removeAll { found.claimed.contains($0) } }
            findings.append(found)
        }
        var items = extra
        var albums = extraAlbums
        var skipped: [ImportSkipReason: Int] = [:]
        var examples: [ImportSkipReason: [String]] = [:]
        var duplicates = 0
        var withoutDetails = 0
        for found in findings {
            items += found.items
            for album in found.albums where !albums.contains(album) { albums.append(album) }
            skipped.merge(found.skipped, uniquingKeysWith: +)
            examples.merge(found.skippedExamples) { Array(($0 + $1).prefix(5)) }
            duplicates += found.duplicates
            withoutDetails += found.withoutDetails
        }
        let merged = mergeAcrossSources(items)
        let sorted = merged.items.sorted {
            ($0.takenAt ?? .distantPast, $0.id) < ($1.takenAt ?? .distantPast, $1.id)
        }
        return ImportPlan(
            items: sorted, albums: albums, skipped: skipped, skippedExamples: examples, duplicatesInExport: duplicates,
            duplicatesAcrossSources: merged.merged, withoutDetails: withoutDetails)
    }

    /// The same photo in two exports: the same name and size (Google keeps originals as Apple does), or the same kind,
    /// size and capture second. Apple's times have no seconds, so there the minute must agree. The copy with the better
    /// details is kept (a capture time to the second over one to the minute) and gets the albums, captions and
    /// favourites of the others.
    static func mergeAcrossSources(_ items: [ImportItem]) -> (items: [ImportItem], merged: Int) {
        var result: [ImportItem] = []
        var byNameSize: [String: Int] = [:]
        var bySizeMinute: [String: [Int]] = [:]
        var merged = 0
        func minute(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970) / 60 }
        for item in items {
            let nameKey = "\(item.name.lowercased())|\(item.size)"
            var existing = byNameSize[nameKey].flatMap { result[$0].source != item.source ? $0 : nil }
            if existing == nil, item.metadata.isCaptureTime, let time = item.takenAt {
                let sizeKey = "\(item.kind)|\(item.size)|\(minute(time))"
                existing = bySizeMinute[sizeKey]?.first { index in
                    let other = result[index]
                    guard other.source != item.source, let otherTime = other.takenAt, other.metadata.isCaptureTime else { return false }
                    if item.metadata.timeSource == .capture && other.metadata.timeSource == .capture {
                        return Int64(otherTime.timeIntervalSince1970) == Int64(time.timeIntervalSince1970)
                    }
                    return true
                }
            }
            if let existing {
                merged += 1
                var kept = result[existing]
                var other = item
                if item.metadata.timeSource.rank > kept.metadata.timeSource.rank { swap(&kept, &other) }
                kept.metadata.merge(other.metadata)
                for album in other.albums where !kept.albums.contains(album) { kept.albums.append(album) }
                kept.alsoIn.insert(other.source)
                kept.alsoIn.formUnion(other.alsoIn)
                kept.alsoIn.remove(kept.source)
                result[existing] = kept
                continue
            }
            let index = result.count
            result.append(item)
            byNameSize[nameKey] = index
            if item.metadata.isCaptureTime, let time = item.takenAt {
                bySizeMinute["\(item.kind)|\(item.size)|\(minute(time))", default: []].append(index)
            }
        }
        return (result, merged)
    }
}

/// Every photo or video no other adapter claimed: imported as it is, the date from its own metadata.
enum PlainFilesExport: ExportAdapter {
    static let source = ImportSourceKind.files

    static func read(_ files: ExportFiles, unclaimed: [Int]) throws -> ImportFindings {
        var found = ImportFindings()
        var index: [String: Int] = [:]
        for position in unclaimed {
            let file = files.files[position]
            guard !file.name.hasPrefix("."), !file.path.contains("__MACOSX/") else { continue }
            if MetaExport.isConversation(file.path), ExportFiles.kind(of: file.name) != nil {
                found.skip(.messages, file.name)
                continue
            }
            guard let kind = ExportFiles.kind(of: file.name) else {
                if !ExportFiles.documentExtensions.contains(file.pathExtension) { found.skip(.unsupportedType, file.name) }
                continue
            }
            found.claimed.insert(position)
            found.withoutDetails += 1
            found.add(ImportItem(origin: .file(file), name: file.name, size: file.size, kind: kind, source: source), index: &index)
        }
        return found
    }
}
