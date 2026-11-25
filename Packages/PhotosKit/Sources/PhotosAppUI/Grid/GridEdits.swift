// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosCore
import PhotosModel

/// Tells a grid which photos' edits changed (SPEC §16.3: saved here, undone, or synced from another device), so it
/// draws their tiles again with the new rendition.
@MainActor
final class GridEditObserver {
    var changed: (Set<FileID>) -> Void = { _ in }
    private var token: (any NSObjectProtocol)?

    init() {
        token = NotificationCenter.default.addObserver(forName: .photosEditsChanged, object: nil, queue: .main) { [weak self] note in
            let ids = note.userInfo?["fileIds"] as? Set<FileID> ?? []
            MainActor.assumeIsolated { self?.changed(ids) }
        }
    }

    isolated deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}
