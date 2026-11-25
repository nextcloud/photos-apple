// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// Small files the app keeps in the user's own Nextcloud so that all their devices share them (SPEC §16.4: smart
/// albums, folder rules and their lock), in the hidden folder `/.nextcloud-photos/`. Plain WebDAV, nothing the server
/// has to know: every write names the version it replaces (`If-Match`), or `If-None-Match: *` for a new file, so two
/// devices never overwrite each other's changes unseen.
public struct AppDataFiles: Sendable {
    public let dav: DAVClient

    public init(dav: DAVClient) {
        self.dav = dav
    }

    /// The folder in the user's files.
    public static let folder = "/.nextcloud-photos"

    public static func path(_ name: String) -> String { "\(folder)/\(name)" }

    /// A file's content and version.
    public struct Content: Sendable, Equatable {
        public var data: Data
        /// Without quotes.
        public var etag: String

        public init(data: Data, etag: String) {
            self.data = data
            self.etag = etag
        }
    }

    /// The file, or nil when it does not exist.
    public func read(_ name: String) async throws -> Content? {
        do {
            let response = try await dav.get(dav.connection.filesURL(Self.path(name)), headers: ["Accept": "application/json"])
            return Content(data: response.data, etag: Self.etag(response))
        } catch NetworkError.notFound {
            return nil
        }
    }

    /// Writes the file if it is still at `expected` (its ETag), or does not exist yet when `expected` is nil. Returns
    /// the new ETag; throws `NetworkError.preconditionFailed` when another device changed it in between.
    @discardableResult
    public func write(_ name: String, data: Data, replacing expected: String?) async throws -> String {
        var headers = ["Content-Type": "application/json"]
        if let expected {
            headers["If-Match"] = "\"\(expected)\""
        } else {
            headers["If-None-Match"] = "*"
        }
        let url = dav.connection.filesURL(Self.path(name))
        do {
            return Self.etag(try await dav.put(url, data: data, headers: headers))
        } catch NetworkError.conflict, NetworkError.notFound {
            // The folder is missing (409 for a PUT into a folder that does not exist).
            try await dav.mkcolRecursive(userPath: Self.folder)
            return Self.etag(try await dav.put(url, data: data, headers: headers))
        }
    }

    /// Deletes the file if it is still at `expected`; a file that is gone already is fine.
    public func delete(_ name: String, expected: String?) async throws {
        do {
            try await dav.delete(dav.connection.filesURL(Self.path(name)), ifMatch: expected)
        } catch NetworkError.notFound {}
    }

    public static func etag(_ response: HTTPResponse) -> String {
        let raw = response.header("OC-ETag") ?? response.header("ETag") ?? ""
        return raw.replacingOccurrences(of: "W/", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
    }
}

extension AppDataFiles {
    /// Changes a JSON file safely: reads it, lets `change` produce the new content from what is there (nil: nothing to
    /// write), writes it with `If-Match`, and starts again when another device wrote in between (at most `attempts`
    /// times). Returns the content as written (or as found when nothing had to change).
    public func update(
        _ name: String, attempts: Int = 4, _ change: @Sendable (Content?) throws -> Data?
    ) async throws -> Content? {
        var lastError: (any Error)?
        for _ in 0..<max(attempts, 1) {
            let current = try await read(name)
            guard let data = try change(current) else { return current }
            do {
                let etag = try await write(name, data: data, replacing: current?.etag)
                return Content(data: data, etag: etag)
            } catch NetworkError.preconditionFailed {
                lastError = NetworkError.preconditionFailed
                continue
            }
        }
        throw lastError ?? NetworkError.preconditionFailed
    }
}

// MARK: - Camera details

extension PhotosAPI {
    /// The most file ids one SEARCH asks for (the server allows 100 operators per query).
    public static let cameraDetailsBatch = 90

    /// Camera details (EXIF make, model, lens, exposure) of up to `cameraDetailsBatch` files, in one SEARCH. Files the
    /// server has no EXIF for come back with empty details, so they are not asked for again.
    public func cameraDetails(fileIds: [FileID], sourceFolders: [String]) async throws -> [FileID: CameraDetails] {
        guard !fileIds.isEmpty else { return [:] }
        let ids = Array(fileIds.prefix(Self.cameraDetailsBatch))
        let scopes = (sourceFolders.isEmpty ? ["/"] : sourceFolders).map { DAVSearch.Scope(href: connection.filesHref($0)) }
        let search = DAVSearch(
            select: [DAVProp.fileId, DAVProp.metadataExif, DAVProp.metadataIFD0], scopes: scopes,
            condition: .or(ids.map { .eq(DAVProp.fileId, String($0)) }), limit: ids.count)
        var result: [FileID: CameraDetails] = [:]
        for resource in try await dav.search(search, timeout: 120) {
            guard let fileId = resource.int64(DAVProp.fileId) else { continue }
            var exif: [String: String] = [:]
            for name in [DAVProp.metadataIFD0, DAVProp.metadataExif] {
                for child in resource.node(name)?.children ?? [] where !child.value.isEmpty {
                    exif[child.name.name] = child.value
                }
            }
            result[fileId] = CameraDetails(exif: exif)
        }
        for id in ids where result[id] == nil { result[id] = CameraDetails() }
        return result
    }
}
