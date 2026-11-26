// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosDomain
@testable import PhotosModel

@Suite struct LibraryThumbnailPlanTests {
    @Test func theEstimateUsesMeasuredSizesWhereThereAreSome() {
        #expect(LibraryThumbnailPlan.estimatedBytes(photos: 0) == 0)
        // 11 200 + 2 450 bytes a photo before anything was measured: 50 000 photos take about 680 MB.
        #expect(LibraryThumbnailPlan.estimatedBytes(photos: 50_000) == 50_000 * 13_650)
        #expect(LibraryThumbnailPlan.estimatedBytes(photos: 10, averages: [256: 20_000]) == 10 * 22_450)
        #expect(LibraryThumbnailPlan.estimatedBytes(photos: 10, averages: [256: 20_000, 64: 1_000]) == 210_000)
        // A bucket measured as empty falls back to the typical size.
        #expect(LibraryThumbnailPlan.estimatedBytes(photos: 1, averages: [256: 0, 64: 0]) == 13_650)
    }

    @Test func onByDefaultOnlyOnTheMac() {
        #if os(macOS)
            #expect(LibraryThumbnailPlan.defaultEnabled)
        #else
            #expect(!LibraryThumbnailPlan.defaultEnabled)
        #endif
    }
}

@Suite struct FillPacingTests {
    @Test func stopsWithoutAnUnmeteredNetworkOrInLowPowerMode() {
        #expect(FillPacing.decide(FillConditions()) == .go)
        #expect(FillPacing.decide(FillConditions(isConnected: false)) == .stop)
        #expect(FillPacing.decide(FillConditions(isConstrained: true)) == .stop)
        #expect(FillPacing.decide(FillConditions(isLowPowerMode: true)) == .stop)
        #expect(FillPacing.decide(FillConditions(isExpensive: true)) == .stop)
        // Cellular when the user allowed it, but never in Low Data Mode or Low Power Mode.
        #expect(FillPacing.decide(FillConditions(isExpensive: true, allowsExpensive: true)) == .go)
        #expect(FillPacing.decide(FillConditions(isExpensive: true, isConstrained: true, allowsExpensive: true)) == .stop)
        #expect(FillPacing.decide(FillConditions(isExpensive: true, isLowPowerMode: true, allowsExpensive: true)) == .stop)
    }

    @Test func waitsWhileThePipelineLoadsAndForAQuietMomentAfter() {
        #expect(FillPacing.decide(FillConditions(pipelineIdle: false, idleFor: 0)) == .wait(FillPacing.busyRecheck))
        // Just idle: a pause between two loads of a scroll is not a gap to fill.
        #expect(FillPacing.decide(FillConditions(pipelineIdle: true, idleFor: 0.5)) == .wait(1.0))
        #expect(FillPacing.decide(FillConditions(pipelineIdle: true, idleFor: 1.5)) == .go)
        #expect(FillPacing.decide(FillConditions(pipelineIdle: true, idleFor: 0.2), quietPeriod: 0) == .go)
        // Conditions come first: no waiting for a quiet moment that would not help.
        #expect(FillPacing.decide(FillConditions(isConnected: false, pipelineIdle: false, idleFor: 0)) == .stop)
    }
}

@Suite struct PreparationPlanTests {
    typealias Photo = PreparationPlan.Photo

    func photos(_ ids: ClosedRange<Int>, aspectRatio: Double = 4.0 / 3.0) -> [Photo] {
        ids.map { Photo(fileId: FileID($0), etag: "e\($0)", aspectRatio: aspectRatio) }
    }

    /// iPhone at the default zoom: five columns of 77 pt, previews for 2×.
    let phone = PreparationPlan.Tiles(side: 77.2, scale: 2, square: true, perScreen: 5)

    @Test func tilesAskForTheBucketTheGridAsksFor() {
        // 77 pt × 2 × 4:3 = 206 px: the 256 px preview, a panorama needs the 1024 px one.
        #expect(phone.bucket(aspectRatio: 4.0 / 3.0) == 256)
        #expect(phone.bucket(aspectRatio: 3.0 / 4.0) == 256)
        #expect(phone.bucket(aspectRatio: 3) == 1024)
        // In the aspect-ratio grid the long edge fits the tile.
        var fit = phone
        fit.square = false
        #expect(fit.bucket(aspectRatio: 3) == 256)
        // The Mac at its default zoom: tiles of 130 pt need 1024.
        #expect(PreparationPlan.Tiles(side: 130, scale: 2, square: true, perScreen: 48).bucket(aspectRatio: 1.5) == 1024)
    }

    @Test func theFirstScreenComesFirstThenCoversThenTheRest() {
        let memory = PreparationPlan.Collection(cover: Photo(fileId: 100, etag: "m"), photos: photos(101...106))
        let album = PreparationPlan.Collection(cover: nil, photos: photos(201...210))
        let entries = PreparationPlan.entries(timeline: photos(1...12), memories: [memory], albums: [album], tiles: phone)
        let ids = entries.map(\.fileId)
        // Screen one of the timeline (5 tiles), the memory's cover, the album's cover (its first photo), screen two.
        #expect(Array(ids.prefix(12)) == [1, 2, 3, 4, 5, 100, 201, 6, 7, 8, 9, 10])
        // Then the memory's first pages (four) and the album's first screen.
        #expect(Array(ids.dropFirst(12)) == [101, 102, 103, 104, 201, 202, 203, 204, 205])
        #expect(entries.first { $0.fileId == 100 }?.bucket == PreparationPlan.coverBucket)
        #expect(entries.first { $0.fileId == 1 }?.bucket == 256)
        // The album's first photo is its cover (1024) and one of its tiles (256): both sizes are asked for.
        #expect(entries.filter { $0.fileId == 201 }.map(\.bucket) == [1024, 256])
    }

    @Test func entriesAreUniqueAndBounded() {
        let shared = PreparationPlan.Collection(cover: Photo(fileId: 1, etag: "e1"), photos: photos(1...3))
        let entries = PreparationPlan.entries(
            timeline: photos(1...10), memories: [shared, shared], albums: [], tiles: phone, limit: 7)
        #expect(entries.count == 7)
        #expect(Set(entries).count == entries.count)
        // Only three memories and three albums are prepared.
        let many = (1...5).map { PreparationPlan.Collection(cover: Photo(fileId: FileID(1000 + $0), etag: "c"), photos: []) }
        let covers = PreparationPlan.entries(timeline: [], memories: many, albums: many, tiles: phone).map(\.fileId)
        #expect(covers == [1001, 1002, 1003])
    }
}
