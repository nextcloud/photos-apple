// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// The Photos server API for one account (docs/reference/photos-server-api.md).
public struct PhotosAPI: Sendable {
    public let dav: DAVClient
    public let ocs: OCSClient

    public init(dav: DAVClient, ocs: OCSClient) {
        self.dav = dav
        self.ocs = ocs
    }

    public var connection: ServerConnection { dav.connection }
    var uid: String { connection.userId }

    // MARK: Timeline / index

    /// Builds the MIME-type condition (`or` of `eq` on `getcontenttype`).
    public static func mimeCondition(_ mimeTypes: [String]) -> DAVSearch.Condition {
        .or(mimeTypes.map { .eq(DAVProp.contentType, $0) })
    }

    /// Sort key for keyset paging of the index.
    public enum IndexOrder: Sendable {
        /// `nc:metadata-photos-original_date_time` (unix seconds). Fast first sync, newest first.
        case captureTime
        /// `d:getlastmodified`. Every file has one, so reconciliation pages by it.
        case modified

        var property: QName { self == .captureTime ? DAVProp.metadataOriginalDateTime : DAVProp.lastModified }

        func literal(_ seconds: Double) -> String {
            switch self {
            case .captureTime: PhotosAPI.number(seconds)
            case .modified: PhotosAPI.isoDate(seconds)
            }
        }

        /// The sort value of a raw search result (also of one that is not a media item the app can show).
        func value(of resource: DAVResource) -> Double? {
            switch self {
            case .captureTime: resource.unixDate(DAVProp.metadataOriginalDateTime)?.timeIntervalSince1970
            case .modified: resource.httpDate(DAVProp.lastModified)?.timeIntervalSince1970
            }
        }
    }

    /// One page of the media index, newest first, with keyset paging (SPEC §5.4.3).
    ///
    /// Returns the page and the cursor for the next page (`nil` when the server had nothing left). Items sharing the
    /// boundary second are fetched completely, so no item is skipped when many share a second.
    public func indexPage(
        sourceFolders: [String],
        mimeTypes: [String],
        properties: [QName],
        order: IndexOrder = .captureTime,
        before: Double?,
        limit: Int = 1000
    ) async throws -> (items: [MediaItem], next: Double?) {
        var conditions: [DAVSearch.Condition] = [Self.mimeCondition(mimeTypes)]
        if let before { conditions.append(.lt(order.property, order.literal(before))) }
        let scopes = sourceFolders.map { DAVSearch.Scope(href: connection.filesHref($0)) }
        let search = DAVSearch(
            select: properties,
            scopes: scopes,
            condition: .and(conditions),
            orderBy: [DAVSearch.Order(order.property)],
            limit: limit
        )
        let raw = try await dav.search(search, timeout: 300)
        var items = raw.compactMap { MediaParser.mediaItem(from: $0, connection: connection) }
        // Whether there is more is decided by what the server sent, not by what could be parsed: a page with entries
        // the parser skips (or one the server shortened after applying the limit) is not the last one. Only an empty
        // page ends the listing.
        guard let last = raw.last(where: { order.value(of: $0) != nil }).flatMap(order.value(of:)) else { return (items, nil) }
        let boundary = last.rounded(.down)
        // The cursor has to move back. A server that ignores the condition would otherwise be asked for ever.
        if let before, boundary >= before { return (items, nil) }
        // Complete the boundary second.
        let rest = DAVSearch(
            select: properties,
            scopes: scopes,
            condition: .and([
                Self.mimeCondition(mimeTypes), .gte(order.property, order.literal(boundary)),
                .lt(order.property, order.literal(boundary + 1)),
            ])
        )
        let known = Set(items.map(\.fileId))
        items += try await dav.search(rest, timeout: 300).compactMap { MediaParser.mediaItem(from: $0, connection: connection) }
            .filter { !known.contains($0.fileId) }
        return (items, boundary)
    }

