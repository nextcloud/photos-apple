// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// One photo of a person (a face detection).
public struct PersonPhoto: Sendable, Hashable {
    public var detectionId: Int
    public var childName: String
    public var item: MediaItem
    public var box: FaceBox?
}

/// A folder entry of the Folders view.
public struct FolderEntry: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var isFolder: Bool
    public var fileId: FileID?
    public var etag: String?
    /// Up to 4 preview file ids (extended servers).
    public var previews: [FileID]
}

extension PhotosAPI {
    // MARK: Recognize (SPEC §7.9; docs/reference/photos-server-api.md §13)

    /// A DAV client that sends the Recognize API key.
    func recognize(_ key: String?) -> DAVClient {
        var client = dav
        if let key { client.extraHeaders["X-Recognize-Api-Key"] = key }
        return client
    }

    /// Obtains a Recognize key: companion endpoint (only when the server has it), else the Photos page's initial state.
    public func fetchRecognizeKey(companionAPI: Bool) async throws -> String? {
        struct Body: Decodable { var key: String }
        if companionAPI, let body: Body = try? await ocs.request("GET", "ocs/v2.php/apps/photos/api/v1/recognize/key") {
            return body.key
        }
        let state = try await InitialStateScraper.fetch(http: dav.http, connection: connection)
        return state["recognizeApiKey"]?.string
    }

    public func people(key: String?) async throws -> [Person] {
        let resources = try await recognize(key).propfind(
            connection.davURL("recognize/\(connection.userId)/faces/"), depth: 1, properties: [DAVProp.nbItems, DAVProp.facePreviewImage])
        return resources.dropFirst().compactMap { resource in
            guard resource.isCollection else { return nil }
            var coverId: FileID?
            var box: FaceBox?
            if let json = resource.string(DAVProp.facePreviewImage), let data = json.data(using: .utf8),
                let preview = try? JSONDecoder().decode(FacePreview.self, from: data)
            {
                coverId = preview.fileid
                if let detection = preview.detection {
                    box = FaceBox(x: detection.x, y: detection.y, width: detection.width, height: detection.height)
                }
            }
            return Person(
                name: resource.lastPathComponent, itemCount: resource.int(DAVProp.nbItems) ?? 0, coverFileId: coverId, coverBox: box)
        }
        .sorted { $0.itemCount > $1.itemCount }
    }

    struct FacePreview: Decodable {
        struct Detection: Decodable {
            var x: Double
            var y: Double
            var width: Double
            var height: Double
        }
        var fileid: FileID
        var detection: Detection?
    }

    struct Detection: Decodable {
        var id: Int
        var fileId: FileID?
        var x: Double
        var y: Double
        var width: Double
        var height: Double
        var clusterId: Int?
        var title: String?
    }

    /// Photos of a person (one entry per detection) or of the unassigned faces.
    public func personPhotos(_ name: String?, key: String?) async throws -> [PersonPhoto] {
        let path = name.map { "recognize/\(connection.userId)/faces/\($0)/" } ?? "recognize/\(connection.userId)/unassigned-faces/"
        let properties = DAVProp.mediaIndex + [DAVProp.realPath, DAVProp.fileName, DAVProp.faceDetections]
        let resources = try await recognize(key).propfind(connection.davURL(path), depth: 1, properties: properties)
        return resources.compactMap { resource in
            guard !resource.isCollection, let fileId = resource.int64(DAVProp.fileId) else { return nil }
            let childName = resource.lastPathComponent
            let detectionId = Int(childName.prefix(while: \.isNumber)) ?? 0
            // realpath is "/<uid>/files/<path>".
            var path = resource.string(DAVProp.realPath) ?? ""
            let prefix = "/\(connection.userId)/files"
            if path.hasPrefix(prefix) { path = String(path.dropFirst(prefix.count)) }
            guard let item = MediaParser.mediaItem(from: resource, fileId: fileId, path: path.isEmpty ? "/" + childName : path) else {
                return nil
            }
            let detections = Self.detections(resource.string(DAVProp.faceDetections))
            let box = detections.first { $0.id == detectionId }.map { FaceBox(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
            return PersonPhoto(detectionId: detectionId, childName: childName, item: item, box: box)
        }
    }

    static func detections(_ json: String?) -> [Detection] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([Detection].self, from: data)) ?? []
    }

