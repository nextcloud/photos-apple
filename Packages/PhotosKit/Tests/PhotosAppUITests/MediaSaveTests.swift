// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import Testing

@testable import PhotosAppUI

/// Saving originals (viewer, grid, menu bar): counting, failures per item, cancelling, and what the user is told.
@Suite struct MediaSaveTests {
    struct Refused: LocalizedError {
        var errorDescription: String? { "The server said no." }
    }

    @Test func everyItemSaved() async {
        let seen = Mutex<[Int]>([])
        let steps = Mutex<[Int]>([])
        let result = await MediaSaveRunner.run([1, 2, 3], progress: { done in steps.withLock { $0.append(done) } }) { element in
            seen.withLock { $0.append(element) }
        }
        #expect(result == MediaSaveResult(total: 3, saved: 3))
        #expect(result.isSuccess)
        #expect(result.failureMessage == nil)
        #expect(seen.withLock { $0 } == [1, 2, 3])
        #expect(steps.withLock { $0 } == [1, 2, 3])
    }

    @Test func aFailingItemDoesNotStopTheOthers() async {
        let result = await MediaSaveRunner.run([1, 2, 3]) { element in
            if element == 2 { throw Refused() }
        }
        #expect(result.saved == 2)
        #expect(result.failures == ["The server said no."])
        #expect(!result.isSuccess)
        #expect(!result.wasCancelled)
        #expect(result.failureMessage == "The server said no.")
    }

    @Test func cancellingKeepsWhatWasSavedAndIsNotAFailure() async {
        let task = Task {
            await MediaSaveRunner.run([1, 2, 3, 4]) { element in
                // The download of the second item is interrupted by Cancel.
                if element == 2 {
                    withUnsafeCurrentTask { $0?.cancel() }
                    throw URLError(.cancelled)
                }
            }
        }
        let result = await task.value
        #expect(result.saved == 1)
        #expect(result.wasCancelled)
        #expect(result.failures.isEmpty)
        #expect(!result.isSuccess)
    }

    @Test func nothingToSave() async {
        let result = await MediaSaveRunner.run([Int]()) { _ in }
        #expect(result == MediaSaveResult(total: 0))
        #expect(result.confirmation == nil)
    }

    @Test func confirmationSaysHowManyItemsWereSaved() {
        #if os(macOS)
            #expect(MediaSaveResult(total: 3, saved: 3).confirmation == "Exported 3 items")
            #expect(MediaSaveResult(total: 1, saved: 1).confirmation == "Exported 1 item")
            #expect(MediaSaveResult(total: 5, saved: 2, wasCancelled: true).confirmation == "Exported 2 of 5 items")
        #else
            #expect(MediaSaveResult(total: 3, saved: 3).confirmation == "Saved 3 items to Photos")
            #expect(MediaSaveResult(total: 1, saved: 1).confirmation == "Saved 1 item to Photos")
            #expect(MediaSaveResult(total: 5, saved: 2, wasCancelled: true).confirmation == "Saved 2 of 5 items to Photos")
        #endif
        // Nothing saved: no "Saved 0 items".
        #expect(MediaSaveResult(total: 2, failures: ["a", "b"]).confirmation == nil)
        #expect(MediaSaveResult(total: 2, wasCancelled: true).confirmation == nil)
    }

    @Test func failuresAreSummedUp() {
        // One item: its reason.
        #expect(MediaSaveResult(total: 1, failures: ["You are offline."]).failureMessage == "You are offline.")
        // Several for the same reason: the count and the reason once.
        let offline = MediaSaveResult(total: 3, saved: 1, failures: ["You are offline.", "You are offline."])
        // Different reasons: the count.
        let mixed = MediaSaveResult(total: 3, saved: 1, failures: ["You are offline.", "The file is locked."])
        #if os(macOS)
            #expect(offline.failureMessage == "2 items could not be exported. You are offline.")
            #expect(mixed.failureMessage == "2 items could not be exported.")
        #else
            #expect(offline.failureMessage == "2 items could not be saved. You are offline.")
            #expect(mixed.failureMessage == "2 items could not be saved.")
        #endif
    }

    @Test func exportedFileNamesDoNotOverwrite() {
        let folder = URL(fileURLWithPath: "/tmp/export")
        let taken: Set<String> = ["IMG_1.jpg", "IMG_1 2.jpg", "notes"]
        let exists: (URL) -> Bool = { taken.contains($0.lastPathComponent) }
        #expect(MediaFileNaming.freeURL(for: "IMG_2.jpg", in: folder, exists: exists).lastPathComponent == "IMG_2.jpg")
        #expect(MediaFileNaming.freeURL(for: "IMG_1.jpg", in: folder, exists: exists).lastPathComponent == "IMG_1 3.jpg")
        #expect(MediaFileNaming.freeURL(for: "notes", in: folder, exists: exists).lastPathComponent == "notes 2")
    }
}
