// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// A user or group found by the sharee search.
public struct Sharee: Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var isGroup: Bool

    public init(id: String, label: String, isGroup: Bool) {
        self.id = id
        self.label = label
        self.isGroup = isGroup
    }

    public var collaborator: Collaborator { Collaborator(id: id, label: label, type: isGroup ? .group : .user) }
}

/// A comment on an album (extended servers, `comments/photos_album/<id>`).
public struct AlbumComment: Hashable, Sendable, Identifiable {
    public var id: Int
    public var actorId: String
    public var actorDisplayName: String
    public var message: String
    public var createdAt: Date?
}

extension PhotosAPI {
    /// `GET /ocs/v2.php/core/autocomplete/get` for users and groups (SPEC SH-1).
    public func searchSharees(_ term: String) async throws -> [Sharee] {
        struct Entry: Decodable {
            var id: String
            var label: String
            var source: String
        }
        let entries: [Entry] = try await ocs.request(
            "GET", "ocs/v2.php/core/autocomplete/get",
            query: [
                URLQueryItem(name: "search", value: term), URLQueryItem(name: "itemType", value: "share-recipients"),
                URLQueryItem(name: "shareTypes[]", value: "0"), URLQueryItem(name: "shareTypes[]", value: "1"),
                URLQueryItem(name: "limit", value: "20"),
            ])
        return entries.filter { $0.id != connection.userId }.map { Sharee(id: $0.id, label: $0.label, isGroup: $0.source == "groups") }
    }

    /// Changes the collaborators of an own album to `collaborators` and returns the album re-read from the server (with
    /// the link token).
    ///
    /// The server only takes the whole list. `album.collaborators` is the list the user started from, which may be
    /// old: the album is read again right before writing, and only what the user added or removed is applied to the
    /// list the server has now, so a collaborator someone added elsewhere in the meantime is not dropped.
    public func setCollaborators(_ collaborators: [Collaborator], of album: Album, extended: Bool) async throws -> Album? {
        let current = try await self.album(album, extended: extended)?.collaborators ?? album.collaborators
        let merged = Self.mergeCollaborators(base: album.collaborators, desired: collaborators, current: current)
        try await updateAlbum(album, collaborators: merged)
        return try await self.album(album, extended: extended)
    }

    /// Applies the difference between `base` and `desired` to `current`. Collaborators are the same when type and id
    /// match; an album has at most one public link, whose id (the token) only the server knows.
    static func mergeCollaborators(base: [Collaborator], desired: [Collaborator], current: [Collaborator]) -> [Collaborator] {
        func key(_ collaborator: Collaborator) -> String {
            collaborator.type == .publicLink ? "link" : "\(collaborator.type.rawValue):\(collaborator.id)"
        }
        let baseKeys = Set(base.map(key))
        let desiredKeys = Set(desired.map(key))
        let currentKeys = Set(current.map(key))
        let removed = baseKeys.subtracting(desiredKeys)
        var merged = current.filter { !removed.contains(key($0)) }
        merged += desired.filter { !baseKeys.contains(key($0)) && !currentKeys.contains(key($0)) }
        return merged
    }

    // MARK: Comments

    func commentsURL(albumId: Int) -> URL { connection.davURL("comments/photos_album/\(albumId)/") }

    public func comments(albumId: Int, limit: Int = 100, offset: Int = 0) async throws -> [AlbumComment] {
        let resources = try await dav.report(commentsURL(albumId: albumId), body: DAVBody.filterComments(limit: limit, offset: offset))
        return resources.compactMap { resource in
            guard let id = resource.int(DAVProp.id) else { return nil }
            return AlbumComment(
                id: id,
                actorId: resource.string(QName(XMLNamespace.oc, "actorId")) ?? "",
                actorDisplayName: resource.string(QName(XMLNamespace.oc, "actorDisplayName")) ?? "",
                message: resource.string(QName(XMLNamespace.oc, "message")) ?? "",
                createdAt: resource.httpDate(QName(XMLNamespace.oc, "creationDateTime"))
            )
        }
        .sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
    }

    public func postComment(albumId: Int, message: String) async throws {
        struct Body: Encodable {
            var actorType = "users"
            var verb = "comment"
            var message: String
        }
        _ = try await dav.send(
            "POST", commentsURL(albumId: albumId), headers: ["Content-Type": "application/json"],
            body: try JSONEncoder().encode(Body(message: message)))
    }

