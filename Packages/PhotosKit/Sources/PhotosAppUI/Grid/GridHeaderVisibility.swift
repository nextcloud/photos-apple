// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Observation
import SwiftUI

/// Whether the view above a grid's first section (the Library's memories, SPEC §17.2) is on screen. The UIKit grid hosts
/// that view inside its collection view and takes it out of the window while it is scrolled away; the memory stories
/// stop playing then. Advancing to the next story animates the strip's scroll position, and doing that outside the
/// window trapped in SwiftUI (`ResolvedScrollBehavior.updateTarget`) while the Library was scrolled far down.
@MainActor @Observable
final class GridHeaderVisibility {
    var isVisible = true
}
