// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosDomain
import PhotosModel
import Testing

@testable import PhotosAppUI

/// One Clean up screen for duplicates, similar shots, large videos, screenshots and the device (SPEC §19.3).
@MainActor @Suite struct CleanUpTests {
    /// The older places keep working: their destinations, deep links and menu commands open Clean up at their section.
    @Test func olderPlacesOpenTheirSection() {
        #expect(CleanUpSection.opened(by: .duplicates) == .duplicates)
        #expect(CleanUpSection.opened(by: .freeSpace) == .largeVideos)
        #expect(CleanUpSection.opened(by: .library) == nil)
        let categories = CleanUpSection.largeVideos.cleanupCategories + CleanUpSection.screenshots.cleanupCategories
        #expect(Set(categories) == Set(Cleanup.Category.allCases), "every category of Free up space has a section")
    }

    /// Round 12 (SPEC §22.1): free up exists on the Mac too, where the backup reads the Photos library.
    @Test func theDeviceSectionIsOnIPhoneIPadAndTheMac() {
        #if os(iOS) || os(macOS)
            #expect(CleanUpSection.available.contains(.device))
        #else
            #expect(!CleanUpSection.available.contains(.device))
        #endif
        #expect(CleanUpSection.available.first == .duplicates)
    }

    func item(_ id: FileID, size: Int64) -> MediaItem {
        MediaItem(fileId: id, path: "/Photos/\(id).mov", mimeType: "video/quicktime", size: size)
    }

    @Test func screenshotsAndRecordingsAreOneSection() {
        let model = CleanUpModel()
        model.freeSpace = [
            .screenshots: CleanUpFinding(count: 1, files: [(1, 10)], previews: [item(1, size: 10)]),
            .screenRecordings: CleanUpFinding(count: 2, files: [(2, 30), (3, 20)], previews: [item(2, size: 30)]),
            .largeVideos: CleanUpFinding(count: 1, files: [(4, 500)], previews: [item(4, size: 500)]),
        ]
        let screenshots = model.finding(.screenshots)
        #expect(screenshots?.count == 3)
        #expect(screenshots?.bytes == 60)
        #expect(screenshots?.previews.map(\.fileId) == [2, 1], "largest first")
        #expect(model.finding(.largeVideos)?.bytes == 500)
        #expect(model.finding(.device) == nil)
    }

    /// A large video that is also a duplicate copy is counted once in the headline.
    @Test func theTotalCountsEachFileOnce() {
        let model = CleanUpModel()
        model.similarEnabled = false
        #expect(model.serverTotal == nil, "nothing loaded yet")
        model.duplicates = CleanUpFinding(count: 1, files: [(4, 500), (5, 100)], previews: [])
        model.freeSpace = [.largeVideos: CleanUpFinding(count: 1, files: [(4, 500)], previews: [])]
        #expect(model.serverTotal == 600)

        model.similarEnabled = true
        #expect(model.serverTotal == nil, "similar shots still loading")
        model.similar = SimilarShotsFinding(
            finding: CleanUpFinding(count: 1, files: [(6, 50)], previews: []), indexed: 10, total: 20)
        #expect(model.serverTotal == 650)
        #expect(model.similar?.isComplete == false)
    }
}
