// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import PhotosDomain
import Testing

@testable import PhotosAppUI

/// The viewer as a stage (SPEC §17.1): its colour, the photo above the info card, closing it into its tile,.
@Suite struct ViewerStageTests {
    let page = CGSize(width: 400, height: 800)

    @Test func stageIsBlackInDarkModeAndWhileTheControlsAreHidden() {
        #expect(ViewerStage.isDark(darkAppearance: true, controlsHidden: false))
        #expect(ViewerStage.isDark(darkAppearance: true, controlsHidden: true))
        #expect(ViewerStage.isDark(darkAppearance: false, controlsHidden: true))
        #expect(!ViewerStage.isDark(darkAppearance: false, controlsHidden: false))
    }

    @Test func plainIsTheDefaultBackdrop() {
        #expect(ViewerBackdropStyle.standard == .black)
        // The stored value of the old "Black" stays valid.
        #expect(ViewerBackdropStyle(rawValue: "black") == .black)
        #expect(ViewerBackdropStyle(rawValue: "tinted") == .tinted)
    }

    @Test func photoColorIsDeepOnADarkStageAndPaleOnALightOne() {
        let colors: [PaletteColor] = [
            PaletteColor(red: 0.9, green: 0.2, blue: 0.1), PaletteColor(red: 0.1, green: 0.3, blue: 0.9),
            PaletteColor(red: 0.5, green: 0.5, blue: 0.5), PaletteColor(red: 1, green: 1, blue: 0.2),
        ]
        for color in colors {
            #expect(ViewerBackdropTone.tone(color, dark: true).contrast(with: .white) >= 7)
            let light = ViewerBackdropTone.tone(color, dark: false)
            #expect(light.contrast(with: .black) >= 7)
            #expect(light.relativeLuminance > 0.8)
        }
    }

    @Test func pillSaysTheDayAndTheTimeWithThePlace() throws {
        let zone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let date = Date(timeIntervalSince1970: 1_795_354_560)  // 22 Nov 2026, 14:36 in Berlin
        let english = Locale(identifier: "en_GB")
        let lines = ViewerStage.pillLines(date: date, place: "Lisbon", timeZone: zone, locale: english)
        #expect(lines.title == "22 November 2026")
        #expect(lines.detail == "14:36 · Lisbon")
        #expect(ViewerStage.pillLines(date: date, place: "  ", timeZone: zone, locale: english).detail == "14:36")
        #expect(ViewerStage.pillLines(date: date, place: nil, timeZone: zone, locale: english).detail == "14:36")
    }

    @Test func photoMovesUpAboveTheInfoCard() {
        // A landscape photo (400 × 300 on the page) fits between 100 and 400: moved up, not shrunk.
        let landscape = ViewerStage.infoPlacement(content: CGSize(width: 4000, height: 3000), page: page, top: 100, bottom: 400)
        #expect(landscape.scale == 1)
        #expect(landscape.offsetY == -150)
        // A portrait photo (400 × 800) has 300 points: it shrinks to them, centred in the room.
        let portrait = ViewerStage.infoPlacement(content: CGSize(width: 3000, height: 6000), page: page, top: 100, bottom: 400)
        #expect(abs(portrait.scale - 300.0 / 800.0) < 0.0001)
        #expect(portrait.offsetY == -150)
        // No room, or no page: left alone.
        let noRoom = ViewerStage.infoPlacement(content: CGSize(width: 4, height: 3), page: page, top: 300, bottom: 300)
        #expect(noRoom.scale == 1 && noRoom.offsetY == 0)
        let noPage = ViewerStage.infoPlacement(content: CGSize(width: 4, height: 3), page: .zero, top: 0, bottom: 300)
        #expect(noPage.scale == 1 && noPage.offsetY == 0)
    }

