// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

extension ServerFeature {
    /// Name under Settings › Server features, localised in this module's catalog (PhotosModel has no resources); the catalog
    /// comments say where the names appear.
    var localizedName: String {
        switch self {
        case .photosDAV: String(localized: "Photos (WebDAV)", bundle: .module)
        case .places: String(localized: "Places", bundle: .module)
        case .recognize: String(localized: "Recognize (faces)", bundle: .module)
        case .systemtags: String(localized: "Tags", bundle: .module)
        case .trashbin: String(localized: "Trash bin", bundle: .module)
        case .notifications: String(localized: "Notifications", bundle: .module)
        case .comments: String(localized: "Comments", bundle: .module)
        case .publicLinks: String(localized: "Public links", bundle: .module)
        case .metadataEdit: String(localized: "Edit date and location", bundle: .module)
        case .albumCover: String(localized: "Album cover", bundle: .module)
        case .albumDescription: String(localized: "Album description", bundle: .module)
        case .albumComments: String(localized: "Album comments", bundle: .module)
        case .albumLastModified: String(localized: "Album last modified", bundle: .module)
        case .albumFilterTags: String(localized: "Tag filters in albums", bundle: .module)
        case .placeCountry: String(localized: "Places by country", bundle: .module)
        case .timelineDays: String(localized: "Timeline day counts", bundle: .module)
        case .captions: String(localized: "AI captions", bundle: .module)
        case .captionsSearchable: String(localized: "Caption search", bundle: .module)
        case .videoRenditions: String(localized: "Video conversion", bundle: .module)
        case .onThisDayNotifications: String(localized: "On this day notifications", bundle: .module)
        case .unifiedSearchPhotos: String(localized: "Unified search (albums, places)", bundle: .module)
        case .folderPreviews: String(localized: "Folder previews", bundle: .module)
        case .taskText2Text: String(localized: "Assistant: text generation", bundle: .module)
        case .taskOCR: String(localized: "Assistant: text recognition", bundle: .module)
        case .taskAnalyzeImages: String(localized: "Assistant: image analysis", bundle: .module)
        case .photosCapability: String(localized: "Photos capability", bundle: .module)
        case .configAPI: String(localized: "Photos settings API", bundle: .module)
        case .syncFeed: String(localized: "Change feed", bundle: .module)
        case .contentHash: String(localized: "Content hashes", bundle: .module)
        case .recognizeKeyAPI: String(localized: "Recognize key API", bundle: .module)
        case .albumChangeTag: String(localized: "Album change tags", bundle: .module)
        case .mediaDuration: String(localized: "Video duration", bundle: .module)
        }
    }
}
