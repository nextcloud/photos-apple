// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel
import PhotosNetworking
import PhotosStore
import Synchronization
import Testing

@testable import PhotosAppUI

/// Live Text (SPEC VW-4), the stack strip (VW-6), "Show in library" (VW-3) and sharing several photos (SH-7).
@Suite struct ViewerFeaturesUITests {
    @Test func liveTextOnlyAnalysesThePhotoShownWhileTheAppIsOpen() {
        #expect(LiveTextPolicy.analyzes(isCurrent: true, hasImage: true, sceneIsActive: true, requiresUnlock: false))
        #expect(!LiveTextPolicy.analyzes(isCurrent: false, hasImage: true, sceneIsActive: true, requiresUnlock: false), "a page paged away")
        #expect(!LiveTextPolicy.analyzes(isCurrent: true, hasImage: false, sceneIsActive: true, requiresUnlock: false), "a placeholder")
        #expect(!LiveTextPolicy.analyzes(isCurrent: true, hasImage: true, sceneIsActive: false, requiresUnlock: false), "privacy cover")
        #expect(!LiveTextPolicy.analyzes(isCurrent: true, hasImage: true, sceneIsActive: true, requiresUnlock: true), "app lock")
    }

    @Test func theLiveTextButtonStaysInTheVisiblePartOfThePhoto() {
        let photo = CGRect(x: 0, y: 0, width: 400, height: 800)
        let whole = LiveTextPolicy.buttonInsets(photo: photo, visible: CGRect(x: -10, y: -10, width: 420, height: 820))
        #expect(whole.top == 0 && whole.left == 0 && whole.bottom == 0 && whole.right == 0)
        // Under the bars of an iPhone: 50 pt at the top, 90 at the bottom.
        let barred = LiveTextPolicy.buttonInsets(photo: photo, visible: CGRect(x: 0, y: 50, width: 400, height: 660))
        #expect(barred.top == 50 && barred.bottom == 90 && barred.left == 0 && barred.right == 0)
        let apart = LiveTextPolicy.buttonInsets(photo: photo, visible: CGRect(x: 500, y: 0, width: 100, height: 100))
        #expect(apart.top == 0 && apart.bottom == 0, "not on screen: nothing to keep inside")
    }

    @MainActor @Test func theStripNamesTheFormatOfEachCopy() {
        #expect(StackStrip.format(of: "IMG_7.dng") == "DNG")
        #expect(StackStrip.format(of: "IMG_7.HEIC") == "HEIC")
        #expect(StackStrip.format(of: "README") == "README")
        #expect(MediaViewer.copyPosition(index: 1, count: 3, name: "IMG_7.JPG").contains("IMG_7.JPG"))
    }

    @Test func showInLibraryIsOfferedForPhotosTheLibraryShows() {
        #expect(ShowInTimelineAction.isOffered(for: MediaItem(fileId: 1, path: "/Photos/a.jpg", mimeType: "image/jpeg")))
        #expect(!ShowInTimelineAction.isOffered(for: MediaItem(fileId: 2, path: "/Photos/a.jpg", mimeType: "image/jpeg", isArchived: true)))
        #expect(
            !ShowInTimelineAction.isOffered(
                for: MediaItem(fileId: 3, path: "/Photos/a.mov", mimeType: "video/quicktime", isLivePhotoVideo: true)))
    }

    @MainActor @Test func showInLibraryFindsTheTileInTheGrid() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var stacked = GridMedia(MediaItem(fileId: 4, path: "/Photos/IMG_4.JPG", mimeType: "image/jpeg", modifiedAt: date))
        stacked.stack = [4, 40]
        let items: [GridMedia] = [
            GridMedia(MediaItem(fileId: 5, path: "/Photos/IMG_5.JPG", mimeType: "image/jpeg", modifiedAt: date.addingTimeInterval(60))),
            stacked,
        ]
        let center = TimelineRevealCenter()
        center.request(MediaItem(fileId: 40, path: "/Photos/IMG_4.DNG", mimeType: "image/x-adobe-dng", modifiedAt: date))
        let request = try #require(center.pending)
        #expect(TimelineRevealCenter.target(of: request, in: items) == .tile(4))
        center.request(MediaItem(fileId: 40, path: "/Photos/IMG_4.DNG", mimeType: "image/x-adobe-dng", modifiedAt: date))
        #expect(center.pending != request, "asking again is a new request")
    }
}

/// Sharing several photos at once: one share per photo and recipient (SPEC SH-7).
@Suite struct ShareBatchTests {
    let anna = ShareRecipient(kind: .user, shareWith: "anna", label: "Anna")
    let team = ShareRecipient(kind: .group, shareWith: "team", label: "Team")

    @Test func everyPhotoIsSharedWithEveryRecipient() {
        let jobs = ShareBatch.jobs(paths: ["/a.jpg", "/b.jpg"], recipients: [anna, team])
        #expect(jobs.count == 4)
        #expect(Set(jobs.map { "\($0.recipient.shareWith):\($0.path)" }) == ["anna:/a.jpg", "anna:/b.jpg", "team:/a.jpg", "team:/b.jpg"])
    }

    @Test func emailIsNotOfferedForSeveralPhotos() {
        var caps = SharingCapabilities()
        caps.email = true
        caps.talk = true
        #expect(!ShareBatch.recipientKinds(caps).contains(.email))
        #expect(ShareBatch.recipientKinds(caps).contains(.talkRoom))
        #expect(ShareBatch.recipientKinds(caps).contains(.user))
    }

    struct Refused: LocalizedError {
        var errorDescription: String? { "Path is already shared with this user" }
    }

    @MainActor @Test func failuresAreListedInOrderAndTheRestIsShared() async {
        let paths: [String] = (1...9).map { "/Photos/\($0).jpg" }
        let jobs = ShareBatch.jobs(paths: paths, recipients: [anna])
        let running = Mutex((now: 0, most: 0))
        var reported: [Int] = []
        let outcome = await ShareBatch.run(
            jobs, parallel: 3,
            create: { job in
                running.withLock {
                    $0.now += 1
                    $0.most = max($0.most, $0.now)
                }
                // Later jobs answer first now and then.
                try? await Task.sleep(for: .milliseconds(job.path.hasSuffix("2.jpg") ? 30 : 5))
                running.withLock { $0.now -= 1 }
                if job.path.hasSuffix("2.jpg") || job.path.hasSuffix("7.jpg") { throw Refused() }
            },
            progress: { reported.append($0) })
        #expect(outcome.total == 9)
        #expect(outcome.shared == 7)
        #expect(outcome.failures.map(\.path) == ["/Photos/2.jpg", "/Photos/7.jpg"])
        #expect(outcome.failures.first?.text == "2.jpg · Anna: Path is already shared with this user")
        #expect(!outcome.isComplete)
        #expect(reported == Array(1...9))
        #expect(running.withLock { $0.most } <= 3, "at most three requests at a time")
    }

    @MainActor @Test func nothingToShareIsComplete() async {
        let outcome = await ShareBatch.run([], create: { _ in })
        #expect(outcome.isComplete)
        #expect(outcome.total == 0)
    }
}
