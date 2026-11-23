// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosDomain
@testable import PhotosModel

private func file(
    _ id: FileID, _ name: String, mime: String = "image/png", size: Int64 = 1000, width: Int? = nil, height: Int? = nil,
    latitude: Double? = nil, longitude: Double? = nil, permissions: String = "RGDNVW", livePhotoVideo: Bool = false
) -> MediaItem {
    MediaItem(
        fileId: id, path: "/Pictures/\(name)", mimeType: mime, size: size, width: width, height: height, latitude: latitude,
        longitude: longitude, permissions: Permissions(rawValue: permissions), isLivePhotoVideo: livePhotoVideo)
}

@Suite struct CleanupTests {
    /// The bug: every PNG was offered for deletion as a "screenshot".
    @Test func aPNGAloneIsNotAScreenshot() {
        #expect(!Cleanup.isScreenshot(file(1, "logo.png")))
        #expect(!Cleanup.isScreenshot(file(2, "scan-contract.png", width: 2480, height: 3508)))
        #expect(!Cleanup.isScreenshot(file(3, "drawing.PNG", width: 1024, height: 1024)))
        #expect(!Cleanup.isScreenshot(file(4, "IMG_0001.PNG")))  // no dimensions known: not enough evidence
        #expect(Cleanup.candidates([file(1, "logo.png"), file(2, "diagram.png", width: 800, height: 600)]).isEmpty)
    }

    @Test(arguments: [
        "Screenshot 2026-11-23 at 10.00.00.png", "Screen Shot 2019-03-01 at 09.12.44.png", "Screenshot_20240101-120000.jpg",
        "screen-shot.webp", "Bildschirmfoto 2026-01-02 um 08.00.00.png", "Capture d’écran 2025-05-05.png", "Capture d'écran.png",
        "Capture d’e\u{301}cran 2025.png", "Captura de pantalla 2024-02-02.png", "Schermafbeelding 2023-03-03.png",
    ])
    func screenshotNames(name: String) {
        #expect(Cleanup.isScreenshot(file(1, name, mime: name.hasSuffix("jpg") ? "image/jpeg" : "image/png")))
    }

    @Test(arguments: ["screenplay shots.png", "sunscreen.png", "Screens of the shop.png", "IMG_1234.PNG", "holiday.jpg"])
    func namesThatAreNotScreenshots(name: String) {
        #expect(!Cleanup.isScreenshot(file(1, name)))
    }

    @Test func phoneScreenSizedPNGIsAScreenshotInEitherOrientation() {
        #expect(Cleanup.isScreenshot(file(1, "IMG_0042.PNG", width: 1170, height: 2532)))
        #expect(Cleanup.isScreenshot(file(2, "IMG_0043.PNG", width: 2532, height: 1170)))
        #expect(Cleanup.isScreenshot(file(3, "IMG_0044.png", mime: "IMAGE/PNG", width: 1080, height: 2400)))
        // One pixel off, or a camera-like size: not a screenshot.
        #expect(!Cleanup.isScreenshot(file(4, "IMG_0045.PNG", width: 1170, height: 2531)))
        #expect(!Cleanup.isScreenshot(file(5, "IMG_0046.PNG", width: 4032, height: 3024)))
    }

    @Test func screenSizedPictureIsNotAScreenshotWhenItIsNotAPNGOrHasALocation() {
        #expect(!Cleanup.isScreenshot(file(1, "IMG_0042.JPG", mime: "image/jpeg", width: 1170, height: 2532)))
        #expect(!Cleanup.isScreenshot(file(2, "IMG_0042.HEIC", mime: "image/heic", width: 1080, height: 1920)))
        #expect(!Cleanup.isScreenshot(file(3, "IMG_0042.PNG", width: 1170, height: 2532, latitude: 48.1, longitude: 11.5)))
    }

    @Test func videosAreNeverScreenshotsAndImagesNeverRecordings() {
        #expect(!Cleanup.isScreenshot(file(1, "Screenshot.mp4", mime: "video/mp4")))
        #expect(!Cleanup.isScreenRecording(file(2, "Screen Recording.png")))
        #expect(!Cleanup.isLargeVideo(file(3, "huge.png", size: 500 * 1024 * 1024)))
    }

