// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosDomain
@testable import PhotosModel

/// Series of similar shots across the library, for Clean up (SPEC §19.3).
@Suite struct SimilarShotsTests {
    let start = Date(timeIntervalSince1970: 1_750_000_000)
    let scene: [Float] = [1, 0, 0, 0]
    let alike: [Float] = [0.95, 0.31, 0, 0]
    let other: [Float] = [0, 0, 1, 0]

    func photo(
        _ id: FileID, _ seconds: Double, _ vector: [Float], name: String? = nil, folder: String = "/Photos", size: Int64 = 1000,
        quality: Float? = nil, favorite: Bool = false, canDelete: Bool = true
    ) -> SimilarShots.Photo {
        SimilarShots.Photo(
            id: id, date: start.addingTimeInterval(seconds), vector: vector, quality: quality, isFavorite: favorite,
            size: size + id, name: name ?? "IMG_\(id).jpg", directory: folder, canDelete: canDelete)
    }

    @Test func seriesAreCutByLooksAndTime() {
        let photos = [
            photo(1, 0, scene), photo(2, 5, alike, quality: 0.9), photo(3, 9, scene),
            // Another scene in between ends the series.
            photo(4, 20, other),
            // Alike, but more than ten minutes later.
            photo(5, 20 + 11 * 60, other),
        ]
        let groups = SimilarShots.groups(photos.shuffled())
        #expect(groups.count == 1)
        let group = groups[0]
        #expect(group.ids == [1, 2, 3])
        #expect(group.best == 2, "the best-rated shot")
        #expect(group.kept == [2])
        #expect(group.others == [1, 3])
        #expect(group.bytes == 1001 + 1003)
    }

    @Test func newestSeriesFirst() {
        let photos = [photo(1, 0, scene), photo(2, 1, scene), photo(3, 100, other), photo(4, 101, other)]
        #expect(SimilarShots.groups(photos).map(\.ids) == [[3, 4], [1, 2]])
    }

    /// A HEIC and the JPEG beside it are one shot: never offered against each other, and the kept shot keeps both.
    @Test func copiesOfOneShotAreOneShot() {
        let heic = photo(1, 0, scene, name: "IMG_0001.HEIC")
        let jpeg = photo(2, 1, scene, name: "IMG_0001.JPG")
        #expect(SimilarShots.groups([heic, jpeg]).isEmpty, "two copies of one shot are no series")

        let favorite = photo(3, 4, alike, name: "IMG_0002.JPG", favorite: true)
        let groups = SimilarShots.groups([heic, jpeg, favorite])
        #expect(groups.count == 1)
        #expect(groups[0].shots == [[1, 2], [3]])
        #expect(groups[0].best == 3)
        #expect(groups[0].others == [1, 2], "the other shot goes with all its copies")
    }

    /// The same file in two folders is for Duplicates, not a series of shots.
    @Test func duplicatesAreNotSeries() {
        let first = SimilarShots.Photo(
            id: 1, date: start, vector: scene, size: 5000, name: "IMG_1.jpg", directory: "/Photos")
        let copy = SimilarShots.Photo(
            id: 2, date: start, vector: scene, size: 5000, name: "IMG_1.jpg", directory: "/Backup")
        #expect(SimilarShots.groups([first, copy]).isEmpty)
    }

    @Test func favouriteWinsAndOnlyDeletableFilesAreOffered() {
        let photos = [
            photo(1, 0, scene, quality: 0.9), photo(2, 2, scene, favorite: true), photo(3, 4, scene, canDelete: false),
            photo(4, 6, scene),
        ]
        let group = SimilarShots.groups(photos)[0]
        #expect(group.best == 2)
        #expect(group.others == [1, 4])
        #expect(group.bytes == 1001 + 1004)
    }

    @Test func aSeriesWithNothingToDeleteIsLeftOut() {
        let photos = [photo(1, 0, scene, favorite: true), photo(2, 1, scene, canDelete: false)]
        #expect(SimilarShots.groups(photos).isEmpty)
    }

    /// The builder is fed in time order from a database cursor; a reused builder starts over after `finish`.
    @Test func builderStartsOverAfterFinishing() {
        var builder = SimilarShots.Builder()
        builder.add(photo(1, 0, scene))
        builder.add(photo(2, 1, scene))
        #expect(builder.finish().count == 1)
        #expect(builder.finish().isEmpty)
    }

    @Test func totalsCountEachFileOnce() {
        #expect(CleanUpTotals.bytes([(1, 100), (2, 50), (1, 100)]) == 150)
        #expect(CleanUpTotals.bytes([]) == 0)
    }
}
