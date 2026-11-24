// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosCore
import PhotosMedia
import PhotosModel
import PhotosNetworking
import PhotosStore

/// Saving an edited photo (SPEC §7.16.2). One path for the editor and for Image ▸ Rotate: the edits are rendered from
/// the original at full resolution and either replace it — a new version of the file, the previous one stays in
/// Nextcloud's file versions — or are uploaded as `<name> (edited)` next to it.
enum PhotoEditSaving {
    enum Failure: LocalizedError, Equatable {
        /// The file is in a share without edit permission.
        case readOnly
        /// The original's format cannot be written back (RAW, GIF…).
        case unsupportedFormat
        /// The file changed on the server since the app last synced it: nothing was overwritten.
        case changedOnServer

        var errorDescription: String? {
            switch self {
            case .readOnly:
                String(localized: "The photo is shared with you without permission to edit it.", bundle: .module)
            case .unsupportedFormat:
                String(
                    localized: "Photos in this format can't be changed in place. Edit the photo and save a copy instead.",
                    bundle: .module)
            case .changedOnServer:
                String(
                    localized:
                        "The photo was changed on the server in the meantime. Nothing was overwritten; try again after the next sync.",
                    bundle: .module)
            }
        }
    }

    /// Why `item` cannot be replaced by an edited version, or nil when it can.
    static func overwriteProblem(_ item: MediaItem) -> Failure? {
        if !item.permissions.canWrite { return .readOnly }
        if item.kind != .image || !PhotoEditor.canRewrite(fileName: item.name) { return .unsupportedFormat }
        return nil
    }

    /// Replaces the original with the edited version. The upload only replaces the file the app knows (`If-Match` with
    /// its ETag): a newer version on the server is never overwritten with an edit of an older one.
    ///
    /// - Parameter original: the downloaded original, when the caller has it already (the editor).
    static func overwrite(_ item: MediaItem, with edits: PhotoEdits, original: URL? = nil, services: AccountServices) async throws {
        if let problem = overwriteProblem(item) { throw problem }
        let file: URL
        if let original {
            file = original
        } else {
            file = try await services.images.originals.original(
                fileId: item.fileId, etag: item.etag, url: services.originalURL(for: item))
        }
        try Task.checkCancellation()
        let directory = try workDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rendered = try PhotoEditor.render(edits, original: file, name: item.name, replacingOriginal: true, to: directory)
        var headers: [String: String] = [:]
        if !item.etag.isEmpty { headers["If-Match"] = "\"\(item.etag)\"" }
        do {
            _ = try await services.dav.put(services.connection.filesURL(item.path), file: rendered, headers: headers)
        } catch NetworkError.preconditionFailed {
            throw Failure.changedOnServer
        }
    }

    /// Uploads the edited version as a copy next to the original and puts it into the same own albums (SPEC §7.16.2).
    static func saveCopy(_ item: MediaItem, with edits: PhotoEdits, original: URL, services: AccountServices) async throws {
        let directory = try workDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rendered = try PhotoEditor.render(edits, original: original, name: item.name, to: directory)
        let uploaded = try await Uploader(dav: services.dav).upload(
            file: rendered, fileName: rendered.lastPathComponent, folder: item.directory, capturedAt: item.capturedAt)
        let ownAlbums = Set(((try? services.collections.albums(.own)) ?? []).map(\.id))
        let memberships = (try? services.collections.memberships(of: [item.fileId])) ?? []
        for albumId in Set(memberships.filter { ownAlbums.contains($0.albumId) && $0.origin != "filters" }.map(\.albumId)) {
            if let album = try? services.collections.album(id: albumId) {
                try? await services.api.addToAlbum(album, userPath: uploaded.path)
            }
        }
    }

    private static func workDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "Edits/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