    /// Faces in one photo (no key needed on `/files`): named clusters only, left to right.
    public func faceDetections(userPath: String) async throws -> [FaceDetection] {
        let resource = try await dav.propfind(
            connection.filesURL(userPath), depth: 0, properties: [DAVProp.fileId, DAVProp.faceDetections]
        ).first
        let fileId = resource?.int64(DAVProp.fileId) ?? 0
        var seen = Set<String>()
        return Self.detections(resource?.string(DAVProp.faceDetections))
            .filter { ($0.clusterId ?? -1) >= 0 && !($0.title ?? "").isEmpty }
            .sorted { $0.x < $1.x }
            .filter { seen.insert($0.title!).inserted }
            .map {
                FaceDetection(
                    id: $0.id, fileId: fileId, clusterId: $0.clusterId, title: $0.title,
                    box: FaceBox(x: $0.x, y: $0.y, width: $0.width, height: $0.height))
            }
    }

    public func renamePerson(_ name: String, to newName: String, key: String?) async throws {
        let base = "recognize/\(connection.userId)/faces/"
        try await recognize(key).move(connection.davURL(base + name + "/"), to: connection.davURL(base + newName + "/"))
    }

    public func createPerson(_ name: String, key: String?) async throws {
        try await recognize(key).mkcol(connection.davURL("recognize/\(connection.userId)/faces/\(name)/"))
    }

    public func deletePerson(_ name: String, key: String?) async throws {
        try await recognize(key).delete(connection.davURL("recognize/\(connection.userId)/faces/\(name)/"))
    }

    /// "Not this person": unclusters the detection.
    public func removeFromPerson(_ name: String, childName: String, key: String?) async throws {
        try await recognize(key).delete(connection.davURL("recognize/\(connection.userId)/faces/\(name)/\(childName)"))
    }

    /// Moves detections to another (existing) person; `from == nil` assigns unassigned faces.
    public func moveFaces(_ childNames: [String], from: String?, to: String, key: String?) async throws {
        let client = recognize(key)
        let source = from.map { "recognize/\(connection.userId)/faces/\($0)/" } ?? "recognize/\(connection.userId)/unassigned-faces/"
        for child in childNames {
            try await client.move(
                connection.davURL(source + child), to: connection.davURL("recognize/\(connection.userId)/faces/\(to)/\(child)"))
        }
    }

    /// Merges person `from` into `into`, then deletes `from`.
    public func mergePerson(_ from: String, into: String, key: String?) async throws {
        let photos = try await personPhotos(from, key: key)
        try await moveFaces(photos.map(\.childName), from: from, to: into, key: key)
        try await deletePerson(from, key: key)
    }

    // MARK: System tags (SPEC §7.10)

    static let tagProperties = [
        DAVProp.id, DAVProp.tagDisplayName, DAVProp.tagUserVisible, DAVProp.tagUserAssignable, DAVProp.tagCanAssign, DAVProp.filesAssigned,
        DAVProp.referenceFileId, QName(XMLNamespace.nc, "color"),
    ]

    static func tag(from resource: DAVResource) -> SystemTag? {
        guard let id = resource.int(DAVProp.id), let name = resource.string(DAVProp.tagDisplayName) else { return nil }
        return SystemTag(
            id: id, name: name, isUserVisible: resource.bool(DAVProp.tagUserVisible) ?? true,
            isUserAssignable: resource.bool(DAVProp.tagUserAssignable) ?? true,
            canAssign: resource.bool(DAVProp.tagCanAssign) ?? true, itemCount: resource.int(DAVProp.filesAssigned) ?? 0,
            coverFileId: resource.int64(DAVProp.referenceFileId), color: resource.string(QName(XMLNamespace.nc, "color")))
    }

    /// Tags used on images in the user's files.
    public func tagsInUse() async throws -> [SystemTag] {
        try await dav.propfind(connection.davURL("systemtags-assigned/image/"), depth: 1, properties: Self.tagProperties).dropFirst()
            .compactMap(Self.tag(from:)).sorted { $0.itemCount > $1.itemCount }
    }

    public func allTags() async throws -> [SystemTag] {
        try await dav.propfind(connection.davURL("systemtags/"), depth: 1, properties: Self.tagProperties).dropFirst().compactMap(
            Self.tag(from:)
        )
        .filter { $0.isUserVisible && $0.isUserAssignable }
    }

    public func tagContent(_ tagId: Int) async throws -> [MediaItem] {
        let resources = try await dav.report(
            connection.filesURL("/").appendingTrailingSlashIfNeeded(true),
            body: DAVBody.filterFiles(properties: DAVProp.mediaIndex, systemTagIds: [tagId]))
        return resources.compactMap { MediaParser.mediaItem(from: $0, connection: connection) }
    }

    public func tags(of fileId: FileID) async throws -> [SystemTag] {
        try await dav.propfind(connection.davURL("systemtags-relations/files/\(fileId)/"), depth: 1, properties: Self.tagProperties)
            .dropFirst()
            .compactMap(Self.tag(from:))
    }

