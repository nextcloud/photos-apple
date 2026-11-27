// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// What the Library's header and the account menu say about the backup (SPEC §21.1). Honest: a photo counts as backed
/// up only when the server has it (the ledger's `uploaded` or `matched`), never because it was handed to the system or
/// is on its way.
public enum BackupSummary: Sendable, Equatable {
    /// Backup is not turned on (or not available here): nothing is said.
    case off
    /// The device's photos are being compared with the ledger for the first time.
    case checking
    /// Every photo and video backup covers is on the server.
    case allBackedUp
    /// A pass uploads; this many are not on the server yet.
    case backingUp(remaining: Int)
    /// This many photos and videos are not on the server; of them, `failed` could not be uploaded.
    case notBackedUp(Int, failed: Int)

    public init(isEnabled: Bool, isLoaded: Bool, snapshot: DeviceLayerSnapshot, isRunning: Bool) {
        guard isEnabled else {
            self = .off
            return
        }
        guard isLoaded else {
            self = .checking
            return
        }
        let remaining = snapshot.notBackedUp
        if remaining == 0 {
            self = .allBackedUp
        } else if isRunning || snapshot.uploading > 0 {
            self = .backingUp(remaining: remaining)
        } else {
            self = .notBackedUp(remaining, failed: snapshot.failed)
        }
    }

    /// Something is not on the server.
    public var hasRemaining: Bool {
        switch self {
        case .backingUp, .notBackedUp: true
        case .off, .checking, .allBackedUp: false
        }
    }
}
