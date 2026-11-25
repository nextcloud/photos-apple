// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosDomain
import PhotosModel

extension SessionModel {
    /// After a sync: the shared lists, then the folder rules, then a share of the camera details when a rule needs them.
    func afterSyncOrganize() async {
        guard let organize, !isStopped else { return }
        organize.invalidateRuleInputs()
        await organize.sync()
        await organize.runRules()
        // About 4 500 photos per sync, in the background, only while some rule asks about cameras.
        if organize.rulesNeedCameraDetails { organize.readCameraDetails(batches: 50) }
    }

    /// Saves a search as a smart album shared by all the user's devices (`.nextcloud-photos/smart-albums.json`). Used
    /// when the server has no smart album setting of its own (extended servers keep theirs, so the web app sees them).
    func saveSharedSmartAlbum(_ album: SmartAlbum) async -> Bool {
        guard let organize else { return false }
        await organize.save(SmartAlbumDefinition(id: album.id, name: album.name, rule: SmartRule(album.filters)))
        return true
    }
}
