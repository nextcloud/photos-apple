// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

/// A performance budget as measured on a Mac. The macOS test job checks it as it is; the CI simulator, several times
/// slower and shared with other jobs, gets five times as long, so a busy runner does not fail a test.
func timingBudget(_ mac: Duration) -> Duration {
    #if targetEnvironment(simulator)
        mac * 5
    #else
        mac
    #endif
}
