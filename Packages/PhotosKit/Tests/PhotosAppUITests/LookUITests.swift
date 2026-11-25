// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import PhotosDomain
import Testing

@testable import PhotosAppUI

/// The viewer's backdrop, header washes and moving covers (SPEC §16.8).
@Suite struct LookUITests {
    @Test func pagerPositionIsTrustedNearTheCurrentPage() {
        #expect(ViewerTint.position(scroll: 2.4, current: 2, count: 10) == 2.4)
        #expect(ViewerTint.position(scroll: 1.6, current: 2, count: 10) == 1.6)
        // Right to left: the scroll view reports the position mirrored.
        #expect(ViewerTint.position(scroll: 7.25, current: 2, count: 10) == 1.75)
        // Neither (a layout in progress): the current page.
        #expect(ViewerTint.position(scroll: 5, current: 2, count: 10) == 2)
        #expect(ViewerTint.position(scroll: .nan, current: 3, count: 10) == 3)
        #expect(ViewerTint.pagePosition(offset: 750, width: 300) == 2.5)
        #expect(ViewerTint.pagePosition(offset: 750, width: 0) == 0)
    }

    @MainActor @Test func blendIsBetweenTheTwoPagesTheFingerIsBetween() throws {
        let tint = ViewerTint()
        tint.pages = [10, 11, 12]
        tint.current = 11
        tint.scrollPosition = 1.25
        let blend = try #require(tint.blend)
        #expect(blend.from == 11 && blend.to == 12 && blend.amount == 0.25)
        tint.scrollPosition = 2
        let last = try #require(tint.blend)
        #expect(last.from == 12 && last.to == 12)
        tint.current = 99
        #expect(tint.blend == nil)
    }

    @Test func headerWashesStayReadable() {
        for hue in stride(from: 0.0, to: 1.0, by: 1.0 / 36) {
            for lightness in [0.1, 0.5, 0.9] {
                let color = PaletteColor(hue: hue, saturation: 0.8, lightness: lightness)
                #expect(HeaderWash.color(color, dark: true).contrast(with: .white) >= 7)
                #expect(HeaderWash.color(color, dark: false).contrast(with: .black) >= 7)
            }
        }
    }

    @Test func coversMoveOnlyWhenEverythingAllowsIt() {
        #expect(LiveCoverPolicy.plays(setting: true, reduceMotion: false, lowPower: false, autoplay: true))
        #expect(!LiveCoverPolicy.plays(setting: false, reduceMotion: false, lowPower: false, autoplay: true))
        #expect(!LiveCoverPolicy.plays(setting: true, reduceMotion: true, lowPower: false, autoplay: true))
        #expect(!LiveCoverPolicy.plays(setting: true, reduceMotion: false, lowPower: true, autoplay: true))
        #expect(!LiveCoverPolicy.plays(setting: true, reduceMotion: false, lowPower: false, autoplay: false))
    }

    @Test func increaseContrastDropsPhotoColours() {
        #expect(PhotoTintLookup.allowed(contrast: .standard))
        #expect(!PhotoTintLookup.allowed(contrast: .increased))
    }

    @Test func storedSettingValuesStayStable() {
        #expect(ViewerBackdropStyle.allCases.map(\.rawValue) == ["black", "tinted", "ambient"])
        #expect(AlbumCoverEffect.allCases.map(\.rawValue) == ["automatic", "still", "depth"])
    }
}
