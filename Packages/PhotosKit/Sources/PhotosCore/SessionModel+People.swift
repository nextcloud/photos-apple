// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// After a sync: the camera data for the camera chip in search (SPEC §22.3).
extension SessionModel {
    func afterSyncPeople() async {
        guard services != nil, !isStopped else { return }
        // The one reader of camera data (Insights, search chips, rules): a page of 500 photos per request, newest first.
        ExifIndexing.shared.start(session: self)
    }
}
