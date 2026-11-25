// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import Testing

@testable import PhotosDomain
@testable import PhotosModel
@testable import PhotosStore

@Suite struct FamilyStoreTests {
    static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    func item(
        _ id: FileID, _ date: Date, path: String? = nil, archived: Bool = false, mount: String = "", peer: FileID? = nil,
        motion: Bool = false
    ) -> MediaItem {
        MediaItem(
            fileId: id, path: path ?? "/Photos/p\(id).jpg", mimeType: motion ? "video/quicktime" : "image/jpeg", etag: "e\(id)",
            modifiedAt: date, capturedAt: date, mountType: mount, livePhotoPeer: peer, isLivePhotoVideo: motion, isArchived: archived)
    }

    func addPeople(_ database: AccountDatabase, _ pairs: [(String, FileID)]) async throws {
        try await database.writer.write { db in
            for (index, (name, fileId)) in pairs.enumerated() {
                try db.execute(sql: "INSERT OR IGNORE INTO person(name, itemCount) VALUES (?, 1)", arguments: [name])
                try db.execute(
                    sql: "INSERT INTO personItem(person, detectionId, fileId, childName) VALUES (?, ?, ?, ?)",
                    arguments: [name, index + 1, fileId, "\(fileId).jpg"])
            }
        }
    }

    @Test func candidatesAreOwnVisiblePhotosWithMembersOrFromTheDays() async throws {
        let database = try AccountDatabase.temporary()
        try LibraryStore(database: database).upsert([
            item(1, Self.date(2026, 10, 1)),  // Anna
            item(2, Self.date(2026, 10, 2)),  // nobody, other day
            item(3, Self.date(2026, 7, 4, 15)),  // the party day
            item(4, Self.date(2026, 10, 1), archived: true),  // Anna, archived
            item(5, Self.date(2026, 10, 1), path: "/Family/x.jpg"),  // Anna, already in the family folder
            item(6, Self.date(2026, 10, 1), mount: "shared"),  // Anna, someone else's file
            item(7, Self.date(2026, 10, 1), path: "/Photos/WhatsApp/y.jpg"),  // Anna, excluded folder
            item(8, Self.date(2026, 7, 4, 16), motion: true),  // the party day, a motion part
            item(9, Self.date(2026, 10, 3)),  // only an unnamed person
        ])
        try await addPeople(database, [("Anna", 1), ("Anna", 4), ("Anna", 5), ("Anna", 6), ("Anna", 7), ("Ben", 1), ("17", 9)])
        let store = FamilyStore(database: database)
        let party = DateInterval(start: Self.date(2026, 7, 4, 0), duration: 86_400)
        let candidates = try await store.candidates(
            members: ["Anna"], days: [party], familyFolder: "/Family", excludedFolders: ["/Photos/WhatsApp"])
        #expect(candidates.map(\.item.fileId).sorted() == [1, 3])
        #expect(candidates.first { $0.item.fileId == 1 }?.people == ["Anna", "Ben"])
        #expect(candidates.first { $0.item.fileId == 3 }?.people == [])
        #expect(try await store.candidates(members: [], days: [], familyFolder: "/Family", excludedFolders: []).isEmpty)
        #expect(try store.namedPeople().map(\.name).sorted() == ["Anna", "Ben"], "unnamed people are not offered as family")
    }

    @Test func decisionsAreRemembered() throws {
        let store = FamilyStore(database: try AccountDatabase.temporary())
        try store.record(.dismissed, for: [1, 2])
        try store.record(.moved, for: [3])
        try store.record(.copied, for: [2])
        #expect(try store.decidedFileIds() == [1, 2, 3])
        #expect(try store.decisionCount(.dismissed) == 1)
        #expect(try store.decisionCount(.copied) == 1)
        try store.forgetDecisions()
        #expect(try store.decidedFileIds().isEmpty)
    }

    @Test func livePhotoMotionPartsGoAlong() throws {
        let database = try AccountDatabase.temporary()
        try LibraryStore(database: database).upsert([
            item(1, Self.date(2026, 1, 1), peer: 2), item(2, Self.date(2026, 1, 1), peer: 1, motion: true), item(3, Self.date(2026, 1, 1)),
        ])
        let videos = try FamilyStore(database: database).livePhotoVideos(of: [1, 3])
        #expect(videos.keys.sorted() == [1])
        #expect(videos[1]?.fileId == 2)
    }

    @Test func photosOfAWeek() async throws {
        let database = try AccountDatabase.temporary()
        try LibraryStore(database: database).upsert([
            item(1, Self.date(2026, 11, 23)), item(2, Self.date(2026, 11, 29, 23)), item(3, Self.date(2026, 11, 30)),
            item(4, Self.date(2026, 11, 24), archived: true), item(5, Self.date(2026, 11, 25), mount: "shared"),
        ])
        let week = DateInterval(start: Self.date(2026, 11, 23, 0), duration: 7 * 86_400)
        let photos = try await FamilyStore(database: database).photosTaken(in: week, excludedFolders: [])
        #expect(photos.map(\.fileId) == [2, 1])
    }

    @Test func mirrorEntriesRoundTrip() throws {
        let store = FamilyStore(database: try AccountDatabase.temporary())
        try store.addMirrored(DeviceMirror.Entry(fileId: 1, etag: "a", localIdentifier: "L1"))
        try store.addMirrored(DeviceMirror.Entry(fileId: 2, etag: "b", localIdentifier: "L2"))
        try store.addMirrored(DeviceMirror.Entry(fileId: 1, etag: "a2", localIdentifier: "L3"))
        #expect(try store.mirroredEntries().count == 3)
        try store.removeMirrored(localIdentifiers: ["L1", "L2"])
        #expect(try store.mirroredEntries() == [DeviceMirror.Entry(fileId: 1, etag: "a2", localIdentifier: "L3")])
    }
}
