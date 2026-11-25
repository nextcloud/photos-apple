// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// How much room smart offline may take on the device (SPEC §15.8.1).
public enum SmartOfflineBudget: String, CaseIterable, Sendable, Codable {
    case off, small, medium, large

    public static let `default`: SmartOfflineBudget = .small

    /// The room in bytes (decimal gigabytes, as the system's storage settings count).
    public var bytes: Int64 {
        switch self {
        case .off: 0
        case .small: 1_000_000_000
        case .medium: 5_000_000_000
        case .large: 20_000_000_000
        }
    }
}

/// What smart offline keeps of a photo.
public enum SmartOfflineQuality: String, CaseIterable, Sendable, Codable {
    /// A preview as large as a screen shows it (`SmartOfflinePolicy.previewSize` long edge).
    case screen
    /// The original file.
    case original
}

/// Why a photo is kept: the reason with the highest score.
public enum SmartOfflineReason: String, Sendable, Codable, Hashable, CaseIterable {
    /// Its "On this day" comes up in the next days.
    case onThisDay
    case favorite
    /// Taken in the last months.
    case recent
    /// In an album that was opened recently.
    case album
}

/// A photo that smart offline could keep, as the index knows it.
public struct SmartOfflineCandidate: Sendable, Hashable {
    public var fileId: FileID
    public var etag: String
    public var timestamp: Date
    public var isFavorite: Bool
    public var kind: MediaKind
    /// Size of the original in bytes (0 when unknown).
    public var size: Int64
    /// When an album that contains it was last opened.
    public var albumViewedAt: Date?

    public init(
        fileId: FileID, etag: String, timestamp: Date, isFavorite: Bool = false, kind: MediaKind = .image, size: Int64 = 0,
        albumViewedAt: Date? = nil
    ) {
        self.fileId = fileId
        self.etag = etag
        self.timestamp = timestamp
        self.isFavorite = isFavorite
        self.kind = kind
        self.size = size
        self.albumViewedAt = albumViewedAt
    }
}

/// A candidate with its score; higher is kept first.
public struct SmartOfflineRanked: Sendable, Hashable {
    public var candidate: SmartOfflineCandidate
    public var score: Double
    public var reason: SmartOfflineReason

    public var fileId: FileID { candidate.fileId }
}

/// A file smart offline has on the device.
public struct SmartOfflineKept: Sendable, Hashable {
    public var fileId: FileID
    public var etag: String
    public var bytes: Int64
    /// When it was last shown (or downloaded, when it was never shown).
    public var lastUsed: Date
    public var quality: SmartOfflineQuality

    public init(fileId: FileID, etag: String, bytes: Int64, lastUsed: Date, quality: SmartOfflineQuality = .screen) {
        self.fileId = fileId
        self.etag = etag
        self.bytes = bytes
        self.lastUsed = lastUsed
        self.quality = quality
    }
}

/// What a pass does: what to download (best first) and what to remove.
public struct SmartOfflinePlan: Sendable, Equatable {
    public var downloads: [SmartOfflineRanked]
    /// Files to delete: those that are no longer wanted at all first (gone, archived, changed), then the least recently used
    /// of the rest, as far as room is needed.
    public var evictions: [FileID]
    /// Everything that is kept or will be when the downloads are through.
    public var wanted: Set<FileID>
    /// Bytes the wanted files take (estimated for those not downloaded yet).
    public var wantedBytes: Int64
}

/// Which photos are worth having without network, and which go when room is needed (SPEC §15.8.1). Pure and deterministic,
/// so the whole policy is unit-tested; `SmartOfflineManager` feeds it from the index and carries it out.
///
/// Every candidate gets a score in 0…1 for each reason that applies; its score is the highest of them:
/// - **On this day** in the next `upcomingDays` days (today included): 1.0, a bit less each day further away. These are
///   the memories the app is about to show.
/// - **Recent**: taken in the last `recentMonths` months: 0.9, halving every `recentHalfLife` days (60 days old: 0.45).
/// - **Album opened recently** (within `albumWindowDays` days): 0.6, halving every 7 days since it was opened.
/// - **Favourite**: 0.35 – 0.55, newer favourites a little higher (halving of the extra every two years).
///
/// The wanted set is the best-scored candidates whose sizes add up to the budget. Files that are kept but no longer wanted
/// stay until their room is needed; then the least recently used go first (LRU).
public enum SmartOfflinePolicy {
    public static let recentMonths = 12
    public static let recentHalfLife: Double = 60
    public static let upcomingDays = 7
    public static let albumWindowDays: Double = 30
    /// Long edge of a kept preview in pixels: what fills an iPhone or iPad screen.
    public static let previewSize = 2048
    /// What a preview is assumed to take before real ones were measured.
    public static let defaultPreviewBytes: Int64 = 450_000
    /// Originals whose size is unknown are assumed to take this.
    public static let defaultOriginalBytes: Int64 = 3_000_000

