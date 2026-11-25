// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Testing

/// Where the tests run. Vision's models do not run in the simulator (no Neural Engine, and a CI runner has no GPU), so
/// tests that need real Vision results only run on the Mac; the macOS test job covers them.
enum TestEnvironment {
    static let isSimulator: Bool = {
        #if targetEnvironment(simulator)
            true
        #else
            false
        #endif
    }()

    static let noVision: Comment = "Vision does not run in the simulator; covered by the macOS tests."
    /// Rendering pictures and writing videos blocked the whole test run in the CI simulator, which has no GPU (a
    /// blocked call is not stopped by a time limit). Covered by the macOS tests.
    static let noGPU: Comment = "Rendering needs a GPU, which the CI simulator lacks; covered by the macOS tests."
}
