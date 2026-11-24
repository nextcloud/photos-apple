// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import Testing

@testable import PhotosModel
@testable import PhotosStore

/// Ratings and flags in the index, and the Library filtered by them (SPEC §15.2).
@Suite(.timeLimit(.minutes(5))) struct CullingStoreTests {
    let database: AccountDatabase
    let library: LibraryStore
    let labels: LabelStore
    let store: CullingStore

    /// Files 1–6 with these tags (ids: ★ 11 … ★★★★★ 15, Pick 20, Rejected 21, Dog 30).
    static let tagsOfFile: [FileID: [Int]] = [1: [13, 20], 2: [11, 21], 3: [], 4: [15], 5: [21, 20], 6: [30]]
    static let tags = [
        SystemTag(id: 11, name: "★"), SystemTag(id: 12, name: "★★"), SystemTag(id: 13, name: "★★★"), SystemTag(id: 14, name: "★★★★"),
        SystemTag(id: 15, name: "★★★★★"), SystemTag(id: 20, name: "Pick"), SystemTag(id: 21, name: "rejected"),
        SystemTag(id: 30, name: "Dog"),
    ]

    init() throws {
        database = try AccountDatabase.temporary()
        library = LibraryStore(database: database)
        labels = LabelStore(database: database)
        store = CullingStore(database: database)
        try library.upsert(
            (1...6).map { id in
                MediaItem(
                    fileId: FileID(id), path: "/Photos/IMG_000\(id).jpg", mimeType: "image/jpeg", etag: "e\(id)",
                    capturedAt: Date(timeIntervalSince1970: Double(1_700_000_000 + id)))
            })
        try labels.mergeTags(Self.tags)
        for tag in Self.tags {
            let members = Set(Self.tagsOfFile.filter { $0.value.contains(tag.id) }.map(\.key))
            try labels.setMembers(ofTag: tag.id, members, serverCount: members.count)
        }
    }

    func mark(_ id: FileID) -> CullingMark {
        CullingTags.mark(fromTagNames: (Self.tagsOfFile[id] ?? []).compactMap { tagId in Self.tags.first { $0.id == tagId }?.name })
    }

    @Test func marksOfTheIndex() throws {
        let marks = try store.marks()
        #expect(marks[1] == CullingMark(rating: 3, flag: .pick))
        // "rejected" in lower case counts.
        #expect(marks[2] == CullingMark(rating: 1, flag: .reject))
        #expect(marks[3] == nil && marks[6] == nil)
        #expect(marks[5]?.flag == .pick)
        #expect(Set(try store.cullingTagNames(of: [1, 6])[1] ?? []) == ["★★★", "Pick"])
        #expect(try store.cullingTagNames(of: [6]).isEmpty)
        let known = try store.knownTags()
        #expect(known[.flag(.reject)]?.id == 21)
        #expect(known[.rating(5)]?.id == 15)
    }

    /// The database's filter and `CullingFilter.matches` agree for every filter and file.
    @Test(arguments: [
        CullingFilter.all, .picks, .rejected, .unflagged, .notRejected, .rating(atLeast: 1), .rating(atLeast: 3), .rating(atLeast: 5),
        .unrated,
    ])
    func gridFilterAgreesWithMarks(_ filter: CullingFilter) async throws {
        var stream = library.observeGrid(.all, culling: filter).makeAsyncIterator()
        let shown = Set(try await stream.next()?.map(\.fileId) ?? [])
        let expected = Set((1...6).map { FileID($0) }.filter { filter.matches(mark($0)) })
        #expect(shown == expected)
    }

    @Test func rejectedItemsForDeletion() throws {
        // File 5 is picked and rejected: Pick wins, it is not deleted.
        #expect(try store.items(matching: .rejected).map(\.fileId) == [2])
        #expect(try store.items(matching: .rejected, excludedFolders: ["/Photos"]).isEmpty)
    }

    @Test func marksFollowTagChanges() async throws {
        var marks = store.observeMarks().makeAsyncIterator()
        #expect(try await marks.next()?[3] == nil)
        try await database.writer.write { db in
            try TagChange(fileId: 3, tagId: 12, tagName: "★★", assign: true).applyLocally(db: db)
        }
        #expect(try await marks.next()?[3] == CullingMark(rating: 2))
    }

    @Test func rememberedTagsAreKnown() throws {
        try store.remember(SystemTag(id: 40, name: "Pick"))
        // The lower id wins when a meaning has two tags.
        #expect(try store.knownTags()[.flag(.pick)]?.id == 20)
    }
}
