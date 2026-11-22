// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Optional server features the app adapts to (SPEC §5.3). A missing feature hides its UI.
public enum ServerFeature: String, Codable, CaseIterable, Sendable, Comparable {
    // Core Photos / Nextcloud
    case photosDAV
    case places
    case recognize
    case systemtags
    case trashbin
    case notifications
    case comments
    case publicLinks
    case metadataEdit
    // Extended (feature branches / newer Photos)
    case albumCover
    case albumDescription
    case albumComments
    case albumLastModified
    case albumFilterTags
    case placeCountry
    case timelineDays
    case captions
    case captionsSearchable
    case videoRenditions
    case onThisDayNotifications
    case unifiedSearchPhotos
    case folderPreviews
    // Task processing (Assistant)
    case taskText2Text
    case taskOCR
    case taskAnalyzeImages
    // Companion APIs (SERVER-COMPANION.md)
    case photosCapability
    case configAPI
    case syncFeed
    case contentHash
    case recognizeKeyAPI
    case albumChangeTag
    case mediaDuration

    public static func < (lhs: ServerFeature, rhs: ServerFeature) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Human readable name for the diagnostics screen.
    public var displayName: String {
        switch self {
        case .photosDAV: "Photos (WebDAV)"
        case .places: "Places"
        case .recognize: "Recognize (faces)"
        case .systemtags: "Tags"
        case .trashbin: "Trash bin"
        case .notifications: "Notifications"
        case .comments: "Comments"
        case .publicLinks: "Public links"
        case .metadataEdit: "Edit date and location"
        case .albumCover: "Album cover"
        case .albumDescription: "Album description"
        case .albumComments: "Album comments"
        case .albumLastModified: "Album last modified"
        case .albumFilterTags: "Tag filters in albums"
        case .placeCountry: "Places by country"
        case .timelineDays: "Timeline day counts"
        case .captions: "AI captions"
        case .captionsSearchable: "Caption search"
        case .videoRenditions: "Video conversion"
        case .onThisDayNotifications: "On this day notifications"
        case .unifiedSearchPhotos: "Unified search (albums, places)"
        case .folderPreviews: "Folder previews"
        case .taskText2Text: "Assistant: text generation"
        case .taskOCR: "Assistant: text recognition"
        case .taskAnalyzeImages: "Assistant: image analysis"
        case .photosCapability: "Photos capability"
        case .configAPI: "Photos settings API"
        case .syncFeed: "Change feed"
        case .contentHash: "Content hashes"
        case .recognizeKeyAPI: "Recognize key API"
        case .albumChangeTag: "Album change tags"
        case .mediaDuration: "Video duration"
        }
    }
}

/// Everything the app learned about a server for one account.
public struct ServerFeatures: Codable, Hashable, Sendable {
    public var serverVersion: ServerVersion
    public var photosAppVersion: String?
    public var enabled: Set<ServerFeature>
    public var imageMimeTypes: [String]
    public var videoMimeTypes: [String]
    public var userConfig: PhotosUserConfig
    /// Folders (relative to the user root, starting with `/`) that contain a `.nomedia` / `.noimage` marker.
    public var nomediaPaths: [String]
    /// Encrypted Recognize API key and when it was obtained (valid 24 h).
    public var recognizeAPIKey: String?
    public var recognizeAPIKeyDate: Date?
    /// `files.chunked_upload.max_parallel_count`, default 5.
    public var maxParallelChunkUploads: Int
    /// Theming colour from capabilities, `#RRGGBB`.
    public var themingColor: String?
    public var detectedAt: Date

    public init(
        serverVersion: ServerVersion,
        photosAppVersion: String? = nil,
        enabled: Set<ServerFeature> = [],
        imageMimeTypes: [String] = MimeTypes.defaultImages,
        videoMimeTypes: [String] = MimeTypes.defaultVideos,
        userConfig: PhotosUserConfig = PhotosUserConfig(),
        nomediaPaths: [String] = [],
        recognizeAPIKey: String? = nil,
        recognizeAPIKeyDate: Date? = nil,
        maxParallelChunkUploads: Int = 5,
        themingColor: String? = nil,
        detectedAt: Date = Date()
    ) {
        self.serverVersion = serverVersion
        self.photosAppVersion = photosAppVersion
        self.enabled = enabled
        self.imageMimeTypes = imageMimeTypes
        self.videoMimeTypes = videoMimeTypes
        self.userConfig = userConfig
        self.nomediaPaths = nomediaPaths
        self.recognizeAPIKey = recognizeAPIKey
        self.recognizeAPIKeyDate = recognizeAPIKeyDate
        self.maxParallelChunkUploads = maxParallelChunkUploads
        self.themingColor = themingColor
        self.detectedAt = detectedAt
    }

