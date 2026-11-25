// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// A photo that could be the photo of the day, as the index knows it.
public struct DailyPhotoCandidate: Sendable, Hashable {
    public var fileId: FileID
    public var timestamp: Date
    public var isFavorite: Bool
    public var width: Int
    public var height: Int
    public var name: String
    public var mimeType: String
    public var place: String?
    /// Somebody is recognised in it (a person of the Recognize app).
    public var hasPeople: Bool

    public init(
        fileId: FileID, timestamp: Date, isFavorite: Bool = false, width: Int = 4032, height: Int = 3024, name: String = "IMG.jpg",
        mimeType: String = "image/jpeg", place: String? = nil, hasPeople: Bool = false
    ) {
        self.fileId = fileId
        self.timestamp = timestamp
        self.isFavorite = isFavorite
        self.width = width
        self.height = height
        self.name = name
        self.mimeType = mimeType
        self.place = place
        self.hasPeople = hasPeople
    }

    public init(_ item: MediaItem, hasPeople: Bool = false) {
        self.init(
            fileId: item.fileId, timestamp: item.timestamp, isFavorite: item.isFavorite, width: item.width ?? 0, height: item.height ?? 0,
            name: item.name, mimeType: item.mimeType, place: item.place, hasPeople: hasPeople)
    }
}

/// The photo chosen for a day and why.
public struct DailyPhotoChoice: Sendable, Hashable {
    public enum Reason: Sendable, Hashable {
        /// Taken on this day so many years ago.
        case yearsAgo(Int)
        /// Taken a few days before or after this day, so many years ago.
        case aroundThisDay(Int)
        /// A favourite (no photo of this day was good enough).
        case favorite
    }

    public var fileId: FileID
    public var reason: Reason
    public var takenAt: Date
    public var place: String?
}

/// Picks the "Photo of the day" (SPEC §15.8.4): a good photo taken on this calendar day in an earlier year, else a favourite
/// that was not shown lately. Deterministic for a day, so rescheduling does not change a choice already made.
///
/// Callers pass only photos the library shows (no archived photos, no Live Photo videos, nothing in excluded folders).
public enum PhotoOfTheDay {
    /// A photo shown in this many days is not shown again (unless nothing else is left).
    public static let repeatWindowDays = 60

    /// How good a photo is as a photo of the day: favourites, people, a proper camera picture of reasonable shape.
    /// Screenshots and tiny images score below zero and are never chosen.
    public static func quality(_ candidate: DailyPhotoCandidate) -> Double {
        if isScreenshotLike(candidate) { return -1 }
        let pixels = Double(candidate.width) * Double(candidate.height)
        if candidate.width > 0 && candidate.height > 0 && pixels < 500_000 { return -1 }
        var score = 1.0
        if candidate.isFavorite { score += 3 }
        if candidate.hasPeople { score += 1.5 }
        if pixels >= 2_000_000 { score += 1 }
        if candidate.place?.isEmpty == false { score += 0.25 }
        if candidate.width > 0 && candidate.height > 0 {
            let aspect = Double(candidate.width) / Double(candidate.height)
            if aspect < 0.45 || aspect > 2.2 { score -= 1 }  // panoramas and slivers look poor in a notification
        }
        return score
    }

    /// Screenshots, screen recordings' stills and graphics: PNG/GIF files and names like "Screenshot…".
    static func isScreenshotLike(_ candidate: DailyPhotoCandidate) -> Bool {
        let mime = candidate.mimeType.lowercased()
        if mime == "image/png" || mime == "image/gif" { return true }
        let name = candidate.name.lowercased()
        return ["screenshot", "screen shot", "bildschirmfoto", "capture d", "captura de pantalla", "schermafbeelding"].contains {
            name.contains($0)
        }
    }

    /// Chooses the photo for `day`.
    /// - Parameters:
    ///   - onThisDay: photos taken within a few days of this day's date in earlier years (more is fine, they are filtered).
    ///   - favorites: favourites to fall back on.
    ///   - recentlyShown: photos shown as the photo of the day in the last `repeatWindowDays` days.
    public static func choose(
        for day: Date, onThisDay: [DailyPhotoCandidate], favorites: [DailyPhotoCandidate], recentlyShown: Set<FileID>,
        calendar: Calendar = .current
    ) -> DailyPhotoChoice? {
        let year = calendar.component(.year, from: day)
        let wanted = calendar.dateComponents([.month, .day], from: day)
        // The same calendar day first; the days next to it only when that day has nothing good.
        let sameDay = onThisDay.filter { candidate in
            let parts = calendar.dateComponents([.year, .month, .day], from: candidate.timestamp)
            return parts.month == wanted.month && parts.day == wanted.day && (parts.year ?? year) < year
        }
        let nearby = onThisDay.filter { calendar.component(.year, from: $0.timestamp) < year }
        for (pool, exact) in [(sameDay, true), (nearby, false)] {
            if let best = best(of: pool, day: day, excluding: recentlyShown) {
                let years = year - calendar.component(.year, from: best.timestamp)
                return DailyPhotoChoice(
                    fileId: best.fileId, reason: exact ? .yearsAgo(years) : .aroundThisDay(years), takenAt: best.timestamp,
                    place: best.place)
            }
        }
        let favoritePool = favorites.filter(\.isFavorite)
        if let best = best(of: favoritePool, day: day, excluding: recentlyShown) ?? best(of: favoritePool, day: day, excluding: []) {
            return DailyPhotoChoice(fileId: best.fileId, reason: .favorite, takenAt: best.timestamp, place: best.place)
        }
        return nil
    }

    /// The best-scoring photo not shown lately; ties are broken by a hash of the day, so equal photos take turns.
    static func best(of pool: [DailyPhotoCandidate], day: Date, excluding: Set<FileID>) -> DailyPhotoCandidate? {
        let seed = dayNumber(day)
        return
            pool
            .filter { !excluding.contains($0.fileId) && quality($0) >= 0 }
            .max { a, b in
                let qa = quality(a)
                let qb = quality(b)
                if qa != qb { return qa < qb }
                return mix(seed, a.fileId) < mix(seed, b.fileId)
            }
    }

    /// Days since 2001 in UTC: the same number all day long wherever the device is.
    static func dayNumber(_ day: Date) -> Int64 { Int64((day.timeIntervalSinceReferenceDate / 86_400).rounded(.down)) }

    /// A stable mix of the day and the file id (SplitMix64), independent of Swift's per-process hash seed.
    static func mix(_ seed: Int64, _ fileId: FileID) -> UInt64 {
        var z = UInt64(bitPattern: seed &* 0x9E37_79B9 &+ Int64(fileId))
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
