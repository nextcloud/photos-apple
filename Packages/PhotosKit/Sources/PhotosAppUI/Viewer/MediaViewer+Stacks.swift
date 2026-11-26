// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosStore
import SwiftUI

extension MediaViewer {
    // MARK: Stacks

    /// The copies of the stack shown, the tile's first; nil for a photo that is in no stack (or has one copy left).
    var currentStack: [FileID]? {
        guard let current, stacks[current] != nil else { return nil }
        let copies: [FileID] = ViewerStacks.copies(of: current, stacks: stacks, removed: removed)
        return copies.count > 1 ? copies : nil
    }

    /// Shows another copy of the stack on its page.
    func choose(copy: FileID) {
        guard let current else { return }
        chosenCopies[current] = copy
        zoomScale = ViewerZoom.minimumScale
    }

    /// Above a stacked photo: a strip of its copies (RAW, HEIC, JPEG…); the one shown is marked, another one is shown
    /// with a tap or click. On iPhone and iPad it sits below the floating controls.
    @ViewBuilder var stackStrip: some View {
        if let copies = currentStack, let shown = currentFileId, !chromeHidden {
            StackStrip(copies: copies, shown: shown) { copy in choose(copy: copy) }
                #if os(iOS)
                    .padding(.top, 62)
                #else
                    .padding(.top, 10)
                #endif
        }
    }

    /// "Copy 2 of 3 · IMG_1234.DNG".
    static func copyPosition(index: Int, count: Int, name: String) -> String {
        String(localized: "Copy \(index + 1) of \(count) · \(name)", bundle: .module)
    }

    /// What the favourite button does: title case on the Mac, sentence case elsewhere.
    static func favoriteTitle(remove: Bool) -> String {
        remove
            ? PlatformWording.title(
                mac: LocalizedStringResource("Remove from Favorites", bundle: .module),
                other: LocalizedStringResource("Remove from favorites", bundle: .module))
            : PlatformWording.title(
                mac: LocalizedStringResource("Add to Favorites", bundle: .module),
                other: LocalizedStringResource("Add to favorites", bundle: .module))
    }

    var viewerPlacement: ToolbarItemPlacement {
        #if os(visionOS)
            // A glass ornament under the window, beside the photo rather than over it (SPEC §17.7).
            .bottomOrnament
        #else
            .primaryAction
        #endif
    }
}
