// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import PhotosDomain
import Testing

@testable import PhotosAppUI

/// Album cards, hero headers, parallax and the card transitions (SPEC §17.4).
@Suite struct AlbumsMotionTests {
    // MARK: Card transitions

    @Test func cardsZoomOnPhoneAndPadUnlessMotionIsReduced() {
        #expect(CardTransition.style(reduceMotion: false, platform: .phoneOrPad) == .zoom)
        #expect(CardTransition.style(reduceMotion: true, platform: .phoneOrPad) == .crossFade)
    }

    @Test func visionProCrossFadesAndTheMacFades() {
        #expect(CardTransition.style(reduceMotion: false, platform: .vision) == .crossFade)
        #expect(CardTransition.style(reduceMotion: true, platform: .vision) == .crossFade)
        #expect(CardTransition.style(reduceMotion: false, platform: .mac) == .fade)
        #expect(CardTransition.style(reduceMotion: true, platform: .mac) == .fade)
    }

    @Test func onlyAlbumRoutesZoomOutOfACard() {
        #expect(AppRoute.album(id: "own:Trip").opensFromCard)
        #expect(!AppRoute.destination("places").opensFromCard)
        #expect(!AppRoute.place(name: "Rome").opensFromCard)
        #expect(!AppRoute.photo(fileId: 1).opensFromCard)
    }

    // MARK: Parallax

    @Test func parallaxIsZeroInTheMiddleAndMovesAgainstTheScrolling() {
        let middle = ScrollParallax.offset(itemMid: 400, itemLength: 200, viewportMid: 400, viewportLength: 800)
        #expect(middle == 0)
        // Below the middle (about to come in from the bottom): the picture is moved up, against the scrolling.
        let below = ScrollParallax.offset(itemMid: 700, itemLength: 200, viewportMid: 400, viewportLength: 800)
        #expect(below < 0)
        let above = ScrollParallax.offset(itemMid: 100, itemLength: 200, viewportMid: 400, viewportLength: 800)
        #expect(above > 0)
        #expect(abs(above + below) < 0.0001)
    }

    @Test func parallaxNeverMovesThePictureFurtherThanItsOverscan() {
        for mid in stride(from: -2000.0, through: 3000, by: 50) {
            let offset = ScrollParallax.offset(itemMid: CGFloat(mid), itemLength: 160, viewportMid: 400, viewportLength: 800)
            // The picture is enlarged by twice the amount: half of that on each side.
            #expect(abs(offset) <= ScrollParallax.amount * 160 + 0.0001)
        }
        #expect(ScrollParallax.offset(itemMid: 10, itemLength: 0, viewportMid: 0, viewportLength: 0) == 0)
    }

    // MARK: Gradients of albums without a cover

    @Test func theGradientFollowsFromTheNameAlone() {
        let first = AlbumGradient.spec(for: "Garden party", dark: false)
        let again = AlbumGradient.spec(for: "Garden party", dark: false)
        #expect(first == again)
        #expect(AlbumGradient.spec(for: "Prompt: Numbers", dark: false) != first)
    }

    @Test func theHashDoesNotChangeBetweenLaunches() {
        // FNV-1a test vectors.
        #expect(AlbumGradient.stableHash("") == 0xcbf2_9ce4_8422_2325)
        #expect(AlbumGradient.stableHash("a") == 0xaf63_dc4c_8601_ec8c)
    }

    @Test func theGradientStaysInNextcloudsBlues() {
        for name in ["", "A", "Lisbon 2025", "Garden party 89421", "日本 2024", "🎉"] {
            for dark in [false, true] {
                let spec = AlbumGradient.spec(for: name, dark: dark)
                #expect(spec.tones.count == 9)
                #expect(spec.points.count == 9)
                for tone in spec.tones {
                    #expect(AlbumGradient.hueRange.contains(tone.hue))
                    #expect((0...1).contains(tone.saturation))
                    // Dark mode: deeper; light mode: bright.
                    #expect(dark ? tone.brightness < 0.65 : tone.brightness > 0.7)
                }
            }
        }
    }

    @Test func theMeshKeepsItsCornersAndEdges() {
        let points = AlbumGradient.spec(for: "Rome 2021", dark: false).points
        for row in 0..<3 {
            for column in 0..<3 {
                let point = points[row * 3 + column]
                if column != 1 { #expect(point.x == Float(column) / 2) }
                if row != 1 { #expect(point.y == Float(row) / 2) }
                #expect((0...1).contains(point.x))
                #expect((0...1).contains(point.y))
            }
        }
    }

    // MARK: Hero headers

    @Test func heroHeightFollowsTheScreen() {
        // iPhone 17 in portrait: about a third of the screen.
        #expect(HeroHeaderLayout.visibleHeight(width: 402, viewportHeight: 750) == 249)
        // In landscape: the height limits it.
        #expect(HeroHeaderLayout.visibleHeight(width: 874, viewportHeight: 380) == 160)
        // iPad: at most 380 points.
        #expect(HeroHeaderLayout.visibleHeight(width: 1024, viewportHeight: 1300) == 380)
        #expect(HeroHeaderLayout.visibleHeight(width: 0, viewportHeight: 800) == 0)
    }

    @Test func atRestTheHeroReachesFromTheTopOfTheScreenToTheFirstRow() {
        // Safe area 116 (status and navigation bar), 249 below the bar: the grid rests at offset -365.
        let frame = HeroHeaderLayout.frame(offsetY: -365, safeTop: 116, visibleHeight: 249, width: 402)
        #expect(frame == CGRect(x: 0, y: -365, width: 402, height: 365))
        // Scrolled up: the hero moves with the photos, unchanged.
        #expect(HeroHeaderLayout.frame(offsetY: -100, safeTop: 116, visibleHeight: 249, width: 402) == frame)
    }

    @Test func pulledDownTheHeroStretches() {
        let frame = HeroHeaderLayout.frame(offsetY: -465, safeTop: 116, visibleHeight: 249, width: 402)
        #expect(frame.minY == -465)
        #expect(frame.maxY == 0)
        #expect(frame.height == 465)
    }

    @Test func theTitleGoesToTheBarWhenTheHeroHasScrolledUnderIt() {
        #expect(!HeroHeaderLayout.isCollapsed(offsetY: -365, safeTop: 116))
        // 70 points of the hero still below the bar: open.
        #expect(!HeroHeaderLayout.isCollapsed(offsetY: -186, safeTop: 116))
        // 50 points: the title is under the bar.
        #expect(HeroHeaderLayout.isCollapsed(offsetY: -166, safeTop: 116))
        #expect(HeroHeaderLayout.isCollapsed(offsetY: 500, safeTop: 116))
    }
}
