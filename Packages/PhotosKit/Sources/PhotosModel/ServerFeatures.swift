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

    /// Where a feature comes from, for the diagnostics screen and for what survives a failed detection.
    public enum Origin: Int, CaseIterable, Sendable {
        /// Nextcloud and the Photos app as released (Photos 6–9, Nextcloud 33+).
        case core
        /// Newer Photos versions (the feature branches); absent on a stock server.
        case extended
        /// Task processing providers (Assistant).
        case assistant
        /// Companion APIs (`SERVER-COMPANION.md`), absent unless the server adds them.
        case companion
    }

    public var origin: Origin {
        switch self {
        case .photosDAV, .places, .recognize, .systemtags, .trashbin, .notifications, .comments, .publicLinks, .metadataEdit: .core
        case .albumCover, .albumDescription, .albumComments, .albumLastModified, .albumFilterTags, .placeCountry, .timelineDays,
            .captions, .captionsSearchable, .videoRenditions, .onThisDayNotifications, .unifiedSearchPhotos, .folderPreviews:
            .extended
        case .taskText2Text, .taskOCR, .taskAnalyzeImages: .assistant
        case .photosCapability, .configAPI, .syncFeed, .contentHash, .recognizeKeyAPI, .albumChangeTag, .mediaDuration: .companion
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
    /// What the capabilities said about the server when this was detected (`FeatureDetector.fingerprint`): a different
    /// value later means the server or its Photos app was upgraded or downgraded, so the features are detected again.
    public var fingerprint: String?

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

    /// Whether the server offers anything beyond the released Photos app (feature branches or companion APIs).
    public var hasExtendedFeatures: Bool { enabled.contains { $0.origin == .extended || $0.origin == .companion } }

    /// The same features without the given ones (a feature the server turned out not to have after all).
    public func removing(_ features: Set<ServerFeature>) -> ServerFeatures {
        var copy = self
        copy.enabled.subtract(features)
        if !features.isDisjoint(with: [.configAPI, .photosCapability]) {
            // Values that only an extended server keeps.
            copy.userConfig.smartAlbums = nil
            copy.userConfig.albumsSortOrder = nil
            copy.userConfig.albumPhotosSortOrder = nil
        }
        if features.contains(.onThisDayNotifications) { copy.userConfig.onThisDayNotifications = nil }
        return copy
    }

    /// Only what every Photos version has: used when detection failed with a server error, so the app never keeps
    /// calling APIs of a newer Photos version that may have been removed (downgrade, app disabled, broken update).
    public var coreOnly: ServerFeatures {
        removing(Set(enabled.filter { $0.origin != .core }))
    }

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
