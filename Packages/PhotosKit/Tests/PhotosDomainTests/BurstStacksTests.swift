// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel
import Testing

@testable import PhotosDomain

/// Bursts the camera marked in the file names (SPEC TL-6 a), and how they combine with copies of one shot.
@Suite struct BurstStacksTests {
    struct Item: CopyStackCandidate {
        var fileId: FileID
        var name: String
        var directory = "/Photos"
        var timestamp: Date
        var mimeType: String
        var isVideo = false
        var hasPreview = true
    }

    let base = Date(timeIntervalSince1970: 1_700_000_000)

    func item(_ id: FileID, _ name: String, at offset: TimeInterval, directory: String = "/Photos") -> Item {
        let ext = (name as NSString).pathExtension.lowercased()
        let mime: String =
            switch ext {
            case "jpg": "image/jpeg"
            case "heic": "image/heic"
            case "mp4", "mov": "video/mp4"
            default: "image/x-raw"
            }
        return Item(
            fileId: id, name: name, directory: directory, timestamp: base.addingTimeInterval(-offset), mimeType: mime,
            isVideo: ext == "mp4" || ext == "mov")
    }

    @Test func markersOfTheCamerasThatNameBurstFrames() {
        // Google Camera: the frame number after BURST, the burst in front of it.
        let first = BurstStacks.marker("IMG_20171007_141256_BURST001_COVER.jpg")
        let second = BurstStacks.marker("IMG_20171007_141256_BURST002.jpg")
        #expect(first?.isCover == true)
        #expect(second?.isCover == false)
        #expect(first?.key == second?.key)
        #expect(first?.key != BurstStacks.marker("IMG_20171007_141300_BURST001.jpg")?.key)
        // Pixel 2: the burst is the long number after BURST, the frame number in front.
        let pixel = BurstStacks.marker("00000IMG_00000_BURST20180120152403_COVER.jpg")
        #expect(pixel?.isCover == true)
        #expect(pixel?.key == BurstStacks.marker("00001IMG_00001_BURST20180120152403.jpg")?.key)
        // Newer Pixels.
        #expect(
            BurstStacks.marker("PXL_20210727_172005836.BURST-01.COVER.jpg")?.key
                == BurstStacks.marker("PXL_20210727_172005836.BURST-02.jpg")?.key)
        #expect(BurstStacks.marker("PXL_20210727_172005836.BURST-01.COVER.jpg")?.isCover == true)
    }

    @Test func namesThatOnlyLookLikeABurstHaveNoMarker() {
        for name in ["sunburst_01.jpg", "Sunburst.jpg", "Burst_01.jpg", "IMG_BURST.jpg", "BURST.jpg", "IMG_1234.HEIC", "burst-03.jpg"] {
            #expect(BurstStacks.marker(name) == nil, "\(name)")
        }
        #expect(BurstStacks.marker("BURST01.jpg") != nil)
    }

    @Test func framesOfAMarkedBurstAreOneStackShowingTheCover() {
        let items = [
            item(1, "IMG_20171007_141256_BURST003.jpg", at: 0), item(2, "IMG_20171007_141256_BURST002.jpg", at: 0.1),
            item(3, "IMG_20171007_141256_BURST001_COVER.jpg", at: 0.2), item(4, "IMG_20171007_141300.jpg", at: 5),
        ]
        #expect(BurstStacks.stacks(items) == [[2, 0, 1]])
        #expect(TimelineStacks.stacks(items) == [[2, 0, 1]])
        // No cover: the newest frame.
        let uncovered = [item(1, "PXL_1.BURST-02.jpg", at: 0), item(2, "PXL_1.BURST-01.jpg", at: 0.3)]
        #expect(BurstStacks.stacks(uncovered) == [[0, 1]])
    }

    @Test func quickSeriesOfSingleShotsAreNotStacked() {
        // Ten frames 0.1 s apart from an iPhone: without the burst identifier, which the server does not report, they stay.
        let items = (0..<10).map { item(FileID($0 + 1), "IMG_10\($0).HEIC", at: Double($0) * 0.1) }
        #expect(BurstStacks.stacks(items).isEmpty)
        #expect(TimelineStacks.stacks(items).isEmpty)
    }

    @Test func otherFoldersVideosAndLaterBurstsStayApart() {
        let items = [
            item(1, "IMG_20171007_141256_BURST001.jpg", at: 0),
            item(2, "IMG_20171007_141256_BURST002.jpg", at: 0.1, directory: "/Photos/Copy"),
            item(3, "IMG_20171007_141256_BURST003.mp4", at: 0.2),
            // The same marker again two minutes later: another burst (a renamed or re-shot file), not this one.
            item(4, "IMG_20171007_141256_BURST004.jpg", at: 120),
        ]
        #expect(BurstStacks.stacks(items).isEmpty)
    }

    @Test func copiesOfBurstFramesBelongToTheBurst() {
        let items = [
            item(1, "IMG_20171007_141256_BURST002.dng", at: 0), item(2, "IMG_20171007_141256_BURST002.jpg", at: 0),
            item(3, "IMG_20171007_141256_BURST001_COVER.dng", at: 0.1), item(4, "IMG_20171007_141256_BURST001_COVER.jpg", at: 0.1),
            item(5, "IMG_0001.HEIC", at: 30), item(6, "IMG_0001.JPG", at: 30),
        ]
        // The cover's JPEG is shown; the RAW + JPEG pair of the other photo stays a copy stack of its own.
        #expect(TimelineStacks.stacks(items) == [[3, 0, 1, 2], [5, 4]])
        #expect(TimelineStacks.stacks(items, bursts: false) == [[1, 0], [3, 2], [5, 4]])
        // RAW + JPEG of a single burst frame are copies, not a burst.
        #expect(BurstStacks.stacks(Array(items[0...1])).isEmpty)
        #expect(TimelineStacks.stacks(Array(items[0...1])) == [[1, 0]])
    }

    @Test func aBurstTileIsToldFromACopyStack() {
        #expect(TimelineStacks.isBurst(leaderName: "IMG_20171007_141256_BURST001_COVER.jpg"))
        #expect(!TimelineStacks.isBurst(leaderName: "IMG_0001.JPG"))
    }

    /// 150 000 items with a burst every thousand: stacking stays linear.
    @Test func stackingALargeLibraryStaysFast() {
        var items: [Item] = []
        for index in 0..<150_000 {
            let name = index % 1000 < 5 ? "IMG_\(index / 1000)_BURST00\(index % 1000).jpg" : "IMG_\(index).JPG"
            items.append(item(FileID(index + 1), name, at: Double(index) * 0.5))
        }
        let clock = ContinuousClock()
        var stacks: [[Int]] = []
        let elapsed = clock.measure { stacks = TimelineStacks.stacks(items) }
        #expect(stacks.count == 150)
        #expect(elapsed < .seconds(3))
    }
}

