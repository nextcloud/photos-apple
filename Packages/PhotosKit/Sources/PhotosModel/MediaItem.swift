// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

public enum MediaKind: String, Codable, Sendable, CaseIterable {
    case image
    case video
}

/// One photo or video on the server, as kept in the local index.
public struct MediaItem: Codable, Hashable, Sendable, Identifiable {
    public var id: FileID { fileId }

    public var fileId: FileID
    /// Path relative to the user's files root, starting with `/`, e.g. `/Photos/2026/IMG_1.HEIC`.
    public var path: String
    public var name: String
    public var mimeType: String
    public var kind: MediaKind
    public var size: Int64
    /// ETag without quotes.
    public var etag: String
    public var modifiedAt: Date
    public var uploadedAt: Date?
    /// `nc:metadata-photos-original_date_time`; the server falls back to mtime when it has none.
    public var capturedAt: Date?
    /// UTC offset of the capture time in seconds (from EXIF `OffsetTimeOriginal`), when known.
    public var captureOffset: Int?
    public var width: Int?
    public var height: Int?
    public var latitude: Double?
    public var longitude: Double?
    public var altitude: Double?
    public var place: String?
    public var placeCountry: String?
    public var isFavorite: Bool
    public var permissions: Permissions
    /// `nc:mount-type`: empty for own storage, `shared`, `group`, `external`…
    public var mountType: String
    public var ownerId: String?
    public var ownerDisplayName: String?
    public var hasPreview: Bool
    public var blurhash: String?
    /// File id of the other half of a Live Photo.
    public var livePhotoPeer: FileID?
    /// True for the motion (MOV) part of a Live Photo (`nc:hidden`); never shown as its own item.
    public var isLivePhotoVideo: Bool
    public var caption: String?
    public var isArchived: Bool
    /// Video duration in seconds when known.
    public var duration: Double?

    public init(
        fileId: FileID,
        path: String,
        name: String? = nil,
        mimeType: String,
        kind: MediaKind? = nil,
        size: Int64 = 0,
        etag: String = "",
        modifiedAt: Date = Date(timeIntervalSince1970: 0),
        uploadedAt: Date? = nil,
        capturedAt: Date? = nil,
        captureOffset: Int? = nil,
        width: Int? = nil,
        height: Int? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        altitude: Double? = nil,
        place: String? = nil,
        placeCountry: String? = nil,
        isFavorite: Bool = false,
        permissions: Permissions = Permissions(rawValue: "RGDNVW"),
        mountType: String = "",
        ownerId: String? = nil,
        ownerDisplayName: String? = nil,
        hasPreview: Bool = true,
        blurhash: String? = nil,
        livePhotoPeer: FileID? = nil,
        isLivePhotoVideo: Bool = false,
        caption: String? = nil,
        isArchived: Bool = false,
        duration: Double? = nil
    ) {
        self.fileId = fileId
        self.path = path
        self.name = name ?? (path as NSString).lastPathComponent
        self.mimeType = mimeType
        self.kind = kind ?? MimeTypes.kind(of: mimeType) ?? .image
        self.size = size
        self.etag = etag
        self.modifiedAt = modifiedAt
        self.uploadedAt = uploadedAt
        self.capturedAt = capturedAt
        self.captureOffset = captureOffset
        self.width = width
        self.height = height
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.place = place
        self.placeCountry = placeCountry
        self.isFavorite = isFavorite
        self.permissions = permissions
        self.mountType = mountType
        self.ownerId = ownerId
        self.ownerDisplayName = ownerDisplayName
        self.hasPreview = hasPreview
        self.blurhash = blurhash
        self.livePhotoPeer = livePhotoPeer
        self.isLivePhotoVideo = isLivePhotoVideo
        self.caption = caption
        self.isArchived = isArchived
        self.duration = duration
    }

    /// Timestamp used for sorting and grouping: capture time, else modification time (same as the web app).
    public var timestamp: Date { capturedAt ?? modifiedAt }

    public var isLivePhoto: Bool { kind == .image && livePhotoPeer != nil }

    public var hasLocation: Bool {
        guard let latitude, let longitude, latitude.isFinite, longitude.isFinite else { return false }
        return !(latitude == 0 && longitude == 0)
    }

    /// True when the file is on the user's own storage (only those can be added to albums or archived).
    public var isOwnStorage: Bool { mountType.isEmpty }

    /// `mountType` of a file that is known only as the child of a collection (a photo of someone else's shared album). Its
    /// `path` is then the child's path below the DAV root (`photos/<uid>/sharedalbums/<album>/<child>`, no leading slash),
    /// not a path in the user's files: the user may have a different file of the same name there.
    public static let collectionChildMountType = "photos-collection"

    /// The file is reached through a collection, not through the user's files (`collectionChildMountType`).
    public var isCollectionChild: Bool { mountType == Self.collectionChildMountType }

    public var aspectRatio: Double {
        guard let width, let height, width > 0, height > 0 else { return 1 }
        return Double(width) / Double(height)
    }

    public var directory: String { (path as NSString).deletingLastPathComponent }
}

/// Nextcloud DAV permission letters (`oc:permissions`), e.g. `RGDNVW`.
public struct Permissions: Codable, Hashable, Sendable {
    public var rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public var canShare: Bool { rawValue.contains("R") }
    public var canDelete: Bool { rawValue.contains("D") }
    public var canRename: Bool { rawValue.contains("N") }
    public var canMove: Bool { rawValue.contains("V") }
    public var canWrite: Bool { rawValue.contains("W") }
    public var isShared: Bool { rawValue.contains("S") }
    public var isMounted: Bool { rawValue.contains("M") }
}