    public func has(_ feature: ServerFeature) -> Bool { enabled.contains(feature) }

    public var allMimeTypes: [String] { imageMimeTypes + videoMimeTypes }

    /// Recognize key that is still valid (keys live 24 h; refresh after 20 h).
    public func validRecognizeKey(now: Date = Date()) -> String? {
        guard let key = recognizeAPIKey, let date = recognizeAPIKeyDate, now.timeIntervalSince(date) < 20 * 3600 else { return nil }
        return key
    }
}

/// The Photos app's per-user settings stored on the server (`PUT /apps/photos/api/v1/config/{key}`), shared with the web app.
public struct PhotosUserConfig: Codable, Hashable, Sendable {
    public var croppedLayout: Bool
    public var gridDensity: String?
    /// Upload destination, default `/Photos`.
    public var photosLocation: String
    /// Timeline scopes, default `["/Photos"]`.
    public var photosSourceFolders: [String]
    public var smartAlbums: [SmartAlbum]?
    public var albumsSortOrder: AlbumSortOrder?
    public var albumPhotosSortOrder: AlbumPhotosSortOrder?
    public var onThisDayNotifications: Bool?

    public init(
        croppedLayout: Bool = false,
        gridDensity: String? = nil,
        photosLocation: String = "/Photos",
        photosSourceFolders: [String] = ["/Photos"],
        smartAlbums: [SmartAlbum]? = nil,
        albumsSortOrder: AlbumSortOrder? = nil,
        albumPhotosSortOrder: AlbumPhotosSortOrder? = nil,
        onThisDayNotifications: Bool? = nil
    ) {
        self.croppedLayout = croppedLayout
        self.gridDensity = gridDensity
        self.photosLocation = photosLocation
        self.photosSourceFolders = photosSourceFolders
        self.smartAlbums = smartAlbums
        self.albumsSortOrder = albumsSortOrder
        self.albumPhotosSortOrder = albumPhotosSortOrder
        self.onThisDayNotifications = onThisDayNotifications
    }

    /// Server config keys as used by `PUT /apps/photos/api/v1/config/{key}`.
    public enum Key: String, CaseIterable, Sendable {
        case croppedLayout, gridDensity, photosLocation, photosSourceFolders, smartAlbums
        case albumsSortOrder, albumPhotosSortOrder, onThisDayNotifications
    }

    /// Applies one raw server value (all server values are strings, lists are JSON-encoded strings).
    public mutating func apply(key: String, rawValue: String) {
        guard let key = Key(rawValue: key) else { return }
        switch key {
        case .croppedLayout: croppedLayout = rawValue == "true"
        case .gridDensity: gridDensity = rawValue
        case .photosLocation: if rawValue.hasPrefix("/") { photosLocation = rawValue }
        case .photosSourceFolders:
            if let data = rawValue.data(using: .utf8), let folders = try? JSONDecoder().decode([String].self, from: data), !folders.isEmpty
            {
                photosSourceFolders = folders
            }
        case .smartAlbums:
            if let data = rawValue.data(using: .utf8) { smartAlbums = try? JSONDecoder().decode([SmartAlbum].self, from: data) }
        case .albumsSortOrder: albumsSortOrder = AlbumSortOrder(rawValue: rawValue)
        case .albumPhotosSortOrder: albumPhotosSortOrder = AlbumPhotosSortOrder(rawValue: rawValue)
        case .onThisDayNotifications: onThisDayNotifications = rawValue == "true"
        }
    }

    /// Raw string value for a key, as the server expects it.
    public func rawValue(for key: Key) -> String? {
        func json(_ value: some Encodable) -> String? {
            (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) }
        }
        switch key {
        case .croppedLayout: return croppedLayout ? "true" : "false"
        case .gridDensity: return gridDensity
        case .photosLocation: return photosLocation
        case .photosSourceFolders: return json(photosSourceFolders)
        case .smartAlbums: return smartAlbums.flatMap { json($0) }
        case .albumsSortOrder: return albumsSortOrder?.rawValue
        case .albumPhotosSortOrder: return albumPhotosSortOrder?.rawValue
        case .onThisDayNotifications: return onThisDayNotifications.map { $0 ? "true" : "false" }
        }
    }
}

public enum AlbumSortOrder: String, Codable, Sendable, CaseIterable {
    case recent, name, date
}

public enum AlbumPhotosSortOrder: String, Codable, Sendable, CaseIterable {
    case oldest, newest
}
