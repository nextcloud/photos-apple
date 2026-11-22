// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreImage
import Foundation
import Testing

@testable import PhotosMedia

@Suite struct EditingTests {
    let image = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 300))

    @Test func identityKeepsSize() {
        #expect(PhotoEditor.apply(PhotoEdits(), to: image).extent.size == CGSize(width: 400, height: 300))
    }

    @Test func rotationSwapsDimensions() {
        var edits = PhotoEdits()
        edits.rotation = 1
        let out = PhotoEditor.apply(edits, to: image).extent
        #expect(Int(out.width.rounded()) == 300 && Int(out.height.rounded()) == 400)
        #expect(out.origin == .zero)
    }

    @Test func squareCrop() {
        var edits = PhotoEdits()
        edits.aspect = .square
        let out = PhotoEditor.apply(edits, to: image).extent
        #expect(Int(out.width) == 300 && Int(out.height) == 300)
    }

    @Test func blurHashDecodes() {
        let decoded = BlurHash.decode("LdH:5yIWWXt7X=M{a#j]I^tSoKWC", width: 8, height: 8)
        #expect(decoded?.width == 8)
        #expect(BlurHash.decode("short") == nil)
    }
}