    @Test(arguments: [
        "Screen Recording 2026-11-23 at 10.00.00.mov", "ScreenRecording_11-23-2026.mp4", "Screen_Recording_20240101.mp4",
        "screencast-2024.webm", "Bildschirmaufnahme 2026-01-02.mov", "Enregistrement de l’écran 2025.mov",
        "Grabación de pantalla 2024.mov", "Schermopname 2023.mov",
    ])
    func screenRecordingNames(name: String) {
        #expect(Cleanup.isScreenRecording(file(1, name, mime: "video/mp4")))
    }

    @Test func largeVideoThresholdIsExclusive() {
        #expect(!Cleanup.isLargeVideo(file(1, "a.mp4", mime: "video/mp4", size: Cleanup.largeVideoSize)))
        #expect(Cleanup.isLargeVideo(file(2, "b.mp4", mime: "video/mp4", size: Cleanup.largeVideoSize + 1)))
    }

    @Test func candidatesAreInOneCategoryAtMostSortedBySizeAndDeletable() {
        let big = Cleanup.largeVideoSize + 10
        let items = [
            file(1, "Screenshot small.png", size: 10), file(2, "Screenshot big.png", size: 30),
            file(3, "Screen Recording.mov", mime: "video/quicktime", size: big),  // large, but listed once as a recording
            file(4, "film.mp4", mime: "video/mp4", size: big), file(5, "clip.mp4", mime: "video/mp4", size: 5),
            file(6, "Screenshot shared.png", size: 99, permissions: "RG"),  // no delete permission
            file(7, "photo.png", size: 999), file(8, "live.mov", mime: "video/quicktime", size: big, livePhotoVideo: true),
        ]
        let result = Cleanup.candidates(items)
        #expect(result.map(\.category) == [.screenshots, .screenRecordings, .largeVideos])
        #expect(result[0].items.map(\.fileId) == [2, 1])
        #expect(result[0].totalBytes == 40)
        #expect(result[1].items.map(\.fileId) == [3])
        #expect(result[2].items.map(\.fileId) == [4])
    }
}

@Suite struct DuplicateKeeperTests {
    private func copy(
        _ id: FileID, _ path: String, uploaded: Date? = nil, favorite: Bool = false, mount: String = "", permissions: String = "RGDNVW"
    ) -> MediaItem {
        MediaItem(
            fileId: id, path: path, mimeType: "image/jpeg", size: 10, uploadedAt: uploaded, isFavorite: favorite,
            permissions: Permissions(rawValue: permissions), mountType: mount)
    }

    @Test func keepsTheOnlyFavourite() {
        let keeper = Duplicates.keeper(of: [copy(1, "/a.jpg", uploaded: day(2020, 1, 1)), copy(2, "/b.jpg", favorite: true)])
        #expect(keeper == Duplicates.Keeper(fileId: 2, reason: .favorite))
    }

    @Test func keepsTheOwnFileOverASharedOne() {
        let keeper = Duplicates.keeper(of: [copy(1, "/Shared/a.jpg", mount: "shared", permissions: "SRG"), copy(2, "/b.jpg")])
        #expect(keeper == Duplicates.Keeper(fileId: 2, reason: .ownFile))
    }

    @Test func keepsTheOldestUpload() {
        let keeper = Duplicates.keeper(of: [
            copy(1, "/a.jpg", uploaded: day(2024, 1, 1)), copy(2, "/b.jpg", uploaded: day(2021, 1, 1)),
            copy(3, "/c.jpg", uploaded: day(2022, 1, 1)),
        ])
        #expect(keeper == Duplicates.Keeper(fileId: 2, reason: .oldest))
    }

    @Test func fallsBackToTheFirstPath() {
        let t = day(2024, 1, 1)
        let keeper = Duplicates.keeper(of: [copy(2, "/b.jpg", uploaded: t), copy(1, "/a.jpg", uploaded: t)])
        #expect(keeper == Duplicates.Keeper(fileId: 1, reason: .firstByPath))
        #expect(Duplicates.keeper(of: []) == nil)
    }

    @Test func twoFavouritesAreDecidedByAge() {
        let keeper = Duplicates.keeper(of: [
            copy(1, "/a.jpg", uploaded: day(2019, 1, 1)), copy(2, "/b.jpg", uploaded: day(2023, 1, 1), favorite: true),
            copy(3, "/c.jpg", uploaded: day(2022, 1, 1), favorite: true),
        ])
        #expect(keeper == Duplicates.Keeper(fileId: 3, reason: .oldest))
    }
}
