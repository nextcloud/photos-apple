// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import Testing

@testable import PhotosAppUI

/// The app icon's glyph drawn inside the app (login, welcome) is the one of `icon/app.svg`: its arcs, written with
/// comma-separated flags, are read, and sun and hills sit where the SVG draws them in the 24×24 grid.
@Suite struct PhotosIconPathTests {
    let bounds = SVGPath.parse(PhotosIconPath.data).boundingRect

    @Test func glyphFillsTheSVGsArea() {
        // app.svg: the hills from x 2.6 to 21.1 and down to y 19.5, the sun's top at y 3.8 (centre 17.2 / 6.4, radius 2.6).
        #expect(abs(bounds.minX - 2.6) < 0.2)
        #expect(abs(bounds.maxX - 21.1) < 0.2)
        #expect(abs(bounds.minY - 3.8) < 0.1)
        #expect(abs(bounds.maxY - 19.5) < 0.1)
    }

    @Test func sunIsAWholeCircle() {
        let sun = SVGPath.parse("M14.6,6.4A2.6,2.6 0 1,0 19.8,6.4A2.6,2.6 0 1,0 14.6,6.4Z").boundingRect
        #expect(abs(sun.width - 5.2) < 0.05)
        #expect(abs(sun.height - 5.2) < 0.05)
        #expect(sun.contains(CGPoint(x: 17.2, y: 6.4)))
    }
}
