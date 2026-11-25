// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import Synchronization
import Testing

@testable import PhotosCore
@testable import PhotosDomain
@testable import PhotosModel
@testable import PhotosNetworking
@testable import PhotosStore

/// A device photo library in memory.
final class FakeDeviceLibrary: DeviceLibrary {
    struct State {
        var access = true
        var assets: [String: Data] = [:]
        var albums: [String: (title: String, members: Set<String>)] = [:]
        /// The user says no to deleting.
        var declinesDeletion = false
        var deletionPrompts = 0
        var next = 0
    }

    let state = Mutex(State())

    func requestAccess() async -> Bool { state.withLock { $0.access } }

    func existing(_ identifiers: [String]) async -> Set<String> {
        state.withLock { state in Set(identifiers.filter { state.assets[$0] != nil }) }
    }

    func album(identifier: String?, title: String) async throws -> String {
        state.withLock { state in
            if let identifier, state.albums[identifier] != nil {
                state.albums[identifier]?.title = title
                return identifier
            }
            state.next += 1
            let id = "album-\(state.next)"
            state.albums[id] = (title, [])
            return id
        }
    }

    func add(_ data: Data, created: Date?, latitude: Double?, longitude: Double?, album: String) async throws -> String {
        state.withLock { state in
            state.next += 1
            let id = "asset-\(state.next)"
            state.assets[id] = data
            state.albums[album]?.members.insert(id)
            return id
        }
    }

    func removeFromAlbum(_ identifiers: [String], album: String) async throws {
        state.withLock { state in state.albums[album]?.members.subtract(identifiers) }
    }

    func delete(_ identifiers: [String], album: String?) async -> Bool {
        state.withLock { state in
            state.deletionPrompts += 1
            guard !state.declinesDeletion else { return false }
            for id in identifiers { state.assets[id] = nil }
            if let album { state.albums[album] = nil }
            return true
        }
    }
}

