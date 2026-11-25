// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import Testing

@testable import PhotosDomain
@testable import PhotosModel
@testable import PhotosStore

/// What rules read from the index and the camera details it keeps for them (SPEC §16.4).
@Suite(.timeLimit(.minutes(5))) struct OrganizeStoreTests {
    let database: AccountDatabase
    let library: LibraryStore
    let store: OrganizeStore

    init() throws {
        database = try AccountDatabase.temporary()
        library = LibraryStore(database: database)
        store = OrganizeStore(database: database)
        var items: [MediaItem] = []
        for id in 1...5 {
            let path: String = id == 5 ? "/Photos/Drone/DJI_5.jpg" : "/Photos/IMG_\(id).jpg"
            let captured = Date(timeIntervalSince1970: Double(1_700_000_000 + id))
            items.append(
                MediaItem(fileId: FileID(id), path: path, mimeType: "image/jpeg", etag: "e\(id)", capturedAt: captured, isArchived: id == 4)
            )
        }
        try library.upsert(items)
        let labels = LabelStore(database: database)
        try labels.mergeTags([SystemTag(id: 15, name: "★★★★★"), SystemTag(id: 30, name: "Drône")])
        try labels.setMembers(ofTag: 15, [1, 2], serverCount: 2)
        try labels.setMembers(ofTag: 30, [5], serverCount: 1)
        let collections = CollectionStore(database: database)
        try collections.upsertAlbum(Album(kind: .own, name: "Holiday"))
        try database.writer.write { db in
            try db.execute(sql: "INSERT INTO albumItem(albumId, fileId, childName) VALUES ('own:Holiday', 3, '3-IMG_3.jpg')")
        }
    }

    @Test func readsWhatRulesAsk() async throws {
        let context = try await store.ruleContext(camera: false)
        #expect(context.tagMembers["drone"] == [5])
        #expect(context.albumMembers["holiday"] == [3])
        #expect(context.marks[1]?.rating == 5)
        let items = try await store.ruleItems(excludedFolders: ["/Photos/Drone"])
        // The archived photo and the excluded folder are left out.
        #expect(Set(items.map(\.fileId)) == [1, 2, 3])
        let album = SmartAlbumDefinition(name: "Best", rule: .all([.condition(.rating(atLeast: 5))]))
        #expect(SmartRuleEvaluator.items(of: album, from: items, in: context).map(\.fileId) == [2, 1])
    }

    @Test func keepsCameraDetailsPerFileVersion() async throws {
        #expect(try await store.cameraDetailsProgress() == (0, 5))
        let missing = try await store.filesNeedingCameraDetails(limit: 10)
        #expect(missing.count == 5)
        try await store.storeCameraDetails([1: CameraDetails(make: "Canon", model: "EOS R5", focalLength: 50), 2: CameraDetails()])
        #expect(try await store.cameraDetailsProgress() == (2, 5))
        #expect(try await store.filesNeedingCameraDetails(limit: 10).count == 3)
        let context = try await store.ruleContext(camera: true)
        #expect(context.camera[1]?.focalLength == 50)
        // Empty details are known (not asked again) but not kept in the context.
        #expect(context.camera[2] == nil)
        #expect(try await store.cameraVocabulary().cameras == ["Canon EOS R5"])
        // A new version of the file is read again.
        try library.update(1) { $0.etag = "e1-new" }
        #expect(try await store.filesNeedingCameraDetails(limit: 10).contains(1))
    }

    @Test func namesAndFolders() async throws {
        let names = try store.fileNames(inFolders: ["/Photos"])
        #expect(names["/Photos"] == ["IMG_1.jpg", "IMG_2.jpg", "IMG_3.jpg", "IMG_4.jpg"])
        #expect(try await store.folders().first == "/Photos")
    }
}
