// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosDomain
import Testing

@testable import PhotosAppUI

/// White captions on memory and story cards stay legible on any photo (SPEC §20.3): the even shade behind them
/// (`CaptionScrim`) gives WCAG AA (4.5:1, the date line is small text) even on a white photo, in black and in the deep
/// tone of the cover's colour that memory cards use.
@Suite struct CaptionScrimTests {
    /// The shade over a photo, as the screen blends it (in sRGB, by opacity).
    func blended(_ photo: PaletteColor, under shade: PaletteColor, opacity: Double) -> PaletteColor {
        photo.mixed(with: shade, amount: opacity)
    }

    /// The brightest photos: white, and bright colours of every hue.
    var brightPhotos: [PaletteColor] {
        [.white]
            + (0..<24).flatMap { step in
                let hue = Double(step) / 24
                return [0.6, 0.9].map { lightness in PaletteColor(hue: hue, saturation: 1, lightness: lightness) }
            }
    }

    /// Deep tones of covers of every hue and saturation (`PhotoTintRole.scrim`, `MemoryScrimColor`), and black.
    var shades: [PaletteColor] {
        [.black]
            + (0..<36).flatMap { step in
                [0.0, 0.3, 0.7, 1.0].map { saturation in
                    PhotoTintRole.scrim.tone(PaletteColor(hue: Double(step) / 36, saturation: saturation, lightness: 0.5))
                }
            }
    }

    @Test func whiteCaptionsKeepAAOnAnyPhoto() {
        let opacity = OverlayLegibility.scrimOpacity(base: OverlayLegibility.captionScrimOpacity, increased: false)
        var lowest = Double.infinity
        for photo in brightPhotos {
            for shade in shades {
                lowest = min(lowest, PaletteColor.white.contrast(with: blended(photo, under: shade, opacity: opacity)))
            }
        }
        // AA (4.5:1) with room to spare.
        #expect(lowest >= 5, "lowest contrast \(lowest)")
    }

    @Test func increasedContrastIsStronger() {
        let opacity = OverlayLegibility.scrimOpacity(base: OverlayLegibility.captionScrimOpacity, increased: true)
        #expect(opacity > OverlayLegibility.captionScrimOpacity)
        // Increase Contrast and Reduce Transparency use black (`MemoryScrimColor`): 7:1 (AAA) on a white photo.
        #expect(PaletteColor.white.contrast(with: blended(.white, under: .black, opacity: opacity)) >= 7)
    }

    @Test func theOldGradientWasNotEnough() {
        // Before: a gradient from clear to 0.6 under the whole caption; at the title's line, about halfway, 0.3.
        #expect(PaletteColor.white.contrast(with: blended(.white, under: .black, opacity: 0.3)) < 3)
    }

    @Test func fadeIsEasedFromNothingToTheFullShade() {
        let fade = OverlayLegibility.captionFade()
        #expect(fade.first?.location == 0 && fade.first?.amount == 0)
        #expect(fade.last?.location == 1 && fade.last?.amount == 1)
        // Rising throughout, and flat at both ends: no edge where it meets the photo or the even shade.
        for (a, b) in zip(fade, fade.dropFirst()) { #expect(b.amount > a.amount) }
        #expect(fade[1].amount < 0.1 && fade[fade.count - 2].amount > 0.9)
    }
}
