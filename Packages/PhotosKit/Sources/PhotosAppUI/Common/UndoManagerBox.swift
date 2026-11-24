// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import SwiftUI

/// The window's undo manager, for actions that register an undo, kept where the view that runs them does not depend on it.
///
/// `@Environment(\.undoManager)` renders a view again whenever the manager changes. On iPad, a grid in a sidebar section of
/// `TabView(.sidebarAdaptable)` (Photos, Videos, Favorites) gets another manager every time the tab view hosts it again;
/// the grid rendered again for that, which updated its toolbar, which made the tab view host it again: an endless loop at
/// 100 % CPU, the grid never appeared. The actions only need the manager when they run, so it is kept in a box nobody
/// observes (`readsUndoManager(into:)`).
@MainActor
final class UndoManagerBox {
    weak var manager: UndoManager?
}

private struct UndoManagerReader: View {
    let box: UndoManagerBox
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        Color.clear
            .accessibilityHidden(true)
            .onChange(of: undoManager.map(ObjectIdentifier.init), initial: true) { _, _ in box.manager = undoManager }
    }
}

extension View {
    /// Keeps the window's undo manager in `box`, without rendering this view again when it changes.
    func readsUndoManager(into box: UndoManagerBox) -> some View {
        background { UndoManagerReader(box: box) }
    }
}
