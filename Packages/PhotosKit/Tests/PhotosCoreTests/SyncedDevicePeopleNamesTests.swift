// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosDomain
import PhotosMedia
import PhotosModel
import Testing

@testable import PhotosCore
@testable import PhotosNetworking

/// On-device People names shared through `people.json` (SPEC §22.3, §22.5). Two "devices" are two stores that take over
/// each other's documents, as a sync through the server does.
@Suite(.timeLimit(.minutes(1))) struct SyncedDevicePeopleNamesTests {
    let server = StubServer()

    func store() -> SyncedSettingsStore {
        let connection = ServerConnection(serverURL: server.url, userId: "alice", loginName: "alice", appPassword: "x", userAgent: "tests")
        let dav = DAVClient(http: server.http(), connection: connection)
        // Never sent within a test: the devices exchange their documents directly.
        return SyncedSettingsStore(files: AppDataFiles(dav: dav), kind: .people, localFile: nil, sendDelay: .seconds(3600))
    }

    func exchange(_ a: SyncedSettingsStore, _ b: SyncedSettingsStore) async {
        await b.merge(a.snapshot())
        await a.merge(b.snapshot())
    }

    static func face(_ fileId: FileID, at time: Double) -> DevicePeopleDocument.FaceRef {
        DevicePeopleDocument.FaceRef(fileId: fileId, box: FaceBox(x: 0.2, y: 0.2, width: 0.3, height: 0.3), at: time)
    }

    @Test func namesOfTwoDevicesMeetAndARaceKeepsBothDevicesFaces() async throws {
        let macStore = store()
        let phoneStore = store()
        let mac = SyncedDevicePeopleNames(store: macStore, legacyFile: nil)
        let phone = SyncedDevicePeopleNames(store: phoneStore, legacyFile: nil)
        try await mac.update { $0.name("anna", "Anna", anchors: [Self.face(1, at: 100)], at: 100) }
        try await phone.update { $0.name("ben", "Ben", anchors: [Self.face(2, at: 101)], at: 101) }
        await exchange(macStore, phoneStore)
        #expect(try await mac.load().people["ben"]?.name == "Ben")
        #expect(try await phone.load().people["anna"]?.name == "Anna")
        // Both give Anna another face before seeing the other's change.
        try await mac.update { $0.assign([Self.face(3, at: 200)], to: "anna", at: 200) }
        try await phone.update { $0.assign([Self.face(4, at: 200)], to: "anna", at: 200) }
        await exchange(macStore, phoneStore)
        for names in [mac, phone] {
            let anna = try #require(try await names.load().people["anna"])
            #expect(Set(anna.faces.map(\.fileId)) == [1, 3, 4])
            #expect(anna.name == "Anna")
        }
        // One record per person in the shared file.
        #expect(Set(macStore.values(prefix: SyncedDevicePeopleNames.prefix).keys) == ["person/anna", "person/ben"])
    }

    @Test func namesKeptOnThisDeviceOnlyAreTakenInOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "people-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = directory.appending(path: "device-people.json")
        try await LocalDevicePeopleNames(file: legacy).update { $0.name("anna", "Anna", anchors: [Self.face(1, at: 100)], at: 100) }
        // Another device named someone else meanwhile, and renamed Anna later.
        let other = store()
        try await SyncedDevicePeopleNames(store: other, legacyFile: nil).update {
            $0.name("ben", "Ben", anchors: [], at: 150)
            $0.name("anna", "Anna Maria", anchors: [Self.face(5, at: 300)], at: 300)
        }
        let here = store()
        await here.merge(other.snapshot())
        let names = SyncedDevicePeopleNames(store: here, legacyFile: legacy)
        let document = try await names.load()
        #expect(document.people["ben"]?.name == "Ben")
        // The newer name wins; the faces of both are kept.
        #expect(document.people["anna"]?.name == "Anna Maria")
        #expect(Set(document.people["anna"]?.faces.map(\.fileId) ?? []) == [1, 5])
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        // What was taken in is shared now.
        #expect(here.value("person/anna") != nil)
    }
}
