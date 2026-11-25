// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// What a rule may ask about photos beyond their own row: memberships and camera details, read once from the index
/// (`OrganizeStore.ruleContext`) and then used for every photo, so a rule over 100 000 photos runs in memory in a moment
/// and the builder can count while the user edits.
public struct SmartRuleContext: Sendable {
    /// File ids per tag, by folded tag name.
    public var tagMembers: [String: Set<FileID>]
    /// File ids per person name (folded).
    public var personMembers: [String: Set<FileID>]
    /// File ids per own album name (folded).
    public var albumMembers: [String: Set<FileID>]
    public var marks: [FileID: CullingMark]
    public var camera: [FileID: CameraDetails]
    public var now: Date

    public init(
        tagMembers: [String: Set<FileID>] = [:], personMembers: [String: Set<FileID>] = [:],
        albumMembers: [String: Set<FileID>] = [:], marks: [FileID: CullingMark] = [:], camera: [FileID: CameraDetails] = [:],
        now: Date = Date()
    ) {
        self.tagMembers = tagMembers
        self.personMembers = personMembers
        self.albumMembers = albumMembers
        self.marks = marks
        self.camera = camera
        self.now = now
    }

    /// Case- and diacritic-insensitive key for names.
    public static func fold(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

/// Decides which photos a `SmartRule` matches (SPEC §16.4).
public enum SmartRuleEvaluator {
    public static func matches(_ rule: SmartRule, _ item: MediaItem, in context: SmartRuleContext) -> Bool {
        switch rule {
        case .all(let rules): rules.allSatisfy { matches($0, item, in: context) }
        case .any(let rules): rules.contains { matches($0, item, in: context) }
        case .not(let rule): !matches(rule, item, in: context)
        case .condition(let condition): matches(condition, item, in: context)
        }
    }

    public static func matches(_ condition: SmartCondition, _ item: MediaItem, in context: SmartRuleContext) -> Bool {
        switch condition {
        case .person(let name):
            return context.personMembers[SmartRuleContext.fold(name)]?.contains(item.fileId) ?? false
        case .place(let place):
            let key = SmartRuleContext.fold(place)
            return item.place.map(SmartRuleContext.fold) == key || item.placeCountry.map(SmartRuleContext.fold) == key
        case .tag(let name):
            return context.tagMembers[SmartRuleContext.fold(name)]?.contains(item.fileId) ?? false
        case .album(let name):
            return context.albumMembers[SmartRuleContext.fold(name)]?.contains(item.fileId) ?? false
        case .rating(let stars):
            return (context.marks[item.fileId]?.rating ?? 0) >= stars
        case .flag(let flag):
            return (context.marks[item.fileId]?.flag ?? .none) == flag
        case .mediaType(let kind):
            return matches(kind, item)
        case .favorite:
            return item.isFavorite
        case .dateRange(let start, let end):
            return item.timestamp >= start && item.timestamp < end
        case .withinLastDays(let days):
            return item.timestamp >= context.now.addingTimeInterval(-Double(days) * 86_400)
        case .olderThanDays(let days):
            return item.timestamp < context.now.addingTimeInterval(-Double(days) * 86_400)
        case .folder(let folder):
            return isInFolder(item.path, folder)
        case .name(let text):
            return contains(item.name, text)
        case .text(let text):
            return [item.name, item.place, item.placeCountry, item.caption, item.directory].contains {
                $0.map { contains($0, text) } ?? false
            }
        case .camera(let text):
            let details = context.camera[item.fileId]
            return [details?.make, details?.model, details?.cameraName].contains { $0.map { contains($0, text) } ?? false }
        case .lens(let text):
            return context.camera[item.fileId]?.lens.map { contains($0, text) } ?? false
        case .focalLength(let min, let max):
            return inRange(context.camera[item.fileId]?.focalLength, min, max)
        case .aperture(let min, let max):
            return inRange(context.camera[item.fileId]?.aperture, min, max)
        case .iso(let min, let max):
            return inRange(context.camera[item.fileId]?.iso, min, max)
        case .unsupported:
            return false
        }
    }

    public static func matches(_ kind: SmartMediaType, _ item: MediaItem) -> Bool {
        switch kind {
        case .photo: item.kind == .image
        case .video: item.kind == .video
        case .livePhoto: item.isLivePhoto
        case .screenshot: Cleanup.isScreenshot(item)
        case .raw: isRaw(item)
        case .panorama: item.kind == .image && (item.aspectRatio >= 2.5 || item.aspectRatio <= 0.4)
        }
    }

    static let rawExtensions: Set<String> = ["dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "pef", "srw", "x3f", "raw"]

    static func isRaw(_ item: MediaItem) -> Bool {
        item.mimeType == "image/x-dcraw" || rawExtensions.contains((item.name as NSString).pathExtension.lowercased())
    }

    /// The path is inside the folder (not just a name starting the same way: `/Photos/Cam` does not contain `/Photos/Camera/a.jpg`).
    public static func isInFolder(_ path: String, _ folder: String) -> Bool {
        var prefix = folder.trimmingCharacters(in: .whitespaces)
        if !prefix.hasPrefix("/") { prefix = "/" + prefix }
        while prefix.count > 1 && prefix.hasSuffix("/") { prefix.removeLast() }
        if prefix == "/" { return true }
        let lowerPath = path.lowercased()
        let lowerPrefix = prefix.lowercased()
        return lowerPath.hasPrefix(lowerPrefix + "/")
    }

    static func contains(_ value: String, _ text: String) -> Bool {
        let needle = text.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return false }
        return value.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    static func inRange(_ value: Double?, _ min: Double?, _ max: Double?) -> Bool {
        guard let value else { return false }
        if let min, value < min - 0.0001 { return false }
        if let max, value > max + 0.0001 { return false }
        return true
    }

    /// The photos of a smart album, in its order and up to its limit.
    public static func items(of album: SmartAlbumDefinition, from items: [MediaItem], in context: SmartRuleContext) -> [MediaItem] {
        var result = items.filter { matches(album.rule, $0, in: context) }
        switch album.sort {
        case .newestFirst: result.sort { ($0.timestamp, $0.fileId) > ($1.timestamp, $1.fileId) }
        case .oldestFirst: result.sort { ($0.timestamp, $0.fileId) < ($1.timestamp, $1.fileId) }
        }
        if let limit = album.limit, limit > 0, result.count > limit { result = Array(result.prefix(limit)) }
        return result
    }
}

/// Turns the text of a Shortcuts search ("Anna beach 2023") into a rule (SPEC §16.4): every word must be found, as a
/// person, tag, place or in the text of the photo; a year limits the time.
public enum IntentSearch {
    public static func rule(for text: String, calendar: Calendar = .current) -> SmartRule {
        var rules: [SmartRule] = []
        for word in text.split(whereSeparator: \.isWhitespace).map(String.init) where !word.isEmpty {
            if word.count == 4, let year = Int(word), (1900...2100).contains(year),
                let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
                let end = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1))
            {
                rules.append(.condition(.dateRange(start: start, end: end)))
            } else {
                rules.append(.any([.condition(.person(word)), .condition(.tag(word)), .condition(.place(word)), .condition(.text(word))]))
            }
        }
        return .all(rules)
    }
}
