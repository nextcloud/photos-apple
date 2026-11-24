// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import OSLog
import Photos
import PhotosModel
import PhotosNetworking
import PhotosStore

/// Which device albums are mirrored into Nextcloud albums (SPEC §7.18.9). Opt-in; kept in the backup account's database.
public struct AlbumMirrorSettings: Codable, Hashable, Sendable {
    public var isEnabled = false
    /// Local identifiers of the device albums the user picked.
    public var albumIdentifiers: [String] = []

    public init(isEnabled: Bool = false, albumIdentifiers: [String] = []) {
        self.isEnabled = isEnabled
        self.albumIdentifiers = albumIdentifiers
    }

    static let key = "albumMirror.settings"

    public static func load(_ database: AccountDatabase) -> AlbumMirrorSettings {
        guard let json = try? database.syncValue(key), let data = json.data(using: .utf8) else { return AlbumMirrorSettings() }
        return (try? JSONDecoder().decode(AlbumMirrorSettings.self, from: data)) ?? AlbumMirrorSettings()
    }

    public func save(_ database: AccountDatabase) throws {
        try database.setSyncValue(Self.key, String(decoding: try JSONEncoder().encode(self), as: UTF8.self))
    }
}

/// A user album of the device's photo library.
public struct DeviceAlbum: Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var count: Int
    /// Local identifiers of the assets in it (filled when mirroring, not for the list in Settings).
    public var assetIdentifiers: [String]

    public init(id: String, title: String, count: Int, assetIdentifiers: [String] = []) {
        self.id = id
        self.title = title
        self.count = count
        self.assetIdentifiers = assetIdentifiers
    }
}

/// The device's albums; PhotoKit in the app, a fake in tests.
protocol DeviceAlbumSource: Sendable {
    func albums(withIdentifiers identifiers: [String]) -> [DeviceAlbum]
}

/// The Nextcloud albums as the mirror sees them.
protocol AlbumMirrorRemote: Sendable {
    func albumNames() async throws -> Set<String>
    func createAlbum(_ name: String) async throws
    func addToAlbum(_ name: String, path: String) async throws
}

/// Mirrors device albums into Nextcloud albums of the same name: a backed-up photo that is in a picked device album is
/// added to the Nextcloud album (created when missing). Only adds: a photo taken out of the device album, or an album
/// renamed on the device, is not changed on the server. Runs after each backup pass; what it added is remembered, so a
/// photo the user removed from the Nextcloud album is not added again.
public enum AlbumMirror {
    /// What a mirror pass did.
    public struct Result: Equatable, Sendable {
        public var added = 0
        public var albumsCreated = 0
        public var failed = 0
    }

    static let stateKey = "albumMirror.added"

