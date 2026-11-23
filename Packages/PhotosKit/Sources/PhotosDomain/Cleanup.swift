// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// Candidates for "Free up space" on the server (SPEC §7.15; web: `src/utils/cleanup.ts`).
///
/// Everything offered here is deleted from the server, so the rules are conservative: a file is only called a
/// screenshot when its name says so, or when it is a PNG with exactly the pixel size of a phone screen and no sign of
/// coming from a camera. A PNG alone is never enough: scans, drawings, exports and transparent graphics are PNGs too.
public enum Cleanup {
    /// Size above which a video is suggested, in bytes (100 MiB).
    public static let largeVideoSize: Int64 = 100 * 1024 * 1024

    public enum Category: String, Hashable, Sendable, CaseIterable {
        case screenshots, screenRecordings, largeVideos
    }

    public struct Candidates: Hashable, Sendable {
        public var category: Category
        /// Largest first.
        public var items: [MediaItem]
        public var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }
    }

    /// Names given to screenshots by common systems (EN/DE/FR/ES/NL), as regular expressions. Separators may be a
    /// space, `_`, `-` or nothing; `.{1,3}` covers the different apostrophes and decomposed accents.
    static let screenshotNames = [
        "screen[ _-]?shot", "bildschirmfoto", "capture d.{1,3}cran", "captura de pantalla", "schermafbeelding",
    ]

    /// Names given to screen recordings, in the same form.
    static let screenRecordingNames = [
        "screen[ _-]?record", "screencast", "bildschirmaufnahme", "enregistrement de l.{1,3}cran", "grabaci.{1,2}n de pantalla",
        "schermopname",
    ]

    /// Resolutions of common phone screens, in pixels, portrait (same table as the web app).
    static let phoneScreenSizes: Set<[Int]> = [
        // iPhone
        [640, 1136], [750, 1334], [828, 1792], [1080, 2340], [1125, 2436], [1170, 2532], [1179, 2556], [1206, 2622], [1242, 2208],
        [1242, 2688], [1284, 2778], [1290, 2796], [1320, 2868],
        // Android
        [720, 1280], [720, 1600], [1080, 1920], [1080, 2160], [1080, 2280], [1080, 2400], [1440, 2560], [1440, 2960], [1440, 3040],
        [1440, 3120], [1440, 3200],
    ]

    static func matches(_ name: String, _ patterns: [String]) -> Bool {
        let normalized = name.precomposedStringWithCanonicalMapping
        return patterns.contains { normalized.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    /// Whether the dimensions are exactly those of a phone screen, in either orientation.
    public static func isPhoneScreenSize(width: Int, height: Int) -> Bool {
        phoneScreenSizes.contains([min(width, height), max(width, height)])
    }

    /// A screenshot is an image named like one, or a PNG with the exact size of a phone screen that carries no
    /// location (the only camera metadata the index keeps; a located picture was taken by a camera).
    public static func isScreenshot(_ item: MediaItem) -> Bool {
        guard item.kind == .image else { return false }
        if matches(item.name, screenshotNames) { return true }
        guard item.mimeType.lowercased() == "image/png", !item.hasLocation, let width = item.width, let height = item.height else {
            return false
        }
        return isPhoneScreenSize(width: width, height: height)
    }

    public static func isScreenRecording(_ item: MediaItem) -> Bool {
        item.kind == .video && matches(item.name, screenRecordingNames)
    }

    public static func isLargeVideo(_ item: MediaItem, threshold: Int64 = largeVideoSize) -> Bool {
        item.kind == .video && item.size > threshold
    }

    /// The category of an item, or `nil` when it is not a cleanup candidate. Each item is in one category at most, so
    /// the sizes add up: a screen recording is not listed again among the large videos.
    public static func category(of item: MediaItem, threshold: Int64 = largeVideoSize) -> Category? {
        if isScreenshot(item) { return .screenshots }
        if isScreenRecording(item) { return .screenRecordings }
        if isLargeVideo(item, threshold: threshold) { return .largeVideos }
        return nil
    }

    /// Non-empty categories in a fixed order, each sorted largest first. Items the user may not delete, Live Photo
    /// videos (they belong to their still) and archived items are left out.
    public static func candidates(_ items: [MediaItem], threshold: Int64 = largeVideoSize) -> [Candidates] {
        var buckets: [Category: [MediaItem]] = [:]
        for item in items where item.permissions.canDelete && !item.isLivePhotoVideo && !item.isArchived {
            guard let category = category(of: item, threshold: threshold) else { continue }
            buckets[category, default: []].append(item)
        }
        return Category.allCases.compactMap { category in
            guard let members = buckets[category], !members.isEmpty else { return nil }
            let sorted = members.sorted { ($0.size, $1.fileId) > ($1.size, $0.fileId) }
            return Candidates(category: category, items: sorted)
        }
    }
}