    /// Round 11: with the info card open on a portrait photo the pager measured itself 817.46 and 818.05 points tall in
    /// turn, each placement causing the other measurement; the main thread never became idle. The placement follows whole
    /// points only, so the chase ends.
    @Test func thePlacementIgnoresTheFractionsItCausesItself() {
        var used = CGSize(width: 402, height: 822.76)
        func measure(_ heights: [Double]) -> Int {
            var changes = 0
            for height in heights where ViewerStage.isNewPlacementSize(CGSize(width: 402, height: height), old: used) {
                used = CGSize(width: 402, height: height)
                changes += 1
            }
            return changes
        }
        // The swing as measured: each step of more than a point is followed…
        #expect(
            measure([813.33, 822.18, 813.92, 821.59, 814.51, 821.0, 815.1, 820.41, 815.69, 819.82, 816.28, 819.23, 816.87, 818.64]) == 14)
        // …and the endless alternation that remained changes the placement once at most, then never again.
        #expect(measure(Array(repeating: [817.46, 818.05], count: 50).flatMap { $0 }) <= 1)
        #expect(!ViewerStage.isNewPlacementSize(CGSize(width: 402, height: 818.05), old: CGSize(width: 402, height: 817.46)))
        // A rotation is followed.
        #expect(ViewerStage.isNewPlacementSize(CGSize(width: 874, height: 402), old: CGSize(width: 402, height: 874)))
    }

    @Test func dragShrinksThePhotoAndFollowsTheFinger() {
        let photo = ViewerDismissal.photoRect(content: CGSize(width: 4000, height: 3000), page: page)
        #expect(photo == CGRect(x: 0, y: 250, width: 400, height: 300))
        let start = ViewerDismissal.dragPose(translation: .zero, page: page, photo: photo)
        #expect(start.scale == 1)
        #expect(start.progress == 0)
        let half = ViewerDismissal.dragPose(translation: CGSize(width: 30, height: 240), page: page, photo: photo)
        #expect(half.offset == CGSize(width: 30, height: 240))
        #expect(half.progress == 0.5)
        #expect(abs(half.scale - (1 - (1 - ViewerDismissal.smallestDragScale) * 0.5)) < 0.0001)
        #expect(half.clip == photo)
        let far = ViewerDismissal.dragPose(translation: CGSize(width: 0, height: 5000), page: page, photo: photo)
        #expect(far.scale == ViewerDismissal.smallestDragScale)
    }

    /// Applies a pose the way the view does: clip, scale around the page's centre, move.
    func landed(_ rect: CGRect, pose: ViewerDismissPose, origin: CGPoint) -> CGRect {
        let center = CGPoint(x: page.width / 2, y: page.height / 2)
        let x = origin.x + center.x + pose.scale * (rect.minX - center.x) + pose.offset.width
        let y = origin.y + center.y + pose.scale * (rect.minY - center.y) + pose.offset.height
        return CGRect(x: x, y: y, width: rect.width * pose.scale, height: rect.height * pose.scale)
    }

    @Test func photoLandsExactlyOnItsTile() throws {
        let photo = ViewerDismissal.photoRect(content: CGSize(width: 4000, height: 3000), page: page)
        let tile = CGRect(x: 101, y: 520, width: 99, height: 99)
        for origin in [CGPoint.zero, CGPoint(x: 20, y: 40)] {
            let pose = ViewerDismissal.landingPose(tile: tile, pageOrigin: origin, page: page, photo: photo)
            let clip = try #require(pose.clip)
            let shown = landed(clip, pose: pose, origin: origin)
            #expect(abs(shown.minX - tile.minX) < 0.001)
            #expect(abs(shown.minY - tile.minY) < 0.001)
            #expect(abs(shown.width - tile.width) < 0.001)
            #expect(abs(shown.height - tile.height) < 0.001)
            // The photo fills the tile: the clip lies inside the photo, as the tile crops it.
            #expect(photo.insetBy(dx: -0.001, dy: -0.001).contains(clip))
            #expect(pose.progress == 1)
        }
    }

    @Test func springStartsAtTheFingersSpeed() {
        let to = CGSize(width: 0, height: -400)
        // Moving back up at 800 pt/s with 400 pt to go: 2 distances per second.
        #expect(ViewerDismissal.springVelocity(CGVector(dx: 0, dy: -800), from: .zero, to: to) == 2)
        // Moving the other way does not push the spring.
        #expect(ViewerDismissal.springVelocity(CGVector(dx: 0, dy: 800), from: .zero, to: to) == 0)
        // Capped, and nothing for no distance.
        #expect(ViewerDismissal.springVelocity(CGVector(dx: 0, dy: -100_000), from: .zero, to: to) == 8)
        #expect(ViewerDismissal.springVelocity(CGVector(dx: 0, dy: 500), from: .zero, to: .zero) == 0)
    }

    @Test func onlyATileMostlyOnScreenIsALandingPlace() {
        let screen = CGRect(x: 0, y: 0, width: 400, height: 800)
        #expect(ViewerDismissal.isLandable(tile: CGRect(x: 10, y: 10, width: 100, height: 100), screen: screen))
        #expect(ViewerDismissal.isLandable(tile: CGRect(x: 10, y: 740, width: 100, height: 100), screen: screen))
        #expect(!ViewerDismissal.isLandable(tile: CGRect(x: 10, y: 770, width: 100, height: 100), screen: screen))
        #expect(!ViewerDismissal.isLandable(tile: CGRect(x: 10, y: 900, width: 100, height: 100), screen: screen))
        #expect(!ViewerDismissal.isLandable(tile: nil, screen: screen))
        #expect(!ViewerDismissal.isLandable(tile: CGRect(x: 10, y: 10, width: 2, height: 2), screen: screen))
    }
}
