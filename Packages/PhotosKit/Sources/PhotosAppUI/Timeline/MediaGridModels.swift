// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosStore
import SwiftUI

/// The iPhone and iPad selection bar (SPEC §17.3).
enum SelectionBarLayout {
    /// Menu actions that are buttons of the bar and so are not repeated in its More menu.
    static let ownButtons: Set<String> = ["delete", "favorite", "album"]
}

/// The selection of a grid as its toolbar and menus need it.
struct GridSelectionInfo {
    var ids: Set<FileID> = []
    /// The items, for selections up to `MediaGridScreen.eagerSelectionLimit`; `nil` for larger ones.
    var items: [MediaItem]? = []
    var summary = SelectionSummary()
    /// The originals for the share sheet (loaded selections only).
    var shareItems: [ShareableMedia] = []
}

/// A delete that waits for its confirmation.
struct DeleteConfirmation {
    var items: [MediaItem]
    /// Items among them that are stacked behind the selected tiles (copies, burst frames), not tiles of their own.
    var stacked = 0
}

/// The action button of a grid's empty state.
struct GridEmptyAction {
    var title: String
    var handler: @MainActor () -> Void
}

struct ViewerStart: Identifiable, Hashable {
    var id: FileID { startId }
    var ids: [FileID]
    var startId: FileID
    /// Copies of one shot behind a tile (`TimelineStacking`), by the tile's id: the viewer can open them.
    var stacks: [FileID: [FileID]] = [:]
    /// Opened from the Library: the viewer does not offer "Show in library".
    var fromLibrary = false
}