    /// Adds a comment to a file (`comments/files/<fileId>`), where the Files app's sidebar shows it. Stock Nextcloud.
    public func addFileComment(fileId: FileID, message: String) async throws {
        struct Body: Encodable {
            var actorType = "users"
            var verb = "comment"
            var message: String
        }
        _ = try await dav.send(
            "POST", connection.davURL("comments/files/\(fileId)"), headers: ["Content-Type": "application/json"],
            body: try JSONEncoder().encode(Body(message: message)))
    }

    public func deleteComment(albumId: Int, commentId: Int) async throws {
        try await dav.delete(commentsURL(albumId: albumId).appending(path: String(commentId)))
    }

    // MARK: Quick share (SPEC SH-4)

    /// Creates "Shared on <date>" (with a free suffix), adds the files and a public link. Returns the album with its token.
    public func quickShare(userPaths: [String], existingAlbumNames: Set<String>, title: String, extended: Bool) async throws -> Album {
        var name = title
        var counter = 2
        while existingAlbumNames.contains(name) {
            name = "\(title) (\(counter))"
            counter += 1
        }
        try await createAlbum(name: name)
        let album = Album(kind: .own, name: name)
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                var iterator = userPaths.makeIterator()
                for _ in 0..<5 {
                    guard let path = iterator.next() else { break }
                    group.addTask { try await self.addToAlbum(album, userPath: path) }
                }
                while try await group.next() != nil {
                    if let path = iterator.next() { group.addTask { try await self.addToAlbum(album, userPath: path) } }
                }
            }
            guard
                let shared = try await setCollaborators(
                    [Collaborator(id: "", label: "Public link", type: .publicLink)], of: album, extended: extended)
            else { throw NetworkError.invalidResponse("album after sharing") }
            return shared
        } catch {
            try? await deleteAlbum(album)
            throw error
        }
    }
}

/// Read-only access to a public album link without an account (SPEC SH-6).
public struct PublicAlbumAPI: Sendable {
    public let http: HTTPClient
    public let serverURL: URL
    public let token: String
    public let userAgent: String

    public init(http: HTTPClient, serverURL: URL, token: String, userAgent: String) {
        self.http = http
        self.serverURL = ServerConnection.normalized(serverURL)
        self.token = token
        self.userAgent = userAgent
    }

    /// Parses `https://host/index.php/apps/photos/public/<token>` (or without `index.php`).
    public static func parse(link: String) -> (serverURL: URL, token: String)? {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
            let range = url.absoluteString.range(of: "/apps/photos/public/")
        else { return nil }
        let base = String(url.absoluteString[..<range.lowerBound]).replacingOccurrences(of: "/index.php", with: "")
        let token = String(url.absoluteString[range.upperBound...]).split(whereSeparator: { $0 == "/" || $0 == "?" || $0 == "#" }).first
            .map(String.init)
        guard let token, !token.isEmpty, let serverURL = URL(string: base) else { return nil }
        return (serverURL, token)
    }

    /// The anonymous connection: Basic auth with `<token>:` (no password), as the web app does.
    var connection: ServerConnection {
        ServerConnection(serverURL: serverURL, userId: token, loginName: token, appPassword: "", userAgent: userAgent)
    }

    public var dav: DAVClient { DAVClient(http: http, connection: connection) }

    var albumURL: URL { connection.davURL("photospublic/\(token)/") }

    public func album() async throws -> Album {
        let resources = try await dav.propfind(albumURL, depth: 0, properties: DAVProp.album + [DAVProp.cover, DAVProp.albumDescription])
        guard let resource = resources.first, var album = MediaParser.album(from: resource, kind: .publicLink) else {
            throw NetworkError.notFound
        }
        album.publicToken = token
        return album
    }

    public func content() async throws -> [MediaParser.CollectionChild] {
        try await dav.propfind(albumURL, depth: 1, properties: DAVProp.collectionChild).compactMap(MediaParser.collectionChild(from:))
    }

    public func previewURL(fileId: FileID, size: Int) -> URL {
        connection.url(
            "index.php/apps/photos/api/v1/publicPreview/\(fileId)",
            query: [
                URLQueryItem(name: "x", value: String(size)), URLQueryItem(name: "y", value: String(size)),
                URLQueryItem(name: "token", value: token),
            ])
    }

    /// URL of a child to stream/download the original.
    public func originalURL(childName: String) -> URL { albumURL.appending(path: childName) }

    public func preview(fileId: FileID, size: Int) async throws -> Data {
        try await dav.get(previewURL(fileId: fileId, size: size)).data
    }
}
