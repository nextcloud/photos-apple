// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import Testing

@testable import PhotosDomain
@testable import PhotosModel
@testable import PhotosStore

/// Photo descriptions written on the device and the new search chips (SPEC §16.2).
@Suite(.timeLimit(.minutes(5))) struct PhotoDescriptionStoreTests {
    let database: AccountDatabase
    let library: LibraryStore
    let store: PhotoDescriptionStore

    init() throws {
        database = try AccountDatabase.temporary()
        library = LibraryStore(database: database)
        store = PhotoDescriptionStore(database: database)
        try library.upsert([
            MediaItem(fileId: 1, path: "/Photos/IMG_0001.jpg", mimeType: "image/jpeg", etag: "e1", capturedAt: Self.date(2019, 7)),
            MediaItem(fileId: 2, path: "/Photos/IMG_0002.jpg", mimeType: "image/jpeg", etag: "e2", capturedAt: Self.date(2020, 1)),
            MediaItem(fileId: 3, path: "/Photos/IMG_0003.mov", mimeType: "video/quicktime", etag: "e3", capturedAt: Self.date(2020, 2)),
            MediaItem(
                fileId: 4, path: "/Photos/IMG_0004.jpg", mimeType: "image/jpeg", etag: "e4", capturedAt: Self.date(2021, 3),
                hasPreview: false),
        ])
    }

    static func date(_ year: Int, _ month: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: 10, hour: 12))!
    }

    func candidate(_ id: FileID) throws -> PhotoDescriptionStore.Candidate {
        let item = try #require(try library.item(id))
        return PhotoDescriptionStore.Candidate(fileId: id, etag: item.etag)
    }

    func search(_ search: LibrarySearch) async throws -> [FileID] {
        try await library.search(search).map(\.fileId).sorted()
    }

    @Test func photosWithAPreviewAreDescribedOncePerVersion() throws {
        // Images with a preview, newest file ids first; not videos, not photos without a preview.
        #expect(try store.candidates(limit: 10).map(\.fileId) == [2, 1])
        #expect(try store.candidates(limit: 10, before: 2).map(\.fileId) == [1])
        try store.save([
            (try candidate(1), PhotoDescriptionStore.Result(text: "A dog on a beach at sunset", language: "en", source: .vision)),
            (try candidate(2), .failed),
        ])
        // A photo that could not be described is not tried again either.
        #expect(try store.candidates(limit: 10).isEmpty)
        #expect(try store.progress() == (described: 2, total: 2))
        #expect(try store.description(of: 1)?.text == "A dog on a beach at sunset")
        #expect(try store.description(of: 2) == nil)
        // A new version is described again; the old description no longer counts.
        var changed = try #require(try library.item(1))
        changed.etag = "e1b"
        try library.upsert([changed])
        #expect(try store.candidates(limit: 10).map(\.fileId) == [1])
        #expect(try store.description(of: 1) == nil)
    }

    @Test func searchFindsPhotosByTheirDescription() async throws {
        try store.save([
            (try candidate(1), PhotoDescriptionStore.Result(text: "A dog running on a beach", language: "en", source: .languageModel))
        ])
        #expect(try await search(LibrarySearch(texts: ["running"])) == [1])
        #expect(try await search(LibrarySearch(filters: [.label("beach")])) == [1])
        #expect(try await search(LibrarySearch(filters: [.label("beach"), .text("dog")])) == [1])
        // Described again: the index follows.
        try store.save([(try candidate(1), PhotoDescriptionStore.Result(text: "A cat on a sofa", language: "en", source: .vision))])
        #expect(try await search(LibrarySearch(texts: ["running"])).isEmpty)
        #expect(try await search(LibrarySearch(texts: ["sofa"])) == [1])
        // A new version of the file: its old description is no longer searched.
        var changed = try #require(try library.item(1))
        changed.etag = "e1b"
        try library.upsert([changed])
        #expect(try await search(LibrarySearch(texts: ["sofa"])).isEmpty)
        // Name and folder are still found as before.
        #expect(try await search(LibrarySearch(texts: ["IMG_0001"])) == [1])
    }

    @Test func turningOffDeletesEverythingAndTheIndexForgetsIt() async throws {
        try store.save([(try candidate(2), PhotoDescriptionStore.Result(text: "Two people in the snow", language: "en", source: .vision))])
        #expect(try await search(LibrarySearch(texts: ["snow"])) == [2])
        try store.deleteAll()
        #expect(try await search(LibrarySearch(texts: ["snow"])).isEmpty)
        #expect(try store.candidates(limit: 10).map(\.fileId) == [2, 1])
    }

    @Test func descriptionsGoWithTheirPhotos() throws {
        try store.save([(try candidate(1), PhotoDescriptionStore.Result(text: "A dog", language: "en", source: .vision))])
        try database.writer.write { db in try db.execute(sql: "DELETE FROM media WHERE fileId = 1") }
        let left = try database.writer.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM photoDescription") }
        #expect(left == 0)
    }

    /// Emptying the index (the timeline folders changed) keeps working with descriptions, and a photo that comes back
    /// with the same version is found by its description again.
    @Test func theIndexCanBeEmptiedAndRefilled() async throws {
        try store.save([(try candidate(1), PhotoDescriptionStore.Result(text: "A dog on a beach", language: "en", source: .vision))])
        let item = try #require(try library.item(1))
        try library.deleteIndex()
        #expect(try await search(LibrarySearch(texts: ["beach"])).isEmpty)
        try library.upsert([item])
        #expect(try await search(LibrarySearch(texts: ["beach"])) == [1])
        try library.deleteAll()
        #expect(try await search(LibrarySearch(texts: ["beach"])).isEmpty)
    }

    @Test func theLookupReadsOnlyDescriptionsInTheUsersLanguage() throws {
        try store.save([
            (try candidate(1), PhotoDescriptionStore.Result(text: "A dog on a beach", language: "en", source: .vision)),
            (try candidate(2), PhotoDescriptionStore.Result(text: "Ein Hund im Schnee", language: "de", source: .languageModel)),
        ])
        let lookup = PhotoDescriptionLookup(database: database)
        #expect(lookup.text(of: 1, language: "en") == "A dog on a beach")
        #expect(lookup.text(of: 2, language: "en") == nil)
        #expect(lookup.text(of: 2, language: "de") == "Ein Hund im Schnee")
        // Remembered until invalidated.
        try store.save([(try candidate(1), PhotoDescriptionStore.Result(text: "A cat", language: "en", source: .vision))])
        #expect(lookup.text(of: 1, language: "en") == "A dog on a beach")
        lookup.invalidate([1])
        #expect(lookup.text(of: 1, language: "en") == "A cat")
        lookup.isEnabled = false
        #expect(lookup.text(of: 1, language: "en") == nil)
    }

    @Test func stillPhotosRatingsAndYears() async throws {
        #expect(try await search(LibrarySearch(filters: [.photos])) == [1, 2, 4])
        #expect(try await search(LibrarySearch(filters: [.videos])) == [3])
        let labels = LabelStore(database: database)
        try labels.mergeTags([SystemTag(id: 13, name: "★★★"), SystemTag(id: 15, name: "★★★★★")])
        try labels.setMembers(ofTag: 13, [1], serverCount: 1)
        try labels.setMembers(ofTag: 15, [2], serverCount: 1)
        #expect(try await search(LibrarySearch(filters: [.rating(atLeast: 3)])) == [1, 2])
        #expect(try await search(LibrarySearch(filters: [.rating(atLeast: 4)])) == [2])
        #expect(try await search(LibrarySearch(filters: [.rating(atLeast: 4), .photos])) == [2])
        let years = try await library.years()
        #expect(years.map(\.year) == [2021, 2020, 2019])
        #expect(years.map(\.count) == [1, 2, 1])
    }

    @Test func knownLabelsComeFromWhatThisDeviceRecognised() throws {
        let labels = LabelStore(database: database)
        try labels.setVisionLabels([
            (LabelStore.VisionCandidate(fileId: 1, etag: "e1"), ["dog", "beach"]),
            (LabelStore.VisionCandidate(fileId: 2, etag: "e2"), ["dog", "sports car"]),
        ])
        let known = try store.knownLabels()
        #expect(known.first == "dog")
        #expect(Set(known) == ["dog", "beach", "sports", "car"])
    }
}
