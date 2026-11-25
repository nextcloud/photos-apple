// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel
import Testing
import UniformTypeIdentifiers

@testable import PhotosAppUI

/// Image ▸ Rotate, Edit ▸ Copy and the grid's submenus (SPEC §6.2).
@Suite struct PhotoCommandsTests {
    func item(_ id: FileID, _ name: String, kind: MediaKind = .image, permissions: String = "RGDNVW") -> MediaItem {
        MediaItem(
            fileId: id, path: "/Photos/\(name)", mimeType: kind == .image ? "image/jpeg" : "video/quicktime", kind: kind,
            permissions: Permissions(rawValue: permissions))
    }

    /// Read-only shares are left alone; so are formats that can't be written back.
    @Test func onlyWritablePhotosAreRotated() {
        #expect(PhotoEditSaving.overwriteProblem(item(1, "a.jpg")) == nil)
        #expect(PhotoEditSaving.overwriteProblem(item(2, "a.jpg", permissions: "RGS")) == .readOnly)
        #expect(PhotoEditSaving.overwriteProblem(item(3, "a.dng")) == .unsupportedFormat)
        #expect(PhotoEditSaving.overwriteProblem(item(4, "a.mov", kind: .video)) == .unsupportedFormat)
        #expect(PhotoRotation.canRotate([item(2, "a.jpg", permissions: "RGS"), item(1, "b.heic")]))
        // A turn is an edit (SPEC §16.3): photos shared read-only and RAW files can be turned too; videos not.
        #expect(PhotoRotation.canRotate([item(2, "a.jpg", permissions: "RGS"), item(4, "a.mov", kind: .video)]))
        #expect(PhotoRotation.canRotate([item(3, "a.dng")]))
        #expect(!PhotoRotation.canRotate([item(4, "a.mov", kind: .video)]))
        #expect(PhotoRotation.photos([item(1, "a.jpg"), item(4, "a.mov", kind: .video)]).map(\.fileId) == [1])
        #expect(PhotoRotation.edits(clockwise: true).rotation == 1)
        #expect(PhotoRotation.edits(clockwise: false).rotation == 3)
    }

    @Test func rotateResultSaysWhatWasLeftAlone() {
        let readOnly = PhotoEditSaving.Failure.readOnly.localizedDescription
        let result = PhotoTaskResult(kind: .rotate, run: MediaSaveResult(total: 3, saved: 1, failures: [readOnly, readOnly]))
        #expect(result.confirmation?.contains("1") == true)
        #expect(result.failureMessage?.contains(readOnly) == true)
        let done = PhotoTaskResult(kind: .copy, run: MediaSaveResult(total: 2, saved: 2))
        #expect(done.failureMessage == nil && done.confirmation != nil)
        #expect(PhotoTaskResult(kind: .copy, run: MediaSaveResult(total: 2, saved: 0, wasCancelled: true)).confirmation == nil)
    }

    @Test func copyTypesComeFromTheName() {
        #expect(PhotoClipboard.type(of: item(1, "a.HEIC")) == .heic)
        #expect(PhotoClipboard.type(of: item(1, "a.png")) == .png)
        #expect(PhotoClipboard.type(of: item(1, "noext")) == .jpeg)
    }

    @Test @MainActor func submenusBecomeSingleAccessibilityActions() {
        let child = GridMenuAction(id: "album.a", title: "Holidays", systemImage: "", handler: { _ in })
        let parent = GridMenuAction(id: "album", title: "Add to Album", systemImage: "", handler: { _ in }, children: [child])
        let share = GridMenuAction(id: "share", title: "Share…", systemImage: "", handler: { _ in }, share: { [] })
        let plain = GridMenuAction(id: "open", title: "Open", systemImage: "", handler: { _ in })
        let flat = GridMenuAction.flattened([plain, parent, share])
        #expect(flat.map(\.title) == ["Open", "Add to Album: Holidays"])
    }
}
