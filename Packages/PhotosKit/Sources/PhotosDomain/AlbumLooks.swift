// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import PhotosModel

/// How an album's cover is drawn (SPEC §16.8.2).
public enum AlbumCoverEffect: String, Codable, CaseIterable, Sendable {
    /// A Live Photo cover plays its motion once when it comes into view; any other cover is still.
    case automatic
    /// Always the still photo.
    case still
    /// The subject of the photo stands in front of the album's title, like the depth effect of the Lock Screen.
    case depth
}

/// The user's choice for one album's cover: which photo, and which effect. Kept in the user's own Nextcloud
/// (`.nextcloud-photos/album-covers.json`), so every device of the user shows the same covers.
public struct AlbumLook: Codable, Hashable, Sendable {
    /// The photo chosen as cover; nil for the album's own cover (the server's pick or its newest photo).
    public var coverFileId: FileID?
    public var effect: AlbumCoverEffect
    /// When it was chosen: between two devices the later choice wins, album by album.
    public var updatedAt: Date

    public init(coverFileId: FileID? = nil, effect: AlbumCoverEffect = .automatic, updatedAt: Date = Date()) {
        self.coverFileId = coverFileId
        self.effect = effect
        self.updatedAt = updatedAt
    }

    /// Nothing chosen: the album looks as it would without the file.
    public var isDefault: Bool { coverFileId == nil && effect == .automatic }

    enum CodingKeys: String, CodingKey {
        case coverFileId = "cover"
        case effect
        case updatedAt = "updated"
    }

    /// Tolerant: an effect written by a newer version of the app counts as `automatic` here.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        coverFileId = try container.decodeIfPresent(FileID.self, forKey: .coverFileId)
        let effect = try container.decodeIfPresent(String.self, forKey: .effect)
        self.effect = effect.flatMap(AlbumCoverEffect.init(rawValue:)) ?? .automatic
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
    }
}

/// All albums' cover choices of one account: the content of `.nextcloud-photos/album-covers.json`.
///
/// ```json
/// { "version": 1, "albums": { "own:Lisbon 2025": { "cover": 4711, "effect": "depth", "updated": "2026-11-25T10:00:00Z" } } }
/// ```
/// Keys are the app's album ids (`<kind>:<DAV name>`; a shared album's name carries its owner). A choice that is reset is
/// kept as a default entry with its time, so the reset reaches the other devices too.
public struct AlbumLookBook: Codable, Hashable, Sendable {
    public static let folder = ".nextcloud-photos"
    public static let fileName = "album-covers.json"
    /// The path in the user's files.
    public static var userPath: String { "/\(folder)/\(fileName)" }
    public static let currentVersion = 1

    public var version: Int
    public var albums: [String: AlbumLook]

    public init(albums: [String: AlbumLook] = [:]) {
        self.version = Self.currentVersion
        self.albums = albums
    }

    public func look(for albumId: String) -> AlbumLook? {
        guard let look = albums[albumId], !look.isDefault else { return nil }
        return look
    }

    public mutating func set(_ look: AlbumLook, for albumId: String) {
        albums[albumId] = look
    }

    /// An album was renamed: its choice follows it.
    public mutating func rename(from old: String, to new: String, at date: Date = Date()) {
        guard let look = albums[old], old != new else { return }
        albums[new] = AlbumLook(coverFileId: look.coverFileId, effect: look.effect, updatedAt: date)
        albums[old] = AlbumLook(updatedAt: date)
    }

    /// The choices of both books, album by album the later one (this book's on a tie).
    public func merged(with other: AlbumLookBook) -> AlbumLookBook {
        var result = self
        result.version = max(version, other.version)
        for (id, theirs) in other.albums {
            if let ours = albums[id], ours.updatedAt >= theirs.updatedAt { continue }
            result.albums[id] = theirs
        }
        return result
    }

    public static func decode(_ data: Data) throws -> AlbumLookBook {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AlbumLookBook.self, from: data)
    }

    /// Stable output (sorted keys), so two devices writing the same choices write the same bytes.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(self)
    }

    enum CodingKeys: String, CodingKey {
        case version, albums
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        albums = try container.decodeIfPresent([String: AlbumLook].self, forKey: .albums) ?? [:]
    }
}

/// Where the title goes on a depth cover, and whether the subject may stand in front of it (SPEC §16.8.2).
public enum DepthCoverLayout {
    /// The title's band on a square cover, in unit coordinates with the origin at the top left: the upper part, as the
    /// clock on the Lock Screen.
    public static let titleBand = CGRect(x: 0.07, y: 0.08, width: 0.86, height: 0.3)
    /// The subject may hide at most this share of the title; more, and the title is drawn in front of it (the Lock
    /// Screen does the same when the subject would hide too much of the clock).
    public static let maximumCoverage = 0.55

    public enum Placement: Equatable, Sendable {
        /// The subject stands in front of the title.
        case behindSubject
        /// The title is in front: the subject would hide too much of it, or there is no subject.
        case inFront
    }

    public static func placement(coverage: Double?) -> Placement {
        guard let coverage else { return .inFront }
        return coverage <= maximumCoverage ? .behindSubject : .inFront
    }

    /// The part of an image (unit coordinates, origin top left) that a cover of `aspect` (width / height) shows when the
    /// image fills it, centred.
    public static func visibleRect(imageWidth: Int, imageHeight: Int, aspect: Double = 1) -> CGRect {
        guard imageWidth > 0, imageHeight > 0, aspect > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let imageAspect = Double(imageWidth) / Double(imageHeight)
        if imageAspect > aspect {
            let width = aspect / imageAspect
            return CGRect(x: (1 - width) / 2, y: 0, width: width, height: 1)
        } else {
            let height = imageAspect / aspect
            return CGRect(x: 0, y: (1 - height) / 2, width: 1, height: height)
        }
    }

    /// The share of `band` (unit coordinates of the cover) where the subject mask is opaque. The mask is the whole
    /// image's (`width × height` alpha bytes, row by row from the top); the cover shows `visible` of it.
    public static func coverage(alpha: [UInt8], width: Int, height: Int, visible: CGRect, band: CGRect = titleBand) -> Double {
        guard width > 0, height > 0, alpha.count >= width * height else { return 0 }
        let left = visible.minX + band.minX * visible.width
        let top = visible.minY + band.minY * visible.height
        let x0 = max(0, Int((left * Double(width)).rounded(.down)))
        let x1 = min(width, Int(((left + band.width * visible.width) * Double(width)).rounded(.up)))
        let y0 = max(0, Int((top * Double(height)).rounded(.down)))
        let y1 = min(height, Int(((top + band.height * visible.height) * Double(height)).rounded(.up)))
        guard x1 > x0, y1 > y0 else { return 0 }
        var covered = 0
        for y in y0..<y1 {
            let row = y * width
            for x in x0..<x1 where alpha[row + x] >= 128 { covered += 1 }
        }
        return Double(covered) / Double((x1 - x0) * (y1 - y0))
    }
}
