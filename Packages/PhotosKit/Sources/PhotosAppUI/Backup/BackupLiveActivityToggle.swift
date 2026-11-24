// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

#if os(iOS)
    import PhotosCore
    import SwiftUI

    /// Backup › "Show progress on Lock Screen": the backup's Live Activity (SPEC §15.4). Off here, or for the app in Settings,
    /// and no activity starts.
    struct BackupLiveActivityToggle: View {
        @State private var isOn = BackupPresence.shared.liveActivity.isEnabled
        private let allowedBySystem = BackupPresence.shared.liveActivity.isAllowedBySystem

        var body: some View {
            Toggle(isOn: $isOn) {
                Text(
                    "Show progress on Lock Screen", bundle: .module,
                    comment:
                        "Backup option (iPhone, iPad): a Live Activity shows the backup's progress on the Lock Screen and in the Dynamic Island."
                )
                if !allowedBySystem {
                    Text(
                        "Live Activities are turned off for Nextcloud Photos in Settings.", bundle: .module,
                        comment: "Below the backup option \"Show progress on Lock Screen\" when the system does not allow Live Activities.")
                }
            }
            .disabled(!allowedBySystem)
            .onChange(of: isOn) { _, value in BackupPresence.shared.liveActivity.isEnabled = value }
        }
    }
#endif
