// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import Testing

@testable import PhotosDomain
@testable import PhotosModel
@testable import PhotosStore

/// The camera data of Insights in the index (SPEC §16.5.1).
@Suite(.timeLimit(.minutes(5))) struct InsightsStoreTests {
    let database: AccountDatabase
    let library: LibraryStore
    let labels: LabelStore
    let store: InsightsStore

    /// Files 1–8: photos with these facts; 9 is a video, 10 an archived photo, 11 a photo in a `.nomedia` folder.
    static let facts: [FileID: ExifFacts] = [
        1: ExifFacts(
            camera: "Nikon D700", lens: "AF-S 35mm f/1.8G", focalLength: 35, aperture: 1.8, iso: 200, exposure: 1.0 / 250, hour: 9),
        2: ExifFacts(camera: "Nikon D700", lens: "AF-S 35mm f/1.8G", focalLength: 36, aperture: 2, iso: 400, exposure: 1.0 / 60, hour: 9),
        3: ExifFacts(
            camera: "Nikon D700", lens: "AF-S 85mm f/1.8G", focalLength: 85, aperture: 2.8, iso: 3200, exposure: 1.0 / 30, hour: 21),
        4: ExifFacts(
            camera: "iPhone 14 Pro", focalLength: 6.86, focalLength35: 24, aperture: 1.78, iso: 50, exposure: 1.0 / 4000, hour: 14),
        5: ExifFacts(camera: "iPhone 14 Pro", focalLength: 9, focalLength35: 77, aperture: 2.8, iso: 64, exposure: 1.0 / 1000, hour: 14),
        6: ExifFacts(camera: "iPhone 14 Pro", focalLength: 2.22, focalLength35: 13, aperture: 2.2, iso: 640, exposure: 2, hour: 23),
        7: ExifFacts(hour: 7),
        8: ExifFacts(),
    ]
    /// Tags: ★★★ 13, Pick 20, Rejected 21.
    static let tagsOfFile: [FileID: [Int]] = [1: [20], 2: [13, 21], 3: [13], 4: [20, 21], 5: [21]]

    init() throws {
        database = try AccountDatabase.temporary()
        library = LibraryStore(database: database)
        labels = LabelStore(database: database)
        store = InsightsStore(database: database)
        var items = (1...8).map { id in
            MediaItem(
                fileId: FileID(id), path: "/Photos/IMG_000\(id).jpg", mimeType: "image/jpeg", etag: "e\(id)",
                capturedAt: Date(timeIntervalSince1970: Double(1_700_000_000 + id)))
        }
        items.append(MediaItem(fileId: 9, path: "/Photos/MOV_9.mov", mimeType: "video/quicktime", etag: "e9"))
        items.append(MediaItem(fileId: 10, path: "/Photos/IMG_10.jpg", mimeType: "image/jpeg", etag: "e10", isArchived: true))
        items.append(MediaItem(fileId: 11, path: "/Photos/Private/IMG_11.jpg", mimeType: "image/jpeg", etag: "e11"))
        try library.upsert(items)
        let tags = [SystemTag(id: 13, name: "★★★"), SystemTag(id: 20, name: "Pick"), SystemTag(id: 21, name: "Rejected")]
        try labels.mergeTags(tags)
        for tag in tags {
            let members = Set(Self.tagsOfFile.filter { $0.value.contains(tag.id) }.map(\.key))
            try labels.setMembers(ofTag: tag.id, members, serverCount: members.count)
        }
    }

    func mark(_ id: FileID) -> CullingMark {
        let names: [String: Int] = ["★★★": 13, "Pick": 20, "Rejected": 21]
        return CullingTags.mark(fromTagNames: names.filter { (Self.tagsOfFile[id] ?? []).contains($0.value) }.map(\.key))
    }

    func storeAll() throws {
        var values: [FileID: (etag: String, facts: ExifFacts)] = [:]
        for (id, facts) in Self.facts { values[id] = ("e\(id)", facts) }
        try store.store(values)
    }

    @Test func pendingAreTheLibrarysPhotosWithoutData() throws {
        let pending = try store.pending(limit: 100, excludedFolders: ["/Photos/Private"])
        // Newest first; no video, no archived photo, nothing of a `.nomedia` folder.
        #expect(pending.map(\.fileId) == [8, 7, 6, 5, 4, 3, 2, 1])
        #expect(pending.first?.etag == "e8" && pending.first?.path == "/Photos/IMG_0008.jpg")
        #expect(try store.pending(limit: 3).map(\.fileId) == [8, 7, 6])
        try storeAll()
        #expect(try store.pending(limit: 100, excludedFolders: ["/Photos/Private"]).isEmpty)
        #expect(try store.pending(limit: 100).map(\.fileId) == [11])
    }

    @Test func aChangedPhotoIsReadAgain() async throws {
        try storeAll()
        try library.upsert([MediaItem(fileId: 3, path: "/Photos/IMG_0003.jpg", mimeType: "image/jpeg", etag: "changed")])
        #expect(try store.pending(limit: 100, excludedFolders: ["/Photos/Private"]).map(\.fileId) == [3])
        let progress = try await store.progress(excludedFolders: ["/Photos/Private"])
        #expect(progress.analysed == 7 && progress.total == 8)
    }

    @Test func progressAndOrphans() async throws {
        var progress = try await store.progress()
        #expect(progress.analysed == 0 && progress.total == 9)
        try storeAll()
        try store.store([99: ("gone", ExifFacts(camera: "Gone"))])
        progress = try await store.progress()
        #expect(progress.analysed == 8 && progress.total == 9)
        try store.removeOrphans()
        let count = try await database.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM photoExif") }
        #expect(count == 8)
    }

    @Test func rowsCarryFactsAndMarks() async throws {
        try storeAll()
        let rows = try await store.rows()
        #expect(rows.count == 8)
        #expect(Set(rows.map(\.facts)) == Set(Self.facts.values))
        let summary = PhotoInsights.summarize(rows)
        #expect(summary.cameras.map(\.key) == ["iPhone 14 Pro", "Nikon D700"])
        // 1 (Pick), 3 (★★★) and 4 (Pick and Rejected: Pick wins) are keepers; 2 is rated but rejected.
        #expect(summary.keepers == 3)
        #expect(summary.reviewed == 5)
    }

    /// Every filter the screen can make, against `InsightsFilter.matches`.
    static let filters: [InsightsFilter] = [
        .camera("Nikon D700"), .camera("iPhone 14 Pro"), .lens("AF-S 35mm f/1.8G"), .focalLength(35), .focalLength(24),
        .focalLength(70), .focalLength(12), .aperture(1.8), .aperture(2.8), .iso(200), .iso(3200), .iso(50), .shutter(1.0 / 250),
        .shutter(1.0 / 60), .shutter(2), .shutter(1.0 / 4000), .hour(9), .hour(14), .hour(7), .hour(3),
        .keepers(lens: "AF-S 35mm f/1.8G", camera: nil), .keepers(lens: "AF-S 85mm f/1.8G", camera: nil),
        .keepers(lens: nil, camera: "iPhone 14 Pro"),
    ]

    @Test(arguments: filters)
    func filterAgreesWithMatches(_ filter: InsightsFilter) async throws {
        try storeAll()
        let shown = try await store.items(matching: filter).map(\.fileId)
        let expected = (1...8).map { FileID($0) }.filter { filter.matches(Self.facts[$0]!, mark: mark($0)) }
        #expect(Set(shown) == Set(expected))
        // Newest first.
        #expect(shown == shown.sorted(by: >))
    }

    @Test func filtersFindWhatTheyShould() async throws {
        try storeAll()
        #expect(try await store.items(matching: .focalLength(35)).map(\.fileId) == [2, 1])
        // The 35 mm equivalent counts: the iPhone's main camera is a 24 mm.
        #expect(try await store.items(matching: .focalLength(24)).map(\.fileId) == [4])
        #expect(try await store.items(matching: .keepers(lens: nil, camera: "iPhone 14 Pro")).map(\.fileId) == [4])
        #expect(try await store.items(matching: .keepers(lens: "AF-S 35mm f/1.8G", camera: nil)).map(\.fileId) == [1])
        #expect(try await store.items(matching: .camera("Nikon D700"), excludedFolders: ["/Photos"]).isEmpty)
    }
}
