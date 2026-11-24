// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// What the app says where the organisation's device management decides (SPEC §5.1.9).
enum ManagedWording {
    static var serverManaged: String {
        String(
            localized: "Your organization manages the server address.", bundle: .module,
            comment: "Under the server address field of the login when device management sets it.")
    }

    static var appLockRequired: String {
        String(
            localized: "Your organization requires the app lock.", bundle: .module,
            comment: "Settings › Privacy footer when device management enforces the app lock.")
    }

    static var logDisabled: String {
        String(
            localized: "Your organization turned off the log of this app.", bundle: .module,
            comment: "Settings › Diagnostics when device management turned off logging.")
    }

    static var backupDisabledTitle: String {
        String(localized: "Backup is turned off", bundle: .module, comment: "Backup screen title when device management turned backup off.")
    }

    static var backupDisabled: String {
        String(
            localized: "Your organization doesn't allow automatic backup in this app.", bundle: .module,
            comment: "Backup screen when device management turned backup off.")
    }
}
