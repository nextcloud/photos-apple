// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import SwiftUI

// Haptics of SPEC §15.5 beyond the standard ones of `photosHaptic`: they follow the system's settings (Settings › Sounds &
// Haptics › System Haptics on iPhone; the trackpad's force click feedback on the Mac, see `LibraryZoomHaptics`).

extension View {
    /// A light tap when the selection mode starts (iPhone, iPad); nothing when it ends, nothing on Mac and Vision Pro.
    @ViewBuilder func selectionStartHaptic(_ isSelecting: Bool) -> some View {
        #if os(iOS)
            sensoryFeedback(trigger: isSelecting) { old, new in
                !old && new ? .impact(weight: .light) : nil
            }
        #else
            self
        #endif
    }
}
