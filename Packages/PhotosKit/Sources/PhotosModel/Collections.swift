// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

public enum AlbumKind: String, Codable, Sendable {
    /// The user's own album (`/photos/<uid>/albums/<name>`).
    case own
    /// Shared with the user (`/photos/<uid>/sharedalbums/<name>`), name carries `" (<owner>)"`.
    case shared
    /// Opened through a public link token (`/photospublic/<token>`).
    case publicLink
}

/// An album as listed by the Photos DAV tree.
public struct Album: Codable, Hashable, Sendable, Identifiable {
    /// Unique within an account: `"<kind>:<name>"`.
    public var id: String { "\(kind.rawValue):\(name)" }
    public var kind: AlbumKind
    /// The DAV collection name (last path segment). For shared albums it includes `" (<owner>)"`.
    public var name: String
    /// Title shown to the user (shared albums without the owner suffix).
    public var title: String
    public var ownerId: String?
    public var ownerDisplayName: String?
    public var location: String
    public var albumDescription: String
    /// Explicitly picked cover (`nc:cover`), `nil` or ≤ 0 for none.
    public var coverFileId: FileID?
    /// `nc:last-photo`: picked cover if still present, else the newest photo with a preview.
    public var lastPhotoFileId: FileID?
    public var itemCount: Int
    public var dateStart: Date?
    public var dateEnd: Date?
    public var filters: AlbumFilters
    public var collaborators: [Collaborator]
    /// Numeric DB id (`nc:album-id`, extended servers), used for comments.
    public var serverAlbumId: Int?
    public var lastModified: Date?
    public var publicToken: String?

    public init(
        kind: AlbumKind,
        name: String,
        title: String? = nil,
        ownerId: String? = nil,
        ownerDisplayName: String? = nil,
        location: String = "",
        albumDescription: String = "",
        coverFileId: FileID? = nil,
        lastPhotoFileId: FileID? = nil,
        itemCount: Int = 0,
        dateStart: Date? = nil,
        dateEnd: Date? = nil,
        filters: AlbumFilters = AlbumFilters(),
        collaborators: [Collaborator] = [],
        serverAlbumId: Int? = nil,
        lastModified: Date? = nil,
        publicToken: String? = nil
    ) {
        self.kind = kind
        self.name = name
        self.title = title ?? name
        self.ownerId = ownerId
        self.ownerDisplayName = ownerDisplayName
        self.location = location
        self.albumDescription = albumDescription
        self.coverFileId = coverFileId
        self.lastPhotoFileId = lastPhotoFileId
        self.itemCount = itemCount
        self.dateStart = dateStart
        self.dateEnd = dateEnd
        self.filters = filters
        self.collaborators = collaborators
        self.serverAlbumId = serverAlbumId
        self.lastModified = lastModified
        self.publicToken = publicToken
    }

    /// The file id to show as cover (`cover > 0 ? cover : last-photo`).
    public var displayCoverFileId: FileID? {
        if let coverFileId, coverFileId > 0 { return coverFileId }
        if let lastPhotoFileId, lastPhotoFileId > 0 { return lastPhotoFileId }
        return nil
    }

    public var publicLink: Collaborator? { collaborators.first { $0.type == .publicLink } }

    /// Strips the `" (<owner>)"` suffix the server appends to shared album names.
    public static func titleWithoutOwnerSuffix(_ name: String, ownerId: String?) -> String {
        if let ownerId, name.hasSuffix(" (\(ownerId))") {
            return String(name.dropLast(ownerId.count + 3))
        }
        if let range = name.range(of: #" \([^()]+\)$"#, options: .regularExpression) {
            return String(name[name.startIndex..<range.lowerBound])
        }
        return name
    }
}

public struct Collaborator: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: Int, Codable, Sendable {
        case user = 0
        case group = 1
        case publicLink = 3
    }

    public var id: String
    public var label: String
    public var type: Kind

    public init(id: String, label: String, type: Kind) {
        self.id = id
        self.label = label
        self.type = type
    }
}

/// Smart filters of an album (`nc:filters` JSON) and of saved smart albums.
public struct AlbumFilters: Codable, Hashable, Sendable {
    public struct DateRange: Codable, Hashable, Sendable {
        /// Milliseconds since 1970 (start of the first day).
        public var start: Int64
        /// Milliseconds since 1970 (start of the last day; the day is included).
        public var end: Int64

