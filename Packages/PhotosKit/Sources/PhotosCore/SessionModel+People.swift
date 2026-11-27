// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel
import PhotosStore

/// After a sync: the camera data for the camera chip in search, People on this device, birthdays (SPEC §22.3).
extension SessionModel {
    func afterSyncPeople() async {
        guard let services, !isStopped else { return }
        // The one reader of camera data (Insights, search chips, rules): a page of 500 photos per request, newest first.
        ExifIndexing.shared.start(session: self)
        let store = DeviceFaceStore(database: services.database)
        if features.has(.recognize) || !DevicePeopleIndexing.isEnabled() {
            // Recognize's people win; the device's stay hidden (and out of search).
            try? store.removeMirror()
        } else {
            // Names given on the user's other devices.
            let engine = DevicePeopleIndexing.engine(services)
            let changed = (try? await engine.applySharedNames()) ?? false
            if changed || !((try? store.hasMirror()) ?? false) { try? store.mirrorNamedPeople() }
        }
        // Birthdays from Nextcloud Contacts, once a day, and the reminders of the named people's next birthdays.
        await ContactBirthdays.refreshIfDue(self)
    }
}
