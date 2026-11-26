// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosModel
import SwiftUI

extension MediaViewer {
    /// The photos on the pages next to the one shown (SPEC §18.2): their decodes stay in memory under memory pressure.
    var neighbourFileIds: [FileID] {
        guard let shown = currentFileId else { return [] }
        let pages = shownIds
        guard let index = pages.firstIndex(of: shown) ?? pages.firstIndex(where: { fileId(ofPage: $0) == shown }) else { return [] }
        return [index - 1, index + 1].filter(pages.indices.contains).map { fileId(ofPage: pages[$0]) }
    }
}