    /// The score and reason of one candidate, or nil when no reason applies.
    public static func score(
        _ candidate: SmartOfflineCandidate, now: Date, calendar: Calendar = .current
    ) -> (score: Double, reason: SmartOfflineReason)? {
        var best: (score: Double, reason: SmartOfflineReason)?
        func consider(_ score: Double, _ reason: SmartOfflineReason) {
            if score > (best?.score ?? 0) { best = (score, reason) }
        }
        if let days = daysUntilOnThisDay(candidate.timestamp, now: now, calendar: calendar) {
            consider(1.0 - 0.01 * Double(days), .onThisDay)
        }
        let age = now.timeIntervalSince(candidate.timestamp) / 86_400
        if let start = calendar.date(byAdding: .month, value: -recentMonths, to: now), candidate.timestamp >= start {
            consider(0.9 * pow(0.5, max(0, age) / recentHalfLife), .recent)
        }
        if let viewed = candidate.albumViewedAt {
            let since = max(0, now.timeIntervalSince(viewed) / 86_400)
            if since <= albumWindowDays { consider(0.6 * pow(0.5, since / 7), .album) }
        }
        if candidate.isFavorite {
            consider(0.35 + 0.2 * pow(0.5, max(0, age) / 730), .favorite)
        }
        return best
    }

    /// In how many days (0 = today, up to `upcomingDays - 1`) the photo's month and day come round in a later year; nil when
    /// that is further away, or the photo is from this year.
    public static func daysUntilOnThisDay(_ date: Date, now: Date, calendar: Calendar = .current) -> Int? {
        let year = calendar.component(.year, from: now)
        guard calendar.component(.year, from: date) < year else { return nil }
        let today = calendar.startOfDay(for: now)
        for offset in 0..<upcomingDays {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            let parts = calendar.dateComponents([.month, .day], from: day)
            let photo = calendar.dateComponents([.year, .month, .day], from: date)
            if photo.month == parts.month && photo.day == parts.day && (photo.year ?? year) < calendar.component(.year, from: day) {
                return offset
            }
        }
        return nil
    }

