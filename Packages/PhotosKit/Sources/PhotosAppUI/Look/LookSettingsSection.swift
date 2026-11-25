// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import SwiftUI

/// Settings ▸ Appearance (SPEC §16.8): colour from photos and moving covers.
struct LookSettingsSection: View {
    @AppStorage(LookSettings.backdropKey) private var backdrop: ViewerBackdropStyle = .standard
    @AppStorage(LookSettings.headerTintKey) private var headerTint = true
    @AppStorage(LookSettings.liveCoversKey) private var liveCovers = true

    var body: some View {
        Section {
            Picker(
                String(localized: "Viewer Background", bundle: .module, comment: "Setting: what is behind a photo in the viewer."),
                selection: $backdrop
            ) {
                ForEach(ViewerBackdropStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            Toggle(
                String(
                    localized: "Tint Headers with Photo Colors", bundle: .module,
                    comment: "Setting: album and memory headers take the cover's colour."),
                isOn: $headerTint)
            Toggle(
                String(
                    localized: "Play Live Photo Covers", bundle: .module,
                    comment: "Setting: Live Photo album covers move once when they appear."),
                isOn: $liveCovers)
        } header: {
            Text("Appearance", bundle: .module, comment: "Settings section: colours from photos and moving covers.")
        } footer: {
            Text(
                "Colors come from each photo on this device. With Increase Contrast they are not used; Live Photo covers stay still with Reduce Motion or Low Power Mode.",
                bundle: .module, comment: "Footer of the Appearance settings.")
        }
    }
}
