// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel
import Testing

@testable import PhotosDomain

/// Copies of one shot in the timeline (HEIC + JPEG, RAW + JPEG), stacked conservatively.
@Suite struct CopyStacksTests {
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

    func item(_ id: FileID, _ name: String, at offset: TimeInterval, mime: String? = nil, directory: String = "/Photos") -> Item {
        let ext = (name as NSString).pathExtension.lowercased()
        let guessed: String =
            switch ext {
            case "jpg", "jpeg": "image/jpeg"
            case "heic": "image/heic"
            case "mov": "video/quicktime"
            default: "image/x-raw"
            }
        return Item(
            fileId: id, name: name, directory: directory, timestamp: base.addingTimeInterval(-offset), mimeType: mime ?? guessed,
            isVideo: ext == "mov")
    }

    @Test func heicAndJpegOfOneShotAreOneStackShowingTheJpeg() {
        let items = [item(1, "IMG_0001.HEIC", at: 0), item(2, "IMG_0001.JPG", at: 0), item(3, "IMG_0002.HEIC", at: 60)]
        #expect(CopyStacks.stacks(items) == [[1, 0]])
    }

    @Test func rawAndJpegAStepApartAreOneStack() {
        let items = [item(1, "DSC_0042.NEF", at: 0), item(2, "dsc_0042.jpg", at: 1.5)]
        #expect(CopyStacks.stacks(items) == [[1, 0]])
    }

    @Test func aCopyWithAPreviewIsShownBeforeOneWithout() {
        var jpeg = item(2, "IMG_0001.JPG", at: 0)
        jpeg.hasPreview = false
        let items = [item(1, "IMG_0001.HEIC", at: 0), jpeg]
        #expect(CopyStacks.stacks(items) == [[0, 1]])
    }

    @Test func otherFoldersOtherNamesAndLaterShotsStayApart() {
        let items = [
            item(1, "IMG_0001.HEIC", at: 0), item(2, "IMG_0001.JPG", at: 0, directory: "/Photos/Export"),
            item(3, "IMG_0002.JPG", at: 0.5), item(4, "IMG_0003.HEIC", at: 10), item(5, "IMG_0003.JPG", at: 12.5),
        ]
        #expect(CopyStacks.stacks(items).isEmpty)
    }

    @Test func burstsWithDifferentNamesAreNotStacked() {
        // A burst: one frame every 0.1 s, every file its own name. Without a burst identifier from the server they stay.
        let items = (0..<10).map { item(FileID($0 + 1), "IMG_10\($0).HEIC", at: Double($0) * 0.1) }
        #expect(CopyStacks.stacks(items).isEmpty)
    }

    @Test func videosAreNeverStacked() {
        let items = [item(1, "IMG_0001.HEIC", at: 0), item(2, "IMG_0001.MOV", at: 0)]
        #expect(CopyStacks.stacks(items).isEmpty)
    }

    @Test func aLongRunOfShotsStillStacksOnlyCopiesTakenTogether() {
        // Photos every second for 20 s keep the run going; the two copies of shot 5 are found inside it.
        var items = (0..<20).map { item(FileID($0 + 1), "IMG_\(1000 + $0).HEIC", at: Double($0)) }
        items.insert(item(99, "IMG_1005.JPG", at: 5), at: 6)
        #expect(CopyStacks.stacks(items) == [[6, 5]])
    }

    @Test func threeCopiesAreOneStack() {
        let items = [item(1, "IMG_7.DNG", at: 0), item(2, "IMG_7.HEIC", at: 0.2), item(3, "IMG_7.JPG", at: 0.4)]
        #expect(CopyStacks.stacks(items) == [[2, 0, 1]])
    }

    @Test func baseNamesIgnoreCaseAndUnicodeForm() {
        #expect(CopyStacks.baseName("Café.HEIC") == CopyStacks.baseName("cafe\u{301}.jpg"))
        #expect(CopyStacks.baseName("archive.tar.gz") == "archive.tar")
        #expect(CopyStacks.baseName("README") == "readme")
    }
}

/// Stacked copies in the viewer, the folder trail of "Show in folder" and the slideshow's stepping.
@Suite struct ViewerExtrasTests {
    @Test func anOpenedStackPutsItsCopiesAfterTheTile() {
        let stacks: [Int: [Int]] = [2: [2, 20, 21], 4: [4, 40]]
        #expect(ViewerStacks.pages([1, 2, 3, 4], stacks: stacks, expanded: []) == [1, 2, 3, 4])
        #expect(ViewerStacks.pages([1, 2, 3, 4], stacks: stacks, expanded: [2]) == [1, 2, 20, 21, 3, 4])
        #expect(ViewerStacks.pages([1, 2, 3, 4], stacks: stacks, expanded: [2, 4]) == [1, 2, 20, 21, 3, 4, 40])
    }

    @Test func theTileOfACopyIsFound() {
        let stacks: [Int: [Int]] = [2: [2, 20, 21]]
        #expect(ViewerStacks.tile(of: 2, in: stacks) == 2)
        #expect(ViewerStacks.tile(of: 21, in: stacks) == 2)
        #expect(ViewerStacks.tile(of: 3, in: stacks) == nil)
    }

    @Test func showInFolderOpensEveryFolderOnTheWay() {
        #expect(FolderTrail.folders(to: "/Photos/2026/Trip") == ["/Photos", "/Photos/2026", "/Photos/2026/Trip"])
        #expect(FolderTrail.folders(to: "/") == [])
        #expect(FolderTrail.folders(to: "/A b/") == ["/A b"])
    }

    @Test func theSlideshowStartsOverAndStepsBack() {
        #expect(Slideshow.next(after: 0, count: 3) == 1)
        #expect(Slideshow.next(after: 2, count: 3) == 0)
        #expect(Slideshow.previous(before: 0, count: 3) == 2)
        #expect(Slideshow.next(after: 0, count: 0) == 0)
        #expect(Slideshow.previous(before: 0, count: 0) == 0)
    }

    @Test func reduceMotionDissolvesWithoutMovement() {
        #expect(Slideshow.drift(reduceMotion: true) == 1)
        #expect(Slideshow.drift(reduceMotion: false) > 1)
        #expect(Slideshow.crossfade(reduceMotion: true) < Slideshow.crossfade(reduceMotion: false))
        #expect(Slideshow.startsPlaying(voiceOver: false))
        #expect(!Slideshow.startsPlaying(voiceOver: true))
    }
}