    /// Candidates with a reason, best first. Ties: newer first, then the higher file id (stable across runs).
    public static func rank(_ candidates: [SmartOfflineCandidate], now: Date, calendar: Calendar = .current) -> [SmartOfflineRanked] {
        candidates.compactMap { candidate in
            score(candidate, now: now, calendar: calendar).map {
                SmartOfflineRanked(candidate: candidate, score: $0.score, reason: $0.reason)
            }
        }
        .sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.candidate.timestamp != b.candidate.timestamp { return a.candidate.timestamp > b.candidate.timestamp }
            return a.fileId > b.fileId
        }
    }

    /// What is kept of a photo: videos always as previews (one video would take the room of hundreds of photos; offline
    /// albums keep videos), photos as chosen.
    public static func quality(of kind: MediaKind, chosen: SmartOfflineQuality) -> SmartOfflineQuality {
        kind == .video ? .screen : chosen
    }

    /// What a candidate will take (an estimate until it is downloaded).
    public static func estimatedBytes(
        _ candidate: SmartOfflineCandidate, quality: SmartOfflineQuality, previewBytes: Int64 = defaultPreviewBytes
    ) -> Int64 {
        switch Self.quality(of: candidate.kind, chosen: quality) {
        case .screen: return previewBytes
        case .original: return candidate.size > 0 ? candidate.size : defaultOriginalBytes
        }
    }

    /// The pass: what is wanted within `budget`, what to download, what to evict.
    ///
    /// - Parameters:
    ///   - ranked: `rank(_:)` of every candidate.
    ///   - kept: what is on the device now.
    ///   - present: the ETags of kept photos the library still shows, also those no reason applies to any more. A kept file
    ///     whose photo is missing here (deleted, archived, in an excluded folder) is removed at once.
    ///   - previewBytes: the average size of the previews kept so far (better than the default estimate).
    public static func plan(
        ranked: [SmartOfflineRanked], kept: [SmartOfflineKept], present: [FileID: String] = [:], budget: Int64,
        quality: SmartOfflineQuality, previewBytes: Int64 = defaultPreviewBytes
    ) -> SmartOfflinePlan {
        let keptById = Dictionary(kept.map { ($0.fileId, $0) }, uniquingKeysWith: { first, _ in first })
        let candidates = Dictionary(ranked.map { ($0.fileId, $0) }, uniquingKeysWith: { first, _ in first })
        // A kept file is still good when the library shows its photo with the same ETag and, for a candidate, it has the
        // quality asked for (one that is no candidate any more just waits for its room to be needed).
        func isCurrent(_ file: SmartOfflineKept) -> Bool {
            if let candidate = candidates[file.fileId]?.candidate {
                return candidate.etag == file.etag && file.quality == Self.quality(of: candidate.kind, chosen: quality)
            }
            return present[file.fileId] == file.etag
        }
        var wanted: Set<FileID> = []
        var wantedBytes: Int64 = 0
        var downloads: [SmartOfflineRanked] = []
        if budget > 0 {
            for entry in ranked {
                let current = keptById[entry.fileId].flatMap { isCurrent($0) ? $0 : nil }
                let cost = current?.bytes ?? estimatedBytes(entry.candidate, quality: quality, previewBytes: max(1, previewBytes))
                // Smaller ones further down may still fit (originals differ in size).
                guard wantedBytes + cost <= budget else { continue }
                wanted.insert(entry.fileId)
                wantedBytes += cost
                if current == nil { downloads.append(entry) }
            }
        }
        // Stale files go in any case; then, as long as the kept files and the downloads would not fit, the least recently
        // used of those that are not wanted any more.
        var evictions: [FileID] = []
        var unwanted: [SmartOfflineKept] = []
        for file in kept {
            if !isCurrent(file) {
                evictions.append(file.fileId)
            } else if !wanted.contains(file.fileId) {
                unwanted.append(file)
            }
        }
        // The wanted files (kept or estimated) plus what is kept without being wanted.
        var total = wantedBytes + unwanted.reduce(0) { $0 + $1.bytes }
        for file in unwanted.sorted(by: { ($0.lastUsed, $0.fileId) < ($1.lastUsed, $1.fileId) }) where total > budget {
            evictions.append(file.fileId)
            total -= file.bytes
        }
        return SmartOfflinePlan(downloads: downloads, evictions: evictions, wanted: wanted, wantedBytes: wantedBytes)
    }

    /// Whether a pass may download now: on Wi-Fi or Ethernet (not cellular, not a hotspot, not Low Data Mode), and not in
    /// Low Power Mode. Removing files never waits for this.
    public static func mayDownload(isConnected: Bool, isExpensive: Bool, isConstrained: Bool, isLowPowerMode: Bool) -> Bool {
        isConnected && !isExpensive && !isConstrained && !isLowPowerMode
    }
}

/// What the kept photos cover, for Settings and the offline banner.
public struct SmartOfflineSummary: Sendable, Equatable {
    public var count: Int
    public var bytes: Int64
    /// The oldest photo kept because it is recent: "back to <month>".
    public var recentSince: Date?
    public var favorites: Int
    public var albums: Int
    public var onThisDay: Int

    public init(count: Int = 0, bytes: Int64 = 0, recentSince: Date? = nil, favorites: Int = 0, albums: Int = 0, onThisDay: Int = 0) {
        self.count = count
        self.bytes = bytes
        self.recentSince = recentSince
        self.favorites = favorites
        self.albums = albums
        self.onThisDay = onThisDay
    }
}