    public func assignTag(_ tag: SystemTag, to fileId: FileID) async throws {
        struct Body: Encodable {
            var id: Int
            var name: String
            var userVisible: Bool
            var userAssignable: Bool
            var canAssign: Bool
        }
        let body = Body(
            id: tag.id, name: tag.name, userVisible: tag.isUserVisible, userAssignable: tag.isUserAssignable, canAssign: tag.canAssign)
        do {
            _ = try await dav.send(
                "PUT", connection.davURL("systemtags-relations/files/\(fileId)/\(tag.id)"), headers: ["Content-Type": "application/json"],
                body: try JSONEncoder().encode(body))
        } catch NetworkError.conflict { return }
    }

    public func unassignTag(_ tagId: Int, from fileId: FileID) async throws {
        do { try await dav.delete(connection.davURL("systemtags-relations/files/\(fileId)/\(tagId)")) } catch NetworkError.notFound {
            return
        }
    }

    public func createTag(_ name: String) async throws -> SystemTag {
        struct Body: Encodable {
            var name: String
            var userVisible = true
            var userAssignable = true
            var canAssign = true
        }
        let response = try await dav.send(
            "POST", connection.davURL("systemtags/"), headers: ["Content-Type": "application/json"],
            body: try JSONEncoder().encode(Body(name: name)))
        guard let location = response.header("content-location"), let id = Int(location.split(separator: "/").last ?? "") else {
            throw NetworkError.invalidResponse("tag without id")
        }
        return SystemTag(id: id, name: name)
    }

    // MARK: Folders (SPEC §7.11)

    /// Folder listing: subfolders (without `.nomedia` ones) and media files.
    public func folder(_ path: String, mimeTypes: [String], nomedia: [String]) async throws -> (folders: [FolderEntry], items: [MediaItem])
    {
        let resources = try await dav.propfind(
            connection.filesURL(path).appendingTrailingSlashIfNeeded(true), depth: 1,
            properties: DAVProp.mediaIndex + [DAVProp.resourceType])
        var folders: [FolderEntry] = []
        var items: [MediaItem] = []
        let mimes = Set(mimeTypes)
        for resource in resources.dropFirst() {
            guard let userPath = connection.userPath(fromHref: resource.href) else { continue }
            if resource.isCollection {
                let name = (userPath as NSString).lastPathComponent
                guard !name.hasPrefix("."), !nomedia.contains(where: { userPath == $0 || userPath.hasPrefix($0 + "/") }) else { continue }
                folders.append(
                    FolderEntry(
                        path: userPath, name: name, isFolder: true, fileId: resource.int64(DAVProp.fileId),
                        etag: resource.string(DAVProp.etag), previews: []))
            } else if let item = MediaParser.mediaItem(from: resource, connection: connection), mimes.contains(item.mimeType),
                !item.isLivePhotoVideo
            {
                items.append(item)
            }
        }
        folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        items.sort { $0.timestamp > $1.timestamp }
        return (folders, items)
    }

    /// Up to 4 recent photos below a folder for its mosaic.
    public func folderPreviews(_ path: String, mimeTypes: [String]) async throws -> [FileID] {
        let search = DAVSearch(
            select: [DAVProp.fileId], scopes: [DAVSearch.Scope(href: connection.filesHref(path))],
            condition: PhotosAPI.mimeCondition(mimeTypes.filter { $0.hasPrefix("image/") }),
            orderBy: [DAVSearch.Order(DAVProp.lastModified)], limit: 4)
        return try await dav.search(search).compactMap { $0.int64(DAVProp.fileId) }
    }

    /// "Shared with you": received shares and group folders (`GET /apps/photos/api/v1/shared/<path>`), handling both JSON shapes.
    public func sharedWithYou(_ path: String = "/") async throws -> [FolderEntry] {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let url = connection.url("index.php/apps/photos/api/v1/shared" + (trimmed.isEmpty ? "" : "/" + trimmed))
        var headers = connection.standardHeaders
        headers["Accept"] = "application/json"
        let response = try await dav.http.send(HTTPRequest(url: url, headers: headers, timeout: 120))
        if let error = NetworkError.from(status: response.status, data: response.data) { throw error }
        let entries = (try? JSONDecoder().decode([JSONValue].self, from: response.data)) ?? []
        return entries.dropFirst().compactMap { entry in
            guard let filename = entry["filename"]?.string else { return nil }
            let isFolder = entry["type"]?.string == "dir" || entry["mime"]?.string == "httpd/unix-directory"
            let previews = (entry["attributes", "previews"]?.array ?? []).compactMap { $0["id"]?.string.flatMap { FileID($0) } }
            return FolderEntry(
                path: filename, name: (filename as NSString).lastPathComponent, isFolder: isFolder,
                fileId: (entry["id"]?.string ?? entry["fileid"]?.string).flatMap { FileID($0) },
                etag: entry["etag"]?.string ?? entry["attributes", "etag"]?.string, previews: previews)
        }
    }
}
