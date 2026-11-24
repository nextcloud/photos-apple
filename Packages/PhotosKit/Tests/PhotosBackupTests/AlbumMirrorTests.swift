// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import Synchronization
import Testing

@testable import PhotosBackup
@testable import PhotosModel
@testable import PhotosNetworking
@testable import PhotosStore

struct FakeDeviceAlbums: DeviceAlbumSource {
    var albums: [DeviceAlbum]

    func albums(withIdentifiers identifiers: [String]) -> [DeviceAlbum] {
        albums.filter { identifiers.contains($0.id) }
    }
}

final class FakeMirrorRemote: AlbumMirrorRemote {
    struct State {
        var albums: Set<String> = []
        var items: [String: [String]] = [:]
        var failPaths: [String: NetworkError] = [:]
    }

    let state = Mutex(State())

    func albumNames() async throws -> Set<String> { state.withLock { $0.albums } }
    func createAlbum(_ name: String) async throws { _ = state.withLock { $0.albums.insert(name) } }
    func addToAlbum(_ name: String, path: String) async throws {
        try state.withLock { state in
            if let error = state.failPaths[path] { throw error }
            state.items[name, default: []].append(path)
        }
    }
}

@Suite struct AlbumMirrorTests {
    let database: AccountDatabase

    init() throws {
        database = try AccountDatabase.temporary()
        try database.writer.write { db in
            func entry(_ id: String, _ kind: BackupResourceKind, _ state: BackupItemState, _ path: String?) throws {
                try BackupLedgerEntry(
                    localIdentifier: id, resourceKind: kind.rawValue, state: state.rawValue, serverPath: path, attempts: 0, updatedAt: 0
                ).insert(db)
            }
            try entry("A", .photo, .uploaded, "/Photos/A.heic")
            try entry("B", .photo, .uploaded, "/Photos/B.heic")
            try entry("B", .edited, .uploaded, "/Photos/B (edited).heic")
            try entry("B", .pairedVideo, .uploaded, "/Photos/B.mov")
            try entry("C", .photo, .matched, "/InstantUpload/C.jpg")
            try entry("D", .photo, .pending, nil)
            try entry("E", .video, .failed, nil)
        }
    }

    var source: FakeDeviceAlbums {
        FakeDeviceAlbums(albums: [
            DeviceAlbum(id: "trip", title: "Trip / 2026", count: 4, assetIdentifiers: ["A", "B", "D", "E"]),
            DeviceAlbum(id: "cats", title: "Cats", count: 1, assetIdentifiers: ["C"]),
            DeviceAlbum(id: "other", title: "Not picked", count: 1, assetIdentifiers: ["A"]),
        ])
    }

    @Test func addsBackedUpPhotosOfPickedAlbumsOnce() async throws {
        let remote = FakeMirrorRemote()
        remote.state.withLock { $0.albums = ["Cats"] }
        let settings = AlbumMirrorSettings(isEnabled: true, albumIdentifiers: ["trip", "cats"])

        let first = try await AlbumMirror.run(settings: settings, source: source, remote: remote, database: database)
        #expect(first == AlbumMirror.Result(added: 3, albumsCreated: 1, failed: 0))
        let state = remote.state.withLock { $0 }
        #expect(state.albums == ["Cats", "Trip - 2026"], "an existing album of the same name is used; '/' is not allowed")
        // The edited version, not the original or the Live Photo's video; files not backed up yet wait.
        #expect(state.items["Trip - 2026"] == ["/Photos/A.heic", "/Photos/B (edited).heic"])
        #expect(state.items["Cats"] == ["/InstantUpload/C.jpg"], "a file the Files app had uploaded counts")
        #expect(state.items["Not picked"] == nil)

        // D is backed up later: only D is added by the next pass.
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE backupAsset SET state = 'uploaded', serverPath = '/Photos/D.heic' WHERE localIdentifier = 'D'")
        }
        let second = try await AlbumMirror.run(settings: settings, source: source, remote: remote, database: database)
        #expect(second.added == 1)
        #expect(remote.state.withLock { $0.items["Trip - 2026"] } == ["/Photos/A.heic", "/Photos/B (edited).heic", "/Photos/D.heic"])
    }

    @Test func doesNothingWhenOffOrNothingPicked() async throws {
        let remote = FakeMirrorRemote()
        for settings in [AlbumMirrorSettings(isEnabled: false, albumIdentifiers: ["trip"]), AlbumMirrorSettings(isEnabled: true)] {
            let result = try await AlbumMirror.run(settings: settings, source: source, remote: remote, database: database)
            #expect(result == AlbumMirror.Result())
        }
        #expect(remote.state.withLock { $0.albums.isEmpty })
    }

    @Test func aMissingFileIsSkippedAndAnOutageStopsThePass() async throws {
        let remote = FakeMirrorRemote()
        remote.state.withLock { $0.failPaths = ["/Photos/A.heic": .notFound, "/InstantUpload/C.jpg": .offline] }
        let settings = AlbumMirrorSettings(isEnabled: true, albumIdentifiers: ["trip", "cats"])
        await #expect(throws: NetworkError.offline) {
            _ = try await AlbumMirror.run(settings: settings, source: source, remote: remote, database: database)
        }
        // A (gone on the server) is not tried again; C (offline) is.
        remote.state.withLock { $0.failPaths = [:] }
        let again = try await AlbumMirror.run(settings: settings, source: source, remote: remote, database: database)
        #expect(again.added == 1)
        #expect(remote.state.withLock { $0.items["Cats"] } == ["/InstantUpload/C.jpg"])
        #expect(remote.state.withLock { $0.items["Trip - 2026"] } == ["/Photos/B (edited).heic"])
    }

    @Test func settingsLiveInTheAccountDatabase() throws {
        #expect(AlbumMirrorSettings.load(database) == AlbumMirrorSettings())
        let settings = AlbumMirrorSettings(isEnabled: true, albumIdentifiers: ["x"])
        try settings.save(database)
        #expect(AlbumMirrorSettings.load(database) == settings)
    }
}