    /// Device album id → local identifiers already added.
    static func loadState(_ database: AccountDatabase) -> [String: [String]] {
        guard let json = try? database.syncValue(stateKey), let data = json.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: [String]].self, from: data)) ?? [:]
    }

    static func saveState(_ state: [String: [String]], _ database: AccountDatabase) throws {
        try database.setSyncValue(stateKey, String(decoding: try JSONEncoder().encode(state), as: UTF8.self))
    }

    /// The rendition shown in an album: the edited version when it was uploaded, otherwise the original.
    static let resourcePreference = [
        BackupResourceKind.edited, .editedVideo, .photo, .video,
    ].map(\.rawValue)

    /// Server paths of backed-up (uploaded or matched) assets.
    static func serverPaths(_ identifiers: [String], database: AccountDatabase) throws -> [String: String] {
        guard !identifiers.isEmpty else { return [:] }
        return try database.writer.read { db in
            var best: [String: (rank: Int, path: String)] = [:]
            let chunks = stride(from: 0, to: identifiers.count, by: 500).map { Array(identifiers[$0..<min($0 + 500, identifiers.count)]) }
            for chunk in chunks {
                let marks = chunk.map { _ in "?" }.joined(separator: ",")
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT localIdentifier, resourceKind, serverPath FROM backupAsset
                        WHERE state IN ('uploaded', 'matched') AND serverPath IS NOT NULL AND localIdentifier IN (\(marks))
                        """,
                    arguments: StatementArguments(chunk))
                for row in rows {
                    let identifier: String = row["localIdentifier"]
                    let kind: String = row["resourceKind"]
                    guard let rank = resourcePreference.firstIndex(of: kind) else { continue }
                    if let current = best[identifier], current.rank <= rank { continue }
                    best[identifier] = (rank, row["serverPath"])
                }
            }
            return best.mapValues(\.path)
        }
    }

    /// Album names may not contain `/`.
    static func albumName(_ title: String) -> String {
        let name = title.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Album" : name
    }

    static func run(
        settings: AlbumMirrorSettings, source: any DeviceAlbumSource, remote: any AlbumMirrorRemote, database: AccountDatabase
    ) async throws -> Result {
        var result = Result()
        guard settings.isEnabled, !settings.albumIdentifiers.isEmpty else { return result }
        var state = loadState(database)
        var existing: Set<String>?
        for album in source.albums(withIdentifiers: settings.albumIdentifiers) {
            try Task.checkCancellation()
            let done = Set(state[album.id] ?? [])
            let paths = try serverPaths(album.assetIdentifiers.filter { !done.contains($0) }, database: database)
            guard !paths.isEmpty else { continue }
            let name = albumName(album.title)
            if existing == nil { existing = try await remote.albumNames() }
            if existing?.contains(name) == false {
                try await remote.createAlbum(name)
                existing?.insert(name)
                result.albumsCreated += 1
            }
            var added = state[album.id] ?? []
            for identifier in album.assetIdentifiers {
                guard let path = paths[identifier] else { continue }
                do {
                    try await remote.addToAlbum(name, path: path)
                    added.append(identifier)
                    result.added += 1
                } catch let error as NetworkError where error.isTransient || error == .unauthorized {
                    state[album.id] = added
                    try saveState(state, database)
                    throw error
                } catch {
                    // The file was moved or deleted on the server since: it stays out of the album.
                    added.append(identifier)
                    result.failed += 1
                }
            }
            state[album.id] = added
            try saveState(state, database)
        }
        return result
    }

    /// Mirrors the picked albums of the device's library into the account behind `api`.
    public static func run(api: PhotosAPI, database: AccountDatabase) async throws -> Result {
        try await run(
            settings: AlbumMirrorSettings.load(database), source: PhotoKitAlbums(), remote: PhotosAlbumMirrorRemote(api: api),
            database: database)
    }
}

/// The user's own albums on the device (not shared or smart albums).
public struct PhotoKitAlbums: DeviceAlbumSource {
    public init() {}

    /// The albums to pick from, by title.
    public func userAlbums() -> [DeviceAlbum] {
        var albums: [DeviceAlbum] = []
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        collections.enumerateObjects { collection, _, _ in
            albums.append(
                DeviceAlbum(
                    id: collection.localIdentifier, title: collection.localizedTitle ?? "",
                    count: PHAsset.fetchAssets(in: collection, options: nil).count))
        }
        return albums.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func albums(withIdentifiers identifiers: [String]) -> [DeviceAlbum] {
        var albums: [DeviceAlbum] = []
        let collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: identifiers, options: nil)
        collections.enumerateObjects { collection, _, _ in
            var assets: [String] = []
            PHAsset.fetchAssets(in: collection, options: nil).enumerateObjects { asset, _, _ in assets.append(asset.localIdentifier) }
            albums.append(
                DeviceAlbum(
                    id: collection.localIdentifier, title: collection.localizedTitle ?? "", count: assets.count, assetIdentifiers: assets))
        }
        return albums
    }
}

struct PhotosAlbumMirrorRemote: AlbumMirrorRemote {
    let api: PhotosAPI

    func albumNames() async throws -> Set<String> {
        Set(try await api.listAlbums(.own, extended: false).map(\.name))
    }

    func createAlbum(_ name: String) async throws {
        try await api.createAlbum(name: name)
    }

    func addToAlbum(_ name: String, path: String) async throws {
        try await api.addToAlbum(Album(kind: .own, name: name), userPath: path)
    }
}
