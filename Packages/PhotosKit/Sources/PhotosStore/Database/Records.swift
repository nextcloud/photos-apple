// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import PhotosModel

extension MediaItem: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "media"
    public static let databaseDateEncodingStrategy: DatabaseDateEncodingStrategy = .timeIntervalSince1970
    public static let databaseDateDecodingStrategy: DatabaseDateDecodingStrategy = .timeIntervalSince1970

    public func encode(to container: inout PersistenceContainer) throws {
        container["fileId"] = fileId
        container["path"] = path
        container["name"] = name
        container["mimeType"] = mimeType
        container["kind"] = kind.rawValue
        container["size"] = size
        container["etag"] = etag
        container["modifiedAt"] = modifiedAt.timeIntervalSince1970
        container["uploadedAt"] = uploadedAt?.timeIntervalSince1970
        container["capturedAt"] = capturedAt?.timeIntervalSince1970
        container["captureOffset"] = captureOffset
        container["width"] = width
        container["height"] = height
        container["latitude"] = latitude
        container["longitude"] = longitude
        container["altitude"] = altitude
        container["place"] = place
        container["placeCountry"] = placeCountry
        container["isFavorite"] = isFavorite
        container["permissions"] = permissions.rawValue
        container["mountType"] = mountType
        container["ownerId"] = ownerId
        container["ownerDisplayName"] = ownerDisplayName
        container["hasPreview"] = hasPreview
        container["blurhash"] = blurhash
        container["livePhotoPeer"] = livePhotoPeer
        container["isLivePhotoVideo"] = isLivePhotoVideo
        container["caption"] = caption
        container["isArchived"] = isArchived
        container["duration"] = duration
    }

    public init(row: Row) throws {
        func date(_ column: String) -> Date? { (row[column] as Double?).map { Date(timeIntervalSince1970: $0) } }
        self.init(
            fileId: row["fileId"],
            path: row["path"],
            name: row["name"],
            mimeType: row["mimeType"],
            kind: MediaKind(rawValue: row["kind"]) ?? .image,
            size: row["size"],
            etag: row["etag"],
            modifiedAt: date("modifiedAt") ?? Date(timeIntervalSince1970: 0),
            uploadedAt: date("uploadedAt"),
            capturedAt: date("capturedAt"),
            captureOffset: row["captureOffset"],
            width: row["width"],
            height: row["height"],
            latitude: row["latitude"],
            longitude: row["longitude"],
            altitude: row["altitude"],
            place: row["place"],
            placeCountry: row["placeCountry"],
            isFavorite: row["isFavorite"],
            permissions: Permissions(rawValue: row["permissions"]),
            mountType: row["mountType"],
            ownerId: row["ownerId"],
            ownerDisplayName: row["ownerDisplayName"],
            hasPreview: row["hasPreview"],
            blurhash: row["blurhash"],
            livePhotoPeer: row["livePhotoPeer"],
            isLivePhotoVideo: row["isLivePhotoVideo"],
            caption: row["caption"],
            isArchived: row["isArchived"],
            duration: row["duration"]
        )
    }
}

/// Album row ↔ model.
struct AlbumRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "album"
    static let databaseDateEncodingStrategy: DatabaseDateEncodingStrategy = .timeIntervalSince1970
    static let databaseDateDecodingStrategy: DatabaseDateDecodingStrategy = .timeIntervalSince1970

    var id: String
    var kind: String
    var name: String
    var title: String
    var ownerId: String?
    var ownerDisplayName: String?
    var location: String
    var albumDescription: String
    var coverFileId: Int64?
    var lastPhotoFileId: Int64?
    var itemCount: Int
    var dateStart: Date?
    var dateEnd: Date?
    var filters: String?
    var collaborators: String?
    var serverAlbumId: Int?
    var lastModified: Date?
    var publicToken: String?
    var fetchedAt: Date?
    var contentFetchedAt: Date?

    init(_ album: Album, fetchedAt: Date?, contentFetchedAt: Date?) {
        id = album.id
        kind = album.kind.rawValue
        name = album.name
        title = album.title
        ownerId = album.ownerId
        ownerDisplayName = album.ownerDisplayName
        location = album.location
        albumDescription = album.albumDescription
        coverFileId = album.coverFileId
        lastPhotoFileId = album.lastPhotoFileId
        itemCount = album.itemCount
        dateStart = album.dateStart
        dateEnd = album.dateEnd
        filters = (try? JSONEncoder().encode(album.filters)).flatMap { String(data: $0, encoding: .utf8) }
        collaborators = (try? JSONEncoder().encode(album.collaborators)).flatMap { String(data: $0, encoding: .utf8) }
        serverAlbumId = album.serverAlbumId
        lastModified = album.lastModified
        publicToken = album.publicToken
        self.fetchedAt = fetchedAt
        self.contentFetchedAt = contentFetchedAt
    }

    var album: Album {
        Album(
            kind: AlbumKind(rawValue: kind) ?? .own,
            name: name,
            title: title,
            ownerId: ownerId,
            ownerDisplayName: ownerDisplayName,
            location: location,
            albumDescription: albumDescription,
            coverFileId: coverFileId,
            lastPhotoFileId: lastPhotoFileId,
            itemCount: itemCount,
            dateStart: dateStart,
            dateEnd: dateEnd,
            filters: filters.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(AlbumFilters.self, from: $0) }
                ?? AlbumFilters(),
            collaborators: collaborators.flatMap { $0.data(using: .utf8) }.flatMap {
                try? JSONDecoder().decode([Collaborator].self, from: $0)
            } ?? [],
            serverAlbumId: serverAlbumId,
            lastModified: lastModified,
            publicToken: publicToken
        )
    }
}

struct AlbumItemRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "albumItem"
    var albumId: String
    var fileId: Int64
    var childName: String
    var origin: String?
    var ownerPath: String?
    var position: Int
}

struct CollectionMediaRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "collectionMedia"
    var fileId: Int64
    var item: MediaItem
}

extension Place: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "place"
}

extension SystemTag: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "tag"
}

struct PersonRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "person"
    var name: String
    var itemCount: Int
    var coverFileId: Int64?
    var coverBox: FaceBox?

    init(_ person: Person) {
        name = person.name
        itemCount = person.itemCount
        coverFileId = person.coverFileId
        coverBox = person.coverBox
    }

    var person: Person { Person(name: name, itemCount: itemCount, coverFileId: coverFileId, coverBox: coverBox) }
}

struct SmartAlbumRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "smartAlbum"
    var id: String
    var name: String
    var filters: AlbumFilters
    var isLocal: Bool
}
