// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel
import Testing

@testable import PhotosDomain

/// Bursts no file name marks, bursts of this device, and the frame a burst shows (SPEC §21.4).
@Suite struct TimeBurstsTests {
    struct Item: CopyStackCandidate {
        var fileId: FileID
        var name: String
        var directory = "/Photos"
        var timestamp: Date
        var mimeType = "image/heic"
        var isVideo = false
        var hasPreview = true
        var isFavorite = false
        var burstIdentifier: String?
    }

    struct Evidence: BurstEvidence {
        var sketchById: [FileID: [Float]] = [:]
        var signalsById: [FileID: BestShot.Signals] = [:]
        func sketches(of ids: [FileID]) -> [FileID: [Float]] { sketchById.filter { ids.contains($0.key) } }
        func signals(of ids: [FileID]) -> [FileID: BestShot.Signals] { signalsById.filter { ids.contains($0.key) } }
    }

    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let scene: [Float] = [1, 0, 0, 0]
    let alike: [Float] = [0.97, 0.24, 0, 0]
    let other: [Float] = [0, 1, 0, 0]

    /// Timeline order: newest first, `seconds` before `base`.
    func item(_ id: FileID, _ seconds: TimeInterval, name: String? = nil, directory: String = "/Photos") -> Item {
        Item(fileId: id, name: name ?? "IMG_\(4400 + id).HEIC", directory: directory, timestamp: base.addingTimeInterval(-seconds))
    }

    func evidence(_ ids: [FileID], _ vector: [Float]? = nil) -> Evidence {
        Evidence(sketchById: Dictionary(uniqueKeysWithValues: ids.map { ($0, vector ?? scene) }))
    }

    @Test func aQuickRunOfAlikePhotosIsABurst() {
        // An iPhone burst uploaded frame by frame: eight frames in two seconds.
        let items = [item(1, 0), item(2, 0), item(3, 0), item(4, 1), item(5, 1), item(6, 1), item(7, 2), item(8, 2), item(9, 60)]
        let stacks = TimelineStacks.classified(items, evidence: evidence(Array(1...9)))
        #expect(stacks.count == 1)
        #expect(stacks.first?.isBurst == true)
        #expect(stacks.first?.members.sorted() == Array(0...7))
        // Without what this device worked out: not stacked (the conservative rule of round 4).
        #expect(TimelineStacks.stacks(items).isEmpty)
    }

    @Test func quickSingleShotsAreNotABurst() {
        // Three taps over three seconds: one a second is a thumb, not a burst.
        let items = [item(1, 0), item(2, 1), item(3, 2)]
        #expect(TimelineStacks.stacks(items, evidence: evidence([1, 2, 3])).isEmpty)
        // Two frames are never enough.
        #expect(TimelineStacks.stacks([item(1, 0), item(2, 0)], evidence: evidence([1, 2])).isEmpty)
    }

    @Test func aRunIsCutWhereThePictureChanges() {
        // The camera swung to another scene in the middle: two bursts.
        let items = [item(1, 0), item(2, 0), item(3, 0), item(4, 0), item(5, 1), item(6, 1), item(7, 1)]
        var known = evidence([1, 2, 3])
        for id: FileID in [4, 5, 6, 7] { known.sketchById[id] = other }
        let stacks = TimelineStacks.stacks(items, evidence: known)
        #expect(stacks.map { $0.sorted() } == [[0, 1, 2], [3, 4, 5, 6]])
        // Alike enough (the frames of a moving subject) stays one.
        var moving = evidence([1, 2, 3])
        for id: FileID in [4, 5, 6, 7] { moving.sketchById[id] = alike }
        #expect(TimelineStacks.stacks(items, evidence: moving).count == 1)
    }

    @Test func photosNotComparedYetAreNotStacked() {
        let items = [item(1, 0), item(2, 0), item(3, 0), item(4, 0)]
        // Frame 3 has no sketch: only 1–2 and 4 on either side, too few.
        #expect(TimelineStacks.stacks(items, evidence: evidence([1, 2, 4])).isEmpty)
    }

    @Test func otherFoldersAndVideosBreakARun() {
        let items = [item(1, 0), item(2, 0, directory: "/Other"), item(3, 0), item(4, 0)]
        #expect(TimelineStacks.stacks(items, evidence: evidence([1, 2, 3, 4])).isEmpty)
    }

    @Test func copiesOfAFrameCountOnce() {
        // HEIC + JPEG of three frames: still three frames, and the copies stay with their frame.
        let items = [
            item(1, 0, name: "IMG_1.HEIC"), item(2, 0, name: "IMG_1.JPG"), item(3, 0, name: "IMG_2.HEIC"), item(4, 0, name: "IMG_2.JPG"),
            item(5, 0, name: "IMG_3.HEIC"),
        ]
        let stacks = TimelineStacks.classified(items, evidence: evidence([1, 3, 5]))
        #expect(stacks.count == 1)
        #expect(stacks.first?.members.count == 5)
        // Copies alone (no burst) are a copy stack, as before.
        let copies = TimelineStacks.classified(Array(items.prefix(2)), evidence: evidence([1]))
        #expect(copies.first?.isBurst == false)
    }

    @Test func theBestFrameIsTheCover() {
        let items = [item(1, 0), item(2, 0), item(3, 0), item(4, 0)]
        var known = evidence([1, 2, 3, 4])
        for id: FileID in [1, 2, 4] { known.signalsById[id] = BestShot.Signals(sharpness: 6, exposure: 0.9) }
        known.signalsById[3] = BestShot.Signals(sharpness: 9, exposure: 0.9)
        #expect(TimelineStacks.stacks(items, evidence: known).first?.first == 2)
        // A favourite frame wins.
        var favorite = items
        favorite[0].isFavorite = true
        #expect(TimelineStacks.stacks(favorite, evidence: known).first?.first == 0)
    }

    @Test func aNamedBurstShowsItsBestFrameOnceAnalysed() {
        let items = [
            item(1, 0, name: "IMG_20171007_141256_BURST003.jpg"), item(2, 0, name: "IMG_20171007_141256_BURST002.jpg"),
            item(3, 1, name: "IMG_20171007_141256_BURST001_COVER.jpg"),
        ]
        // Not analysed: the camera's cover, as before.
        #expect(TimelineStacks.stacks(items).first?.first == 2)
        var known = Evidence()
        known.signalsById = [
            1: BestShot.Signals(sharpness: 9, exposure: 0.9), 2: BestShot.Signals(sharpness: 6, exposure: 0.9),
            3: BestShot.Signals(sharpness: 6.5, exposure: 0.9),
        ]
        #expect(TimelineStacks.stacks(items, evidence: known).first?.first == 0)
    }

    @Test func burstsOfThisDeviceGoByTheirIdentifier() {
        var items = [item(1, 0), item(2, 5), item(3, 30), item(4, 31)]
        items[0].burstIdentifier = "A"
        items[1].burstIdentifier = "A"
        items[2].burstIdentifier = "B"
        // A burst of one frame is no stack.
        let stacks = TimelineStacks.classified(items)
        #expect(stacks == [TimelineStacks.Stack(members: [0, 1], isBurst: true)])
    }
}
