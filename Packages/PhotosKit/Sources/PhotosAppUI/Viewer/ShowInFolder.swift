// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosModel
import SwiftUI

/// "Show in folder" (SPEC VW-3): opens the app's folder browser at a photo's folder, in the window it was chosen in.
/// `MainView` provides it; the viewer and the grid's context menu offer it when it is there.
struct ShowInFolderAction {
    let open: @MainActor (_ directory: String) -> Void

    @MainActor func callAsFunction(_ item: MediaItem) { open(item.directory) }

    /// Title case on the Mac, sentence case elsewhere.
    static var title: String {
        PlatformWording.title(
            mac: LocalizedStringResource("Show in Folder", bundle: .module),
            other: LocalizedStringResource("Show in folder", bundle: .module))
    }

    static let systemImage = "folder"
}

extension EnvironmentValues {
    @Entry var showInFolder: ShowInFolderAction? = nil
}