        public init(start: Int64, end: Int64) {
            self.start = start
            self.end = end
        }

        public init(start: Date, end: Date) {
            self.start = Int64(start.timeIntervalSince1970 * 1000)
            self.end = Int64(end.timeIntervalSince1970 * 1000)
        }

        public var startDate: Date { Date(timeIntervalSince1970: Double(start) / 1000) }
        /// Exclusive end: end of the last included day.
        public var endDateExclusive: Date { Date(timeIntervalSince1970: Double(end) / 1000 + 86_400) }
    }

    public var dateRanges: [DateRange]
    public var places: [String]
    public var names: [String]
    public var tags: [String]

    public init(dateRanges: [DateRange] = [], places: [String] = [], names: [String] = [], tags: [String] = []) {
        self.dateRanges = dateRanges
        self.places = places
        self.names = names
        self.tags = tags
    }

    enum CodingKeys: String, CodingKey {
        case dateRanges = "date-range"
        case places
        case names = "name"
        case tags
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dateRanges = (try? c.decodeIfPresent([DateRange].self, forKey: .dateRanges)) ?? []
        places = (try? c.decodeIfPresent([String].self, forKey: .places)) ?? []
        names = (try? c.decodeIfPresent([String].self, forKey: .names)) ?? []
        tags = (try? c.decodeIfPresent([String].self, forKey: .tags)) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(dateRanges, forKey: .dateRanges)
        try c.encode(places, forKey: .places)
        try c.encode(names, forKey: .names)
        if !tags.isEmpty { try c.encode(tags, forKey: .tags) }
    }

    public var isEmpty: Bool { dateRanges.isEmpty && places.isEmpty && names.isEmpty && tags.isEmpty }
}

/// A saved timeline filter (`smartAlbums` user config, extended servers; else stored locally).
public struct SmartAlbum: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var filters: AlbumFilters

    public init(id: String = SmartAlbum.makeID(), name: String, filters: AlbumFilters) {
        self.id = id
        self.name = name
        self.filters = filters
    }

    public static func makeID() -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<10).map { _ in chars.randomElement()! })
    }
}

public struct Place: Codable, Hashable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    /// ISO 3166-1 alpha-2 (`nc:place-country`), when known.
    public var countryCode: String?
    public var itemCount: Int
    public var coverFileId: FileID?

    public init(name: String, countryCode: String? = nil, itemCount: Int = 0, coverFileId: FileID? = nil) {
        self.name = name
        self.countryCode = countryCode
        self.itemCount = itemCount
        self.coverFileId = coverFileId
    }
}

/// Relative face box, all values in 0…1 of the image size.
public struct FaceBox: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// A Recognize face cluster.
public struct Person: Codable, Hashable, Sendable, Identifiable {
    public var id: String { name }
    /// Cluster title, or the numeric cluster id when untitled.
    public var name: String
    public var itemCount: Int
    public var coverFileId: FileID?
    public var coverBox: FaceBox?

    public init(name: String, itemCount: Int = 0, coverFileId: FileID? = nil, coverBox: FaceBox? = nil) {
        self.name = name
        self.itemCount = itemCount
        self.coverFileId = coverFileId
        self.coverBox = coverBox
    }

    public var isUnnamed: Bool { Int(name) != nil }
}

/// One face detection in a photo (`nc:face-detections`).
public struct FaceDetection: Codable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var fileId: FileID
    public var clusterId: Int?
    public var title: String?
    public var box: FaceBox

    public init(id: Int, fileId: FileID, clusterId: Int?, title: String?, box: FaceBox) {
        self.id = id
        self.fileId = fileId
        self.clusterId = clusterId
        self.title = title
        self.box = box
    }
}

public struct SystemTag: Codable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var name: String
    public var isUserVisible: Bool
    public var isUserAssignable: Bool
    public var canAssign: Bool
    public var itemCount: Int
    public var coverFileId: FileID?
    public var color: String?

    public init(
        id: Int,
        name: String,
        isUserVisible: Bool = true,
        isUserAssignable: Bool = true,
        canAssign: Bool = true,
        itemCount: Int = 0,
        coverFileId: FileID? = nil,
        color: String? = nil
    ) {
        self.id = id
        self.name = name
        self.isUserVisible = isUserVisible
        self.isUserAssignable = isUserAssignable
        self.canAssign = canAssign
        self.itemCount = itemCount
        self.coverFileId = coverFileId
        self.color = color
    }
}
