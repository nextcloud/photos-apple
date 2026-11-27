// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import SwiftUI

/// Settings › Advanced: whether this app's settings follow the user to their other Macs, iPhones and iPads through
/// `/.nextcloud-photos/settings.json` (SPEC §22.5.2). A setting of each app; on by default.
struct SyncedSettingsSection: View {
    @Environment(SessionModel.self) private var session
    @AppStorage(SyncedDefaults.enabledKey) private var isOn = true

    var body: some View {
        Section {
            Toggle(
                PlatformWording.title(
                    mac: LocalizedStringResource(
                        "Sync Settings Through Nextcloud", bundle: .module,
                        comment: "Setting (Mac, title case): this app's settings follow the user to their other Macs, iPhones and iPads."),
                    other: LocalizedStringResource(
                        "Sync settings through Nextcloud", bundle: .module,
                        comment: "Setting: this app's settings follow the user to their other Macs, iPhones and iPads.")),
                isOn: $isOn
            )
            .onChange(of: isOn) { _, on in
                // Turned on again: what is set here is sent, and what changed elsewhere comes over.
                if on { Task { await session.syncNow() } }
            }
        } header: {
            Text(
                "Everywhere", bundle: .module,
                comment: "Settings section header: the app's settings follow the user to their other Macs, iPhones and iPads.")
        } footer: {
            Text(
                "Display, appearance, slideshow, film, culling, editing and naming options follow you to Nextcloud Photos on your Mac, iPhone and iPad. Storage, backup, notifications and security stay on each one.",
                bundle: .module, comment: "Footer of Sync settings through Nextcloud: what follows the user and what does not.")
        }
    }
}
