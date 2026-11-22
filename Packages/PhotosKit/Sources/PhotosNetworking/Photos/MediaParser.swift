// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// Converts DAV responses into model values.
public enum MediaParser {
    /// A media file from the `/files/<uid>/` tree (SEARCH / PROPFIND / REPORT).
    public static func mediaItem(from resource: DAVResource, connection: ServerConnection) -> MediaItem? {
        guard !resource.isCollection, let fileId = resource.int64(DAVProp.fileId) else { return nil }
        guard let path = connection.userPath(fromHref: resource.href) else { return nil }
        return mediaItem(from: resource, fileId: fileId, path: path)
    }

    /// A media item from any tree when the user path is known (album/place children use the original filename prop).
    public static func mediaItem(from resource: DAVResource, fileId: FileID, path: String) -> MediaItem? {
        let mime = resource.string(DAVProp.contentType) ?? ""
        guard let kind = MimeTypes.kind(of: mime) else { return nil }
        let etag = (resource.string(DAVProp.etag) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let size = resource.int64(DAVProp.size) ?? resource.int64(DAVProp.contentLength) ?? 0
        let modified = resource.httpDate(DAVProp.lastModified) ?? Date(timeIntervalSince1970: 0)
        let captured = resource.unixDate(DAVProp.metadataOriginalDateTime)
        let (width, height) = dimensions(resource.node(DAVProp.metadataSize))
        let gps = coordinates(resource.node(DAVProp.metadataGPS))
        let isArchived = path.hasPrefix("/.archive/")
        let name = resource.string(DAVProp.fileName) ?? (path as NSString).lastPathComponent
        return MediaItem(
            fileId: fileId,
            path: path,
            name: name,
            mimeType: mime,
            kind: kind,
            size: size,
            etag: etag,
            modifiedAt: modified,
            uploadedAt: resource.unixDate(DAVProp.uploadTime).flatMap { $0.timeIntervalSince1970 > 0 ? $0 : nil },
            capturedAt: captured,
            width: width,
            height: height,
            latitude: gps?.latitude,
            longitude: gps?.longitude,
            altitude: gps?.altitude,
            place: resource.string(DAVProp.metadataPlace),
            placeCountry: resource.string(DAVProp.metadataPlaceCountry),
            isFavorite: resource.bool(DAVProp.favorite) ?? false,
            permissions: Permissions(rawValue: resource.string(DAVProp.permissions) ?? ""),
            mountType: resource.string(DAVProp.mountType) ?? "",
            ownerId: resource.string(DAVProp.ownerId),
            ownerDisplayName: resource.string(DAVProp.ownerDisplayName),
            hasPreview: resource.bool(DAVProp.hasPreview) ?? true,
            blurhash: resource.string(DAVProp.metadataBlurhash),
            livePhotoPeer: resource.int64(DAVProp.metadataLivePhoto).flatMap { $0 > 0 ? $0 : nil },
            isLivePhotoVideo: resource.bool(DAVProp.hidden) ?? false,
            caption: resource.string(DAVProp.metadataCaption),
            isArchived: isArchived,
            duration: resource.double(DAVProp.metadataDuration)
        )
    }

    /// `<width>…</width><height>…</height>` (no namespace).
    static func dimensions(_ node: XMLNode?) -> (Int?, Int?) {
        guard let node else { return (nil, nil) }
        let width = node.child(named: "width").flatMap { Int($0.value) ?? Double($0.value).map { Int($0) } }
        let height = node.child(named: "height").flatMap { Int($0.value) ?? Double($0.value).map { Int($0) } }
        return (width, height)
    }

    static func coordinates(_ node: XMLNode?) -> (latitude: Double, longitude: Double, altitude: Double?)? {
        guard let node,
            let lat = node.child(named: "latitude").flatMap({ Double($0.value) }),
            let lon = node.child(named: "longitude").flatMap({ Double($0.value) }),
            lat.isFinite, lon.isFinite, !(lat == 0 && lon == 0)
        else { return nil }
        return (lat, lon, node.child(named: "altitude").flatMap { Double($0.value) })
    }

    // MARK: Collections

    public static func album(from resource: DAVResource, kind: AlbumKind) -> Album? {
        guard resource.isCollection else { return nil }
        let name = resource.lastPathComponent
        guard !name.isEmpty else { return nil }
        var owner: Collaborator?
        let collaborators = Self.collaborators(resource.node(DAVProp.collaborators))
        if kind == .shared { owner = collaborators.first }
        let original = resource.string(DAVProp.originalName) ?? name
        let title = kind == .shared ? Album.titleWithoutOwnerSuffix(original, ownerId: owner?.id) : original
        var dateStart: Date?
        var dateEnd: Date?
        if let json = resource.string(DAVProp.dateRange), let data = json.data(using: .utf8),
            let range = try? JSONDecoder().decode([String: Double?].self, from: data)
        {
            dateStart = (range["start"] ?? nil).map { Date(timeIntervalSince1970: $0) }
            dateEnd = (range["end"] ?? nil).map { Date(timeIntervalSince1970: $0) }
        }
        var filters = AlbumFilters()
        if let json = resource.string(DAVProp.filters), let data = json.data(using: .utf8) {
            filters = (try? JSONDecoder().decode(AlbumFilters.self, from: data)) ?? AlbumFilters()
        }
        let lastModified = resource.httpDate(DAVProp.lastModified).flatMap { $0.timeIntervalSince1970 > 0 ? $0 : nil }
        return Album(
            kind: kind,
            name: name,
            title: title,
            ownerId: owner?.id,
            ownerDisplayName: owner?.label,
            location: resource.string(DAVProp.location) ?? "",
            albumDescription: resource.string(DAVProp.albumDescription) ?? "",
            coverFileId: resource.int64(DAVProp.cover).flatMap { $0 > 0 ? $0 : nil },
            lastPhotoFileId: resource.int64(DAVProp.lastPhoto).flatMap { $0 > 0 ? $0 : nil },
            itemCount: resource.int(DAVProp.nbItems) ?? 0,
            dateStart: dateStart,
            dateEnd: dateEnd,
            filters: filters,
            collaborators: kind == .shared ? [] : collaborators,
            serverAlbumId: resource.int(DAVProp.albumId),
            lastModified: lastModified
        )
    }

    /// `nc:collaborators` with `<nc:collaborator><id/><label/><type/></nc:collaborator>` children (inner elements un-namespaced).
    public static func collaborators(_ node: XMLNode?) -> [Collaborator] {
        guard let node else { return [] }
        return node.children.compactMap { child in
            guard let id = child.child(named: "id")?.value,
                let typeValue = child.child(named: "type").flatMap({ Int($0.value) }),
                let type = Collaborator.Kind(rawValue: typeValue)
            else { return nil }
            return Collaborator(id: id, label: child.child(named: "label")?.value ?? id, type: type)
        }
    }

    public static func place(from resource: DAVResource) -> Place? {
        guard resource.isCollection else { return nil }
        let name = resource.lastPathComponent
        guard !name.isEmpty else { return nil }
        let country = resource.string(DAVProp.placeCountry)
        return Place(
            name: name,
            countryCode: (country?.isEmpty ?? true) ? nil : country,
            itemCount: resource.int(DAVProp.nbItems) ?? 0,
            coverFileId: resource.int64(DAVProp.lastPhoto).flatMap { $0 > 0 ? $0 : nil }
        )
    }

    /// A child of an album/place collection, named `<fileid>-<filename>`.
    public struct CollectionChild: Sendable, Hashable {
        public var item: MediaItem
        /// DAV child name (`<fileid>-<filename>`), needed to remove it from an album.
        public var childName: String
        /// `user` or `filters` (smart-filter items can't be removed).
        public var origin: String?
        /// Path in the owner's files when the current user owns the file.
        public var ownerPath: String?
    }

    public static func collectionChild(from resource: DAVResource) -> CollectionChild? {
        guard !resource.isCollection, let fileId = resource.int64(DAVProp.fileId) else { return nil }
        let childName = resource.lastPathComponent
        let ownerPath = resource.string(DAVProp.collectionFileOriginalFilename)
        let path = ownerPath ?? "/" + (resource.string(DAVProp.fileName) ?? childName)
        guard let item = mediaItem(from: resource, fileId: fileId, path: path) else { return nil }
        return CollectionChild(item: item, childName: childName, origin: resource.string(DAVProp.albumFileOrigin), ownerPath: ownerPath)
    }
}