    /// Items modified or uploaded after a date (incremental sync).
    public func changedItems(since date: Date, sourceFolders: [String], mimeTypes: [String], properties: [QName]) async throws
        -> [MediaItem]
    {
        let seconds = date.timeIntervalSince1970
        let search = DAVSearch(
            select: properties,
            scopes: sourceFolders.map { DAVSearch.Scope(href: connection.filesHref($0)) },
            condition: .and([
                Self.mimeCondition(mimeTypes),
                .or([.gt(DAVProp.lastModified, Self.isoDate(seconds)), .gt(DAVProp.uploadTime, Self.number(seconds))]),
            ]),
            orderBy: [DAVSearch.Order(DAVProp.lastModified)]
        )
        return try await dav.search(search, timeout: 300).compactMap { MediaParser.mediaItem(from: $0, connection: connection) }
    }

    /// A Unix time as the ISO 8601 date SEARCH conditions on `getlastmodified` expect.
    public static func isoDate(_ seconds: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date(timeIntervalSince1970: seconds))
    }

    /// Items by file id (e.g. Live Photo peers, covers outside the index).
    public func items(fileIds: [FileID], properties: [QName]) async throws -> [MediaItem] {
        guard !fileIds.isEmpty else { return [] }
        var result: [MediaItem] = []
        for chunk in stride(from: 0, to: fileIds.count, by: 50).map({ Array(fileIds[$0..<min($0 + 50, fileIds.count)]) }) {
            let search = DAVSearch(
                select: properties,
                scopes: [DAVSearch.Scope(href: connection.filesHref("/"))],
                condition: .or(chunk.map { .eq(DAVProp.fileId, String($0)) })
            )
            result += try await dav.search(search).compactMap { MediaParser.mediaItem(from: $0, connection: connection) }
        }
        return result
    }

    /// Recursive ETag of a folder (changes when anything below changes).
    public func folderETag(_ path: String) async throws -> String? {
        let resources = try await dav.propfind(connection.filesURL(path), depth: 0, properties: [DAVProp.etag])
        return resources.first?.string(DAVProp.etag)?.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    /// Paths (relative to the user root) of folders with a 0-byte `.nomedia` / `.noimage` file.
    public func nomediaFolders() async throws -> [String] {
        let search = DAVSearch(
            select: [DAVProp.fileId, DAVProp.size],
            scopes: [DAVSearch.Scope(href: connection.filesHref("/"))],
            condition: .and([
                .or([.eq(DAVProp.displayName, ".nomedia"), .eq(DAVProp.displayName, ".noimage")]),
                .eq(DAVProp.size, "0"),
            ])
        )
        // Only what really is such a file counts, whatever the server made of the condition.
        return try await dav.search(search).compactMap { connection.userPath(fromHref: $0.href) }
            .filter { [".nomedia", ".noimage"].contains(($0 as NSString).lastPathComponent) }
            .map { ($0 as NSString).deletingLastPathComponent }
    }

    /// Where a file is now (path relative to the user root), looked up by its id; `nil` when the user has no such file.
    /// One small SEARCH: used before queued deletes and moves, whose stored path may be outdated or reused.
    public func currentPath(fileId: FileID) async throws -> String? {
        let search = DAVSearch(
            select: [DAVProp.fileId],
            scopes: [DAVSearch.Scope(href: connection.filesHref("/"))],
            condition: .eq(DAVProp.fileId, String(fileId))
        )
        return try await dav.search(search).first { $0.int64(DAVProp.fileId) == fileId }.flatMap { connection.userPath(fromHref: $0.href) }
    }

    /// Timeline day counts (extended servers): `[(day "YYYY-MM-DD", count)]`.
    public func timelineDays(mediaType: String = "all") async throws -> [(day: String, count: Int)] {
        struct Day: Decodable {
            var day: String
            var count: Int
        }
        let days: [Day] = try await ocs.request(
            "GET", "ocs/v2.php/apps/photos/api/v1/timeline/days", query: [URLQueryItem(name: "mediaType", value: mediaType)])
        return days.map { ($0.day, $0.count) }
    }

    static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int64(value)) : String(value)
    }

    // MARK: Albums

    public func albumsHomeURL(_ kind: AlbumKind) -> URL {
        connection.davURL("photos/\(uid)/\(kind == .shared ? "sharedalbums" : "albums")/")
    }

    public func albumURL(_ album: Album) -> URL {
        switch album.kind {
        case .own: connection.davURL("photos/\(uid)/albums/\(album.name)/")
        case .shared: connection.davURL("photos/\(uid)/sharedalbums/\(album.name)/")
        case .publicLink: connection.davURL("photospublic/\(album.publicToken ?? album.name)/")
        }
    }

    public func listAlbums(_ kind: AlbumKind, extended: Bool) async throws -> [Album] {
        let properties = DAVProp.album + (extended ? DAVProp.albumExtended : [])
        let resources = try await dav.propfind(albumsHomeURL(kind), depth: 1, properties: properties)
        return resources.dropFirst().compactMap { MediaParser.album(from: $0, kind: kind) }
    }

    public func album(_ album: Album, extended: Bool) async throws -> Album? {
        let properties = DAVProp.album + (extended ? DAVProp.albumExtended : [])
        return try await dav.propfind(albumURL(album), depth: 0, properties: properties).first.flatMap {
            MediaParser.album(from: $0, kind: album.kind)
        }
    }

    public func albumContent(_ album: Album) async throws -> [MediaParser.CollectionChild] {
        let resources = try await dav.propfind(albumURL(album), depth: 1, properties: DAVProp.collectionChild)
        return resources.compactMap(MediaParser.collectionChild(from:))
    }

    public func createAlbum(name: String, location: String = "", description: String? = nil) async throws {
        let url = connection.davURL("photos/\(uid)/albums/\(name)/")
        try await dav.mkcol(url)
        var set: [(QName, DAVBody.PropValue)] = []
        if !location.isEmpty { set.append((DAVProp.location, .text(location))) }
        if let description, !description.isEmpty { set.append((DAVProp.albumDescription, .text(description))) }
        if !set.isEmpty { try await dav.proppatch(url, set: set) }
    }

    public func renameAlbum(_ album: Album, to newName: String) async throws {
        try await dav.move(albumURL(album), to: connection.davURL("photos/\(uid)/albums/\(newName)/"), overwrite: false)
    }

    /// Deletes an own album, or leaves a shared one.
    public func deleteAlbum(_ album: Album) async throws {
        try await dav.delete(albumURL(album))
    }

    public func updateAlbum(
        _ album: Album,
        location: String? = nil,
        description: String? = nil,
        cover: FileID? = nil,
        filters: AlbumFilters? = nil,
        collaborators: [Collaborator]? = nil
    ) async throws {
        var set: [(QName, DAVBody.PropValue)] = []
        if let location { set.append((DAVProp.location, .text(location))) }
        if let description { set.append((DAVProp.albumDescription, .text(description))) }
        if let cover { set.append((DAVProp.cover, .text(String(cover)))) }
        if let filters, let data = try? JSONEncoder().encode(filters), let json = String(data: data, encoding: .utf8) {
            set.append((DAVProp.filters, .text(json)))
        }
        if let collaborators {
            set.append((DAVProp.collaborators, .text(Self.collaboratorsJSON(collaborators))))
        }
        guard !set.isEmpty else { return }
        try await dav.proppatch(albumURL(album), set: set)
    }

    static func collaboratorsJSON(_ collaborators: [Collaborator]) -> String {
        struct Entry: Encodable {
            var id: String
            var label: String
            var type: Int
        }
        let entries = collaborators.map {
            Entry(id: $0.type == .publicLink && $0.id.count != 32 ? "" : $0.id, label: $0.label, type: $0.type.rawValue)
        }
        return (try? JSONEncoder().encode(entries)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    /// Adds a file the user owns (path relative to the user root). 409 (already in the album) counts as success.
    public func addToAlbum(_ album: Album, userPath: String) async throws {
        let name = (userPath as NSString).lastPathComponent
        let destination = albumURL(album).appending(path: name)
        do {
            try await dav.copy(connection.filesURL(userPath), to: destination)
        } catch NetworkError.conflict {
            return
        }
    }

    public func removeFromAlbum(_ album: Album, childName: String) async throws {
        try await dav.delete(albumURL(album).appending(path: childName))
    }

    // MARK: Places

    public func listPlaces(withCountry: Bool) async throws -> [Place] {
        let properties = [DAVProp.lastPhoto, DAVProp.nbItems] + (withCountry ? [DAVProp.placeCountry] : [])
        let resources = try await dav.propfind(connection.davURL("photos/\(uid)/places/"), depth: 1, properties: properties)
        return resources.dropFirst().compactMap(MediaParser.place(from:))
    }

    public func placeContent(_ place: String) async throws -> [MediaParser.CollectionChild] {
        let resources = try await dav.propfind(
            connection.davURL("photos/\(uid)/places/\(place)/"), depth: 1, properties: DAVProp.collectionChild)
        return resources.compactMap(MediaParser.collectionChild(from:))
    }

    // MARK: File actions

    public func setFavorite(userPath: String, _ favorite: Bool) async throws {
        try await dav.proppatch(connection.filesURL(userPath), set: [(DAVProp.favorite, .text(favorite ? "1" : "0"))])
    }

    /// - Parameter ifMatch: only when the file at the path has this ETag (`NetworkError.preconditionFailed` otherwise).
    public func delete(userPath: String, ifMatch etag: String? = nil) async throws {
        try await dav.delete(connection.filesURL(userPath), ifMatch: etag)
    }

    /// - Parameter ifMatch: only when the file at the path has this ETag (`NetworkError.preconditionFailed` otherwise).
    public func move(userPath: String, to destination: String, ifMatch etag: String? = nil) async throws {
        do {
            try await dav.move(connection.filesURL(userPath), to: connection.filesURL(destination), ifMatch: etag)
        } catch NetworkError.conflict {
            try await dav.mkcolRecursive(userPath: (destination as NSString).deletingLastPathComponent)
            try await dav.move(connection.filesURL(userPath), to: connection.filesURL(destination), ifMatch: etag)
        }
    }

    /// Sets capture time and/or location (Nextcloud ≥ 35). Pass `removeLocation` to clear GPS.
    public func setMetadata(
        userPath: String, capturedAt: Date? = nil, latitude: Double? = nil, longitude: Double? = nil, removeLocation: Bool = false
    ) async throws {
        var set: [(QName, DAVBody.PropValue)] = []
        if let capturedAt { set.append((DAVProp.metadataOriginalDateTime, .text(String(Int64(capturedAt.timeIntervalSince1970))))) }
        if let latitude, let longitude {
            set.append((DAVProp.metadataGPS, .xml("<nc:latitude>\(latitude)</nc:latitude><nc:longitude>\(longitude)</nc:longitude>")))
        }
        try await dav.proppatch(connection.filesURL(userPath), set: set, remove: removeLocation ? [DAVProp.metadataGPS] : [])
    }

    /// Links the two halves of a Live Photo.
    public func linkLivePhoto(imagePath: String, imageFileId: FileID, videoPath: String, videoFileId: FileID) async throws {
        try await dav.proppatch(connection.filesURL(imagePath), set: [(DAVProp.metadataLivePhoto, .text(String(videoFileId)))])
        try await dav.proppatch(connection.filesURL(videoPath), set: [(DAVProp.metadataLivePhoto, .text(String(imageFileId)))])
    }

    /// On-demand EXIF (`nc:metadata-photos-exif` / `-ifd0`), returned as flat `tag → value`.
    public func exif(userPath: String) async throws -> [String: String] {
        let resources = try await dav.propfind(
            connection.filesURL(userPath), depth: 0,
            properties: [DAVProp.metadataExif, DAVProp.metadataIFD0, DAVProp.metadataGPS, DAVProp.metadataPlace])
        guard let resource = resources.first else { return [:] }
        var result: [String: String] = [:]
        for name in [DAVProp.metadataIFD0, DAVProp.metadataExif] {
            for child in resource.node(name)?.children ?? [] where !child.value.isEmpty {
                result[child.name.name] = child.value
            }
        }
        return result
    }

    // MARK: User config

    /// The user's Photos settings as the server has them now (`key → raw value`): from the config API (extended
    /// servers), else from the Photos page.
    public func userConfig() async throws -> PhotosUserConfig {
        var config = PhotosUserConfig()
        do {
            let values: JSONValue = try await ocs.request("GET", "ocs/v2.php/apps/photos/api/v1/config")
            for (key, value) in values.object ?? [:] {
                if let raw = Self.rawConfigValue(value) { config.apply(key: key, rawValue: raw) }
            }
        } catch let error where FeatureDetector.isMissingAPI(error) {
            let state = try await InitialStateScraper.fetch(http: dav.http, connection: connection)
            guard !state.isEmpty else { throw NetworkError.invalidResponse("Photos settings") }
            for key in PhotosUserConfig.Key.allCases {
                if let raw = state[key.rawValue].flatMap(Self.rawConfigValue) { config.apply(key: key.rawValue, rawValue: raw) }
            }
        }
        return config
    }

    /// Server config values are strings; lists arrive either as JSON text or as JSON.
    static func rawConfigValue(_ value: JSONValue) -> String? {
        if let string = value.string { return string }
        return (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// `PUT /index.php/apps/photos/api/v1/config/{key}` with `{"value": "…"}`.
    public func setUserConfig(_ key: PhotosUserConfig.Key, value: String) async throws {
        struct Body: Encodable { var value: String }
        let url = connection.url("index.php/apps/photos/api/v1/config/\(key.rawValue)")
        var headers = connection.standardHeaders
        headers["Content-Type"] = "application/json"
        headers["Accept"] = "application/json"
        let response = try await dav.http.send(
            HTTPRequest(method: "PUT", url: url, headers: headers, body: try JSONEncoder().encode(Body(value: value))))
        if let error = NetworkError.from(status: response.status, data: response.data) { throw error }
    }

    // MARK: Previews

    /// Size buckets the server rounds to and pregenerates (SPEC §5.5.1).
    public static let previewBuckets = [64, 256, 1024, 4096]

    public static func previewBucket(forPixels pixels: Double) -> Int {
        previewBuckets.first { Double($0) >= pixels * 0.8 } ?? 4096
    }

    public func previewURL(fileId: FileID, size: Int, etag: String? = nil) -> URL {
        var query = [URLQueryItem(name: "x", value: String(size)), URLQueryItem(name: "y", value: String(size))]
        if let etag, !etag.isEmpty { query.append(URLQueryItem(name: "etag", value: etag)) }
        return connection.url("index.php/apps/photos/api/v1/preview/\(fileId)", query: query)
    }

    public func publicPreviewURL(fileId: FileID, size: Int, token: String) -> URL {
        connection.url(
            "index.php/apps/photos/api/v1/publicPreview/\(fileId)",
            query: [
                URLQueryItem(name: "x", value: String(size)), URLQueryItem(name: "y", value: String(size)),
                URLQueryItem(name: "token", value: token),
            ])
    }

    /// Fetches preview image data.
    public func preview(fileId: FileID, size: Int, etag: String? = nil) async throws -> Data {
        try await dav.get(previewURL(fileId: fileId, size: size, etag: etag), headers: ["Accept": "image/*"]).data
    }

    /// Temporary unauthenticated download URL (`POST ocs/v2.php/apps/dav/api/v1/direct`), valid for hours; used for video streaming.
    public func directDownloadURL(fileId: FileID) async throws -> URL {
        struct Body: Decodable { var url: String }
        let body: Body = try await ocs.request("POST", "ocs/v2.php/apps/dav/api/v1/direct", form: ["fileId": String(fileId)])
        guard let url = URL(string: body.url) else { throw NetworkError.invalidResponse("direct download") }
        return url
    }

    /// The public link users can share for an album with a link collaborator.
    public func publicAlbumLink(token: String) -> URL {
        connection.url("index.php/apps/photos/public/\(token)")
    }
}
