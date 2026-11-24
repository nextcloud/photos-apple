// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import PhotosNetworking
import Synchronization

/// A folder someone shared with the user whose photos appear in the user's timeline ("partner sharing", SPEC SH-8).
///
/// Built from Nextcloud's normal sharing only: the partner shares a folder, and this app adds the received folder to the
/// folders it indexes. Nothing changes on the server, not even the Photos app's timeline folders, so the web app and
/// other devices are not affected.
public struct PartnerFolder: Codable, Hashable, Sendable, Identifiable {
    public var id: String { path }
    /// Where the received share is in the user's files (`/Anna's photos`).
    public var path: String
    public var ownerId: String
    public var ownerDisplayName: String

    public init(path: String, ownerId: String, ownerDisplayName: String) {
        self.path = path
        self.ownerId = ownerId
        self.ownerDisplayName = ownerDisplayName
    }
}

/// The partner folders of an account and whether their photos are shown. Kept in the account's database, so it goes with
/// the account (logout, removal, wipe).
public struct PartnerSettings: Codable, Hashable, Sendable {
    public var folders: [PartnerFolder] = []
    /// Off hides partner photos in the timeline; they stay indexed, so turning it on again is instant.
    public var showInTimeline = true

    public init(folders: [PartnerFolder] = [], showInTimeline: Bool = true) {
        self.folders = folders
        self.showInTimeline = showInTimeline
    }

    static let key = "partner.settings"

    public static func load(_ database: AccountDatabase) -> PartnerSettings {
        guard let json = try? database.syncValue(key), let data = json.data(using: .utf8) else { return PartnerSettings() }
        return (try? JSONDecoder().decode(PartnerSettings.self, from: data)) ?? PartnerSettings()
    }

    public func save(_ database: AccountDatabase) throws {
        try database.setSyncValue(Self.key, String(decoding: try JSONEncoder().encode(self), as: UTF8.self))
    }

    /// The partner folder that holds a file or folder path.
    public func partner(containing path: String) -> PartnerFolder? {
        folders.first { PartnerPaths.isBelow(path, $0.path) }
    }
}

/// The partner folders of an account, readable from any thread: the grid asks it for every tile it badges.
public final class PartnerPaths: Sendable {
    private let paths = Mutex<[String]>([])

    public init() {}

    public func set(_ folders: [String]) { paths.withLock { $0 = folders } }

    /// Whether a directory (`GridMedia.directory`) is a partner folder or below one.
    public func contains(directory: String) -> Bool {
        paths.withLock { folders in folders.contains { Self.isBelow(directory, $0) } }
    }

    public var isEmpty: Bool { paths.withLock { $0.isEmpty } }

    /// `path` is `folder` itself or inside it.
    public static func isBelow(_ path: String, _ folder: String) -> Bool {
        if folder == "/" { return true }
        let trimmed = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        return path == trimmed || path.hasPrefix(trimmed + "/")
    }
}

extension SyncEngine {
    /// Partner folders that the timeline folders do not cover already; they are indexed in addition.
    func partnerScopes(base: [String]) -> [String] {
        PartnerSettings.load(database).folders.map(\.path).filter { folder in !base.contains { PartnerPaths.isBelow(folder, $0) } }
    }

    /// Changes the partner folders of the timeline and brings the index in line: the photos of a new folder are read
    /// at once (that folder only, not the whole library), those of a removed one leave the index.
    ///
    /// Folders the timeline folders cover already only change their badge, nothing is fetched or removed.
    public func setPartnerFolders(_ folders: [PartnerFolder]) async throws {
        var settings = PartnerSettings.load(database)
        let old = Set(settings.folders.map(\.path))
        let new = Set(folders.map(\.path))
        settings.folders = folders
        try settings.save(database)
        let base = baseScopes
        for removed in old.subtracting(new) where !base.contains(where: { PartnerPaths.isBelow(removed, $0) }) {
            try removeIndexRows(below: removed)
            try database.setSyncValue(Key.rootETag(removed), nil)
        }
        for added in new.subtracting(old).sorted() where !base.contains(where: { PartnerPaths.isBelow(added, $0) }) {
            try await indexFolder(added)
        }
    }

    /// Reads every media file below one folder into the index, by modification time (every file has one), and stores the
    /// folder's ETag so the next sync only looks at what changed there.
    func indexFolder(_ folder: String) async throws {
        let etag = try await api.folderETag(folder)
        var cursor: Double?
        while true {
            try Task.checkCancellation()
            let page = try await api.indexPage(
                sourceFolders: [folder], mimeTypes: mimeTypes, properties: indexProperties, order: .modified, before: cursor, limit: 2000)
            try upsertFromServer(page.items)
            guard let next = page.next else { break }
            cursor = next
        }
        try storeRootETags([Root(folder: folder, etag: etag)])
    }

    func removeIndexRows(below folder: String) throws {
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM media WHERE path LIKE ? ESCAPE '\\'", arguments: [LibraryStore.likePrefix(folder)])
        }
    }
}
