// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore

/// The one app model of the process.
///
/// It is created when the process starts (the app delegate asks for it in `didFinishLaunching`), not when a window appears:
/// a launch in the background — for a background task, a silent push, the "Back up now" intent or finished background
/// uploads — never shows a window, and would otherwise find no model to work with.
@MainActor enum AppHost {
    static let model = AppModel()
}