/// The timeline's shape from the server's day counts during the first sync (SPEC §5.4.3).
@Suite struct TimelineSkeletonTests {
    let skeleton = TimelineSkeleton(days: [
        ("2026-11-22", 3), ("2026-11-02", 2), ("2026-10-31", 4), ("2025-01-01", 1), ("garbage", 9), ("2024-13-01", 5), ("2024-12-31", 0),
    ])

    @Test func daysAreSummedIntoMonthsAndYears() {
        #expect(skeleton.months == [202611: 5, 202610: 4, 202501: 1])
        #expect(skeleton.total == 10)
        #expect(skeleton.buckets(for: .day).map(\.key) == [202611, 202610, 202501])
        #expect(skeleton.buckets(for: .month).map(\.count) == [5, 4, 1])
        #expect(skeleton.buckets(for: .year) == [.init(key: 2026, count: 9), .init(key: 2025, count: 1)])
        #expect(TimelineSkeleton(days: []).isEmpty)
    }

    @Test func onlyTheOldestLoadedMonthAndOlderOnesGetPlaceholders() {
        // Nothing loaded: every month.
        #expect(
            skeleton.placeholders(granularity: .day, lastBucket: nil, loadedInLastBucket: 0).older.map(\.key) == [202611, 202610, 202501])
        // November complete, two of October's four loaded: the other two after them, then January 2025.
        let partial = skeleton.placeholders(granularity: .month, lastBucket: 202610, loadedInLastBucket: 2)
        #expect(partial.trailing == 2)
        #expect(partial.older == [.init(key: 202501, count: 1)])
        // More loaded than counted (shared folders, UTC days): no negative placeholders.
        #expect(skeleton.placeholders(granularity: .month, lastBucket: 202610, loadedInLastBucket: 7).trailing == 0)
        // A month the server did not count.
        let unknown = skeleton.placeholders(granularity: .month, lastBucket: 202609, loadedInLastBucket: 1)
        #expect(unknown.trailing == 0)
        #expect(unknown.older.map(\.key) == [202501])
        #expect(TimelineSkeleton.bucket(ofSectionId: 20261022, granularity: .day) == 202610)
        #expect(TimelineSkeleton.bucket(ofSectionId: 2026, granularity: .year) == 2026)
    }
}
