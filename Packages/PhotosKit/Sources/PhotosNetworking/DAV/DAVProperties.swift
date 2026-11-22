// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The WebDAV properties the app uses (see docs/reference/photos-server-api.md §4).
public enum DAVProp {
    static func d(_ name: String) -> QName { QName(XMLNamespace.dav, name) }
    static func oc(_ name: String) -> QName { QName(XMLNamespace.oc, name) }
    static func nc(_ name: String) -> QName { QName(XMLNamespace.nc, name) }

    // DAV
    public static let displayName = d("displayname")
    public static let contentType = d("getcontenttype")
    public static let contentLength = d("getcontentlength")
    public static let etag = d("getetag")
    public static let lastModified = d("getlastmodified")
    public static let creationDate = d("creationdate")
    public static let resourceType = d("resourcetype")
    public static let collection = d("collection")
    // ownCloud
    public static let fileId = oc("fileid")
    public static let id = oc("id")
    public static let size = oc("size")
    public static let favorite = oc("favorite")
    public static let permissions = oc("permissions")
    public static let ownerId = oc("owner-id")
    public static let ownerDisplayName = oc("owner-display-name")
    public static let tagDisplayName = oc("display-name")
    public static let tagUserVisible = oc("user-visible")
    public static let tagUserAssignable = oc("user-assignable")
    public static let tagCanAssign = oc("can-assign")
    // Nextcloud
    public static let hasPreview = nc("has-preview")
    public static let hidden = nc("hidden")
    public static let mountType = nc("mount-type")
    public static let uploadTime = nc("upload_time")
    public static let isEncrypted = nc("is-encrypted")
    public static let metadataSize = nc("metadata-photos-size")
    public static let metadataOriginalDateTime = nc("metadata-photos-original_date_time")
    public static let metadataGPS = nc("metadata-photos-gps")
    public static let metadataPlace = nc("metadata-photos-place")
    public static let metadataPlaceCountry = nc("metadata-photos-place-country")
    public static let metadataCaption = nc("metadata-photos-caption")
    public static let metadataExif = nc("metadata-photos-exif")
    public static let metadataIFD0 = nc("metadata-photos-ifd0")
    public static let metadataBlurhash = nc("metadata-blurhash")
    public static let metadataLivePhoto = nc("metadata-files-live-photo")
    public static let metadataDuration = nc("metadata-photos-duration")
    public static let faceDetections = nc("face-detections")
    public static let facePreviewImage = nc("face-preview-image")
    public static let realPath = nc("realpath")
    public static let fileName = nc("file-name")
    // Photos collections
    public static let nbItems = nc("nbItems")
    public static let lastPhoto = nc("last-photo")
    public static let originalName = nc("original-name")
    public static let location = nc("location")
    public static let dateRange = nc("dateRange")
    public static let collaborators = nc("collaborators")
    public static let filters = nc("filters")
    public static let cover = nc("cover")
    public static let albumDescription = nc("description")
    public static let albumId = nc("album-id")
    public static let placeCountry = nc("place-country")
    public static let albumFileOrigin = nc("photos-album-file-origin")
    public static let collectionFileOriginalFilename = nc("photos-collection-file-original-filename")
    public static let filesAssigned = nc("files-assigned")
    public static let referenceFileId = nc("reference-fileid")
    // Trash bin
    public static let trashbinFilename = nc("trashbin-filename")
    public static let trashbinOriginalLocation = nc("trashbin-original-location")
    public static let trashbinDeletionTime = nc("trashbin-deletion-time")

    /// Properties of a media file in the local index (SPEC §5.4.1).
    public static let mediaIndex: [QName] = [
        fileId, displayName, contentType, size, etag, lastModified, uploadTime, favorite, permissions, mountType, ownerId,
        hasPreview, hidden, metadataOriginalDateTime, metadataSize, metadataGPS, metadataPlace, metadataBlurhash,
        metadataLivePhoto,
    ]

    /// Index properties available only on extended servers.
    public static let mediaIndexExtended: [QName] = [metadataPlaceCountry, metadataCaption]

    /// Cheap properties for reconciliation passes.
    public static let mediaReconcile: [QName] = [fileId, etag, favorite, metadataPlace]

    /// Properties of album / collection children (album, place, face content).
    public static let collectionChild: [QName] = [
        fileId, displayName, contentType, contentLength, etag, lastModified, resourceType, favorite, permissions, hasPreview,
        hidden, metadataOriginalDateTime, metadataSize, metadataGPS, metadataPlace, metadataBlurhash, metadataLivePhoto,
        albumFileOrigin, collectionFileOriginalFilename, fileName,
    ]

    /// Properties of album collections.
    public static let album: [QName] = [lastPhoto, nbItems, location, dateRange, collaborators, filters, originalName]
    public static let albumExtended: [QName] = [cover, albumDescription, albumId, lastModified]
}