@Suite(.timeLimit(.minutes(1))) @MainActor struct FamilyCoreTests {
    let server = StubServer()
    let sandbox = Sandbox()

    func makeServices() throws -> AccountServices {
        try AccountServices(
            account: makeAccount("alice", server: server.url.absoluteString), appPassword: "password", http: server.http(),
            features: ServerFeatures(serverVersion: ServerVersion(major: 33)), userAgent: "tests", layout: sandbox.layout,
            onUnauthorized: {})
    }

    func photo(_ id: FileID, etag: String? = nil, kind: MediaKind = .image, archived: Bool = false) -> MediaItem {
        MediaItem(
            fileId: id, path: "/Photos/p\(id).jpg", name: "p\(id).jpg", mimeType: kind == .video ? "video/mp4" : "image/jpeg", kind: kind,
            etag: etag ?? "e\(id)", modifiedAt: Date(), capturedAt: Date(), isArchived: archived)
    }

    /// An album with these photos in the account's database.
    func seedAlbum(_ services: AccountServices, _ items: [MediaItem]) throws -> Album {
        try services.library.upsert(items)
        let album = Album(kind: .own, name: "Summer")
        try services.collections.upsertAlbum(album)
        try services.database.writer.write { db in
            try db.execute(sql: "DELETE FROM albumItem WHERE albumId = ?", arguments: [album.id])
            for (index, item) in items.enumerated() {
                try db.execute(
                    sql: "INSERT INTO albumItem(albumId, fileId, childName, origin, position) VALUES (?, ?, ?, 'user', ?)",
                    arguments: [album.id, item.fileId, item.name, index])
            }
        }
        server.set { state in
            for item in items { state.downloads["/index.php/apps/photos/api/v1/preview/\(item.fileId)"] = Data("jpeg-\(item.fileId)".utf8) }
        }
        return album
    }

    func makeModel(_ services: AccountServices, _ library: FakeDeviceLibrary, hidden: Set<String> = []) -> LockScreenAlbumModel {
        LockScreenAlbumModel(services: services, library: library, hiddenPeople: { hidden }, refreshAlbum: { _ in })
    }

    @Test func lockScreenAlbumCopiesTheAlbumsPhotos() async throws {
        defer { sandbox.remove() }
        let services = try makeServices()
        let album = try seedAlbum(services, [photo(1), photo(2, kind: .video), photo(3, archived: true), photo(4)])
        let library = FakeDeviceLibrary()
        let model = makeModel(services, library)
        await model.choose(album)
        #expect(model.status.copies == 2)
        #expect(model.status.error == nil)
        let state = library.state.withLock { $0 }
        #expect(state.assets.count == 2, "no video, nothing archived")
        #expect(state.albums.values.first?.title == DeviceMirror.deviceAlbumTitle("Summer"))
        #expect(state.albums.values.first?.members.count == 2)
        #expect(Set(state.assets.values) == [Data("jpeg-1".utf8), Data("jpeg-4".utf8)])
        #expect(state.deletionPrompts == 0, "adding asks nothing")
        // Settings come back with the account.
        #expect(LockScreenAlbumSettings.load(services.database).albumId == album.id)
    }

    @Test func removedPhotosLeaveAndTurningOffDeletesEverything() async throws {
        defer { sandbox.remove() }
        let services = try makeServices()
        let album = try seedAlbum(services, [photo(1), photo(4)])
        let library = FakeDeviceLibrary()
        let model = makeModel(services, library)
        await model.choose(album)
        // 4 leaves the album, 1 is edited on the server.
        _ = try seedAlbum(services, [photo(1, etag: "e1-edited"), photo(5)])
        library.state.withLock { $0.declinesDeletion = true }
        await model.sync(force: true)
        var state = library.state.withLock { $0 }
        #expect(state.albums.values.first?.members.count == 2, "the album shows only what Nextcloud has")
        #expect(state.assets.count == 4, "the user has not allowed the deletion yet")
        #expect(model.settings.pendingDeletion.count == 2)
        // An automatic pass does not ask again about what the user declined.
        let prompts = library.state.withLock { $0.deletionPrompts }
        await model.sync(force: true)
        #expect(library.state.withLock { $0.deletionPrompts } == prompts)
        #expect(model.settings.pendingDeletion.count == 2)
        library.state.withLock { $0.declinesDeletion = false }
        await model.deletePending()
        state = library.state.withLock { $0 }
        #expect(state.assets.count == 2)
        #expect(model.settings.pendingDeletion.isEmpty)

        await model.turnOff()
        state = library.state.withLock { $0 }
        #expect(state.assets.isEmpty)
        #expect(state.albums.isEmpty, "the device album goes too")
        #expect(model.status.copies == 0)
        #expect(!model.settings.isOn)
        #expect(model.settings.deviceAlbumIdentifier == nil)
    }

    @Test func hiddenPeopleAndNoAccessKeepPhotosOff() async throws {
        defer { sandbox.remove() }
        let services = try makeServices()
        let album = try seedAlbum(services, [photo(1), photo(2)])
        try await services.database.writer.write { db in
            try db.execute(sql: "INSERT INTO person(name, itemCount) VALUES ('Secret', 1)")
            try db.execute(sql: "INSERT INTO personItem(person, detectionId, fileId, childName) VALUES ('Secret', 1, 2, 'p2.jpg')")
        }
        let library = FakeDeviceLibrary()
        library.state.withLock { $0.access = false }
        let model = makeModel(services, library, hidden: ["Secret"])
        await model.choose(album)
        #expect(model.status.accessDenied)
        #expect(!model.settings.isOn)
        library.state.withLock { $0.access = true }
        await model.choose(album)
        #expect(library.state.withLock { $0.assets.count } == 1, "a photo of a hidden person stays off the device")
    }

    @Test func olderStoredLockScreenSettingsAreRead() throws {
        let data = Data(#"{"albumId":"own:Summer","albumTitle":"Summer","pendingDeletion":["L1"]}"#.utf8)
        let settings = try JSONDecoder().decode(LockScreenAlbumSettings.self, from: data)
        #expect(settings.albumId == "own:Summer")
        #expect(settings.pendingDeletion == ["L1"])
        #expect(settings.declinedDeletion.isEmpty)
    }

    @Test func familyFileNamesGetANumberWhenTaken() {
        #expect(FamilyFileNames.destination(folder: "/Family/", name: "a.jpg", attempt: 1) == "/Family/a.jpg")
        #expect(FamilyFileNames.destination(folder: "/Family", name: "a.jpg", attempt: 2) == "/Family/a 2.jpg")
        #expect(FamilyFileNames.destination(folder: "/Family", name: "README", attempt: 3) == "/Family/README 3")
    }

    @Test func movingRecordsTheDecisionAndTakesTheMotionPartAlong() async throws {
        defer { sandbox.remove() }
        let services = try makeServices()
        var live = photo(1)
        live.livePhotoPeer = 2
        var motion = MediaItem(
            fileId: 2, path: "/Photos/p1.mov", name: "p1.mov", mimeType: "video/quicktime", modifiedAt: Date(), livePhotoPeer: 1)
        motion.isLivePhotoVideo = true
        try services.library.upsert([live, motion, photo(3)])
        try services.database.setSyncValue(
            "family.settings",
            #"{"folder":{"path":"/Family","kind":"own","ownerDisplayName":"","sharedWith":[]},"members":[],"copies":false}"#)
        server.set { state in
            for path in ["/Photos/p1.jpg", "/Photos/p1.mov", "/Photos/p3.jpg"] {
                state.responses["MOVE /remote.php/dav/files/alice\(path)"] = StubServer.Stub(status: 201, body: "")
            }
        }
        var changed = 0
        let model = FamilyLibraryModel(
            services: services, excludedFolders: { [] }, mimeTypes: { ["image/jpeg"] }, afterChange: { changed += 1 })
        #expect(model.settings.folder?.path == "/Family")
        let failed = await model.apply(.move, to: [live, photo(3)])
        #expect(failed == 0)
        #expect(
            server.requests.filter { $0.method == "MOVE" }.map(\.path).sorted() == [
                "/remote.php/dav/files/alice/Photos/p1.jpg", "/remote.php/dav/files/alice/Photos/p1.mov",
                "/remote.php/dav/files/alice/Photos/p3.jpg",
            ], "the motion part went along")
        #expect(try FamilyStore(database: services.database).decidedFileIds() == [1, 3])
        #expect(changed == 1)
        #expect(model.progress == nil)
    }

    @Test func aFailedMoveIsNotRecorded() async throws {
        defer { sandbox.remove() }
        let services = try makeServices()
        try services.library.upsert([photo(1)])
        try services.database.setSyncValue("family.settings", #"{"folder":{"path":"/Family","kind":"own"},"members":[],"copies":true}"#)
        let model = FamilyLibraryModel(services: services, excludedFolders: { [] }, mimeTypes: { [] }, afterChange: {})
        #expect(model.settings.folder?.path == "/Family", "older stored settings without every field are read")
        #expect(model.settings.copies)
        #expect(await model.apply(.copy, to: [photo(1)]) == 1, "the stub server answers 404")
        #expect(try FamilyStore(database: services.database).decidedFileIds().isEmpty)
    }

    func stubPostcard(_ folder: String, backStatus: Int = 201) {
        let base = "/remote.php/dav/files/alice"
        let encodedFolder = folder
        server.set { state in
            state.responses["MKCOL \(base)/Postcards"] = StubServer.Stub(status: 201, body: "")
            state.responses["PUT \(base)/Postcards/.nomedia"] = StubServer.Stub(status: 201, body: "")
            state.responses["MKCOL \(base)\(encodedFolder)"] = StubServer.Stub(status: 405, body: "")
            state.responses["MKCOL \(base)\(encodedFolder) 2"] = StubServer.Stub(status: 201, body: "")
            state.responses["PUT \(base)\(encodedFolder) 2/1 Front.jpg"] = StubServer.Stub(status: 201, body: "")
            state.responses["PUT \(base)\(encodedFolder) 2/2 Back.jpg"] = StubServer.Stub(status: backStatus, body: "")
            state.responses["DELETE \(base)\(encodedFolder) 2"] = StubServer.Stub(status: 204, body: "")
            state.responses["POST /ocs/v2.php/apps/files_sharing/api/v1/shares"] = StubServer.Stub(
                status: 200,
                body: String(
                    decoding: StubServer.ocs(
                        #"{"id":"5","share_type":3,"path":"/Postcards/x","item_type":"folder","url":"https://cloud.test/s/abc"}"#),
                    as: UTF8.self))
        }
    }

    @Test func aPostcardIsTwoPicturesInAFolderWithALink() async throws {
        defer { sandbox.remove() }
        let services = try makeServices()
        let now = Date()
        let folder = "/Postcards/" + PostcardFiles.folderName(date: now, place: "Lisbon")
        stubPostcard(folder)
        let content = PostcardContent(message: "Hi!", recipient: "Grandma", place: "Lisbon", date: now)
        let sent = try await PostcardSender.send(
            front: Data("f".utf8), back: Data("b".utf8), content: content, services: services, now: now)
        #expect(sent.folder == folder + " 2", "the taken name gets a number")
        #expect(sent.link == URL(string: "https://cloud.test/s/abc"))
        let share = try #require(server.requests.first { $0.method == "POST" })
        #expect(share.body.contains("shareType=3"))
        #expect(share.body.contains("note=Hi"))
        #expect(share.body.contains("Grandma"), "the link's label names the recipient")
        #expect(
            server.requests.contains { $0.method == "PUT" && $0.path.hasSuffix("/Postcards/.nomedia") }, "cards stay out of the timeline")
    }

    @Test func aFailedUploadLeavesNoHalfCard() async throws {
        defer { sandbox.remove() }
        let services = try makeServices()
        let now = Date()
        let folder = "/Postcards/" + PostcardFiles.folderName(date: now, place: "Lisbon")
        stubPostcard(folder, backStatus: 507)
        let content = PostcardContent(place: "Lisbon", date: now)
        await #expect(throws: NetworkError.self) {
            try await PostcardSender.send(front: Data("f".utf8), back: Data("b".utf8), content: content, services: services, now: now)
        }
        #expect(server.requests.contains { $0.method == "DELETE" && $0.path.hasSuffix(" 2") })
        #expect(!server.requests.contains { $0.method == "POST" })
    }

    @Test func postcardLinkLabels() {
        #expect(PostcardFiles.linkLabel(recipient: " ").isEmpty == false)
        #expect(PostcardFiles.linkLabel(recipient: "Grandma").contains("Grandma"))
    }
}
