// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosNetworking

/// Settings shared by the user's devices (SPEC §22.5): after every library sync, one look at `/.nextcloud-photos/`
/// sends what changed here and takes over what changed elsewhere.
extension SessionModel {
    func syncSettings() async {
        guard let services, !isStopped else { return }
        let files = services.syncedSettings
        let account = services.account.id.rawValue
        let settings = files.store(.settings)
        // Made before the sync so that it is part of it, whether or not the people feature asked for it yet.
        _ = files.store(.people)
        await family?.prepareShared()
        let defaults = SyncedDefaults.shared
        let syncsDefaults = SyncedDefaults.isEnabled()
        if syncsDefaults {
            defaults.attach(settings, account: account)
            await defaults.prepare(settings, account: account)
        }
        await files.syncAll()
        if syncsDefaults { defaults.apply(settings, account: account) }
        family?.takeOverShared()
    }
}
