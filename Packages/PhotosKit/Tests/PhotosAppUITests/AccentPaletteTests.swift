// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosAppUI

/// The accent colour is legible as text (SPEC §20.3): WCAG AA (4.5:1) in every appearance, AAA (7:1) with Increase
/// Contrast in light mode.
@Suite struct AccentPaletteTests {
    /// The light backgrounds the accent is drawn on: plain, grouped lists, and the tint of a bordered button.
    let lightBackgrounds = [LivingRGB.white, LivingRGB(242 / 255, 242 / 255, 247 / 255)]

    @Test func lightAccentIsLegibleOnLightBackgrounds() {
        for background in lightBackgrounds {
            #expect(AccentPalette.rgb(dark: false, increasedContrast: false).contrast(with: background) >= 4.5)
            #expect(AccentPalette.rgb(dark: false, increasedContrast: true).contrast(with: background) >= 7)
        }
        // The tinted fill of a bordered button: the accent at about 15 % on white.
        let accent = AccentPalette.rgb(dark: false, increasedContrast: false)
        let tint = LivingRGB(1 - 0.15 * (1 - accent.red), 1 - 0.15 * (1 - accent.green), 1 - 0.15 * (1 - accent.blue))
        #expect(accent.contrast(with: tint) >= 4.5)
        // White on the accent (prominent buttons, the selected state).
        #expect(accent.contrast(with: .white) >= 4.5)
    }

    @Test func darkAccentIsLegibleOnBlack() {
        #expect(AccentPalette.rgb(dark: true, increasedContrast: false).contrast(with: .black) >= 4.5)
        #expect(AccentPalette.rgb(dark: true, increasedContrast: true).contrast(with: .black) >= 4.5)
    }

    @Test func theOldNextcloudBlueWasNotEnoughOnWhite() {
        // #0082c9: why the light accent changed.
        #expect(LivingRGB(0, 130 / 255, 201 / 255).contrast(with: .white) < 4.5)
    }
}
