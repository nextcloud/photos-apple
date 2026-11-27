// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// One entry of a folder listing (`PhotosAPI.listFolder`) or of the folder tree (`PhotosAPI.folders(below:)`).
public struct SyncFolderEntry: Sendable, Equatable {
    /// Path below the user's files root (`/Photos/2024`).
    public var path: String
    /// Without quotes. Of a folder, the server's recursive ETag: any change below it changes it (SPEC §22.4.2).
    public var etag: String
    public var isFolder: Bool
    public var fileId: FileID?
    /// Of a file; nil for folders.
    public var mimeType: String?

    public init(path: String, etag: String, isFolder: Bool, fileId: FileID? = nil, mimeType: String? = nil) {
        self.path = path
        self.etag = etag
        self.isFolder = isFolder
        self.fileId = fileId
        self.mimeType = mimeType
    }
}

/// What the targeted sync reads (SPEC §22.4.2): one folder's direct children, and every folder below the timeline's roots.
extension PhotosAPI {
    /// The properties of a listing: enough to tell what changed, nothing the index needs (that comes by id).
    static let listingProperties: [QName] = [DAVProp.resourceType, DAVProp.etag, DAVProp.fileId, DAVProp.contentType]

    /// A folder's own ETag and its direct children (PROPFIND, Depth 1). A large folder takes a while: 5 minutes.
    public func listFolder(_ path: String) async throws -> (etag: String?, children: [SyncFolderEntry]) {
        let response = try await dav.send(
            "PROPFIND", connection.filesURL(path).appendingTrailingSlashIfNeeded(true),
            headers: ["Depth": "1", "Content-Type": "application/xml; charset=utf-8"],
            body: DAVBody.propfind(Self.listingProperties), timeout: 300)
        let own = Self.normalized(path)
        var etag: String?
        var children: [SyncFolderEntry] = []
        for resource in try MultiStatus.parse(response.data) {
            guard let entry = Self.syncFolderEntry(resource, connection: connection) else { continue }
            if entry.path == own {
                etag = entry.etag
            } else {
                children.append(entry)
            }
        }
        return (etag, children)
    }

    /// Every folder below `root` (not `root` itself) with its ETag: one SEARCH. ETags read this way are the folders' own
    /// ones; a listing adds those of storages mounted below (shares, external storage), so the two can differ, which
    /// only makes the next targeted walk look at such a folder once more.
    public func folders(below root: String) async throws -> [SyncFolderEntry] {
        let search = DAVSearch(
            select: [DAVProp.etag, DAVProp.fileId, DAVProp.resourceType],
            scopes: [DAVSearch.Scope(href: connection.filesHref(root))],
            // Without a limit Nextcloud answers 100 results (seen on 36); it ignores an offset. A folder left out is only
            // listed once more by the next targeted walk.
            condition: .isCollection, limit: Self.folderSearchLimit)
        let own = Self.normalized(root)
        return try await dav.search(search, timeout: 300).compactMap { resource in
            guard var entry = Self.syncFolderEntry(resource, connection: connection), entry.path != own else { return nil }
            entry.isFolder = true
            return entry
        }
    }

    static let folderSearchLimit = 50_000

    static func syncFolderEntry(_ resource: DAVResource, connection: ServerConnection) -> SyncFolderEntry? {
        guard let path = connection.userPath(fromHref: resource.href) else { return nil }
        let etag = (resource.string(DAVProp.etag) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let isFolder = resource.isCollection
        return SyncFolderEntry(
            path: path, etag: etag, isFolder: isFolder, fileId: resource.int64(DAVProp.fileId),
            mimeType: isFolder ? nil : resource.string(DAVProp.contentType))
    }

    static func normalized(_ path: String) -> String {
        var path = path.hasPrefix("/") ? path : "/" + path
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
