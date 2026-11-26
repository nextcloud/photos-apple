// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import GRDB
import OSLog
import Photos
import PhotosModel
import PhotosNetworking
import PhotosStore

/// Backup progress shown in the UI (SPEC §7.18.7).
public struct BackupStatus: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case idle
        case notAuthorized
        case scanning
        case reconciling(checked: Int, total: Int)
        case uploading(done: Int, total: Int, current: String)
        case paused(String)
        /// Everything this device has is on the server: nothing failed, nothing waits.
        case upToDate
        /// The pass ran to its end, but this many items could not be uploaded (`lastFailure` says why). They are tried
        /// again after their waiting time, or at once when the user asks.
        case incomplete(failed: Int)
        case failed(String)
    }

    public var phase: Phase = .idle
    /// Everything this app has uploaded so far (the ledger's count).
    public var uploaded = 0
    /// What the current or last pass uploaded.
    public var uploadedThisPass = 0
    public var matched = 0
    /// Items that still have to be uploaded (they wait for Wi-Fi, for the system, or for the next pass). Failed items
    /// are not in here; see `failed`.
    public var pending = 0
    /// Items whose upload failed and that wait for their next attempt.
    public var failed = 0
    /// Why the most recent of them failed.
    public var lastFailure: String?
    /// The size of what is still to upload (`pending`), as far as the photo library told it; 0 when unknown.
    public var pendingBytes: Int64 = 0
    /// Items left out because their original is only in iCloud and "Download originals from iCloud" is off.
    public var skipped = 0
    /// The app may only see the photos the user selected ("limited access"); everything else is not backed up.
    public var isLimitedAccess = false
    public var lastRun: Date?
    /// Set when a run stopped because of something only the user can fix (the phase is then `.failed` with the message).
    public var blocker: Blocker?
    /// The system took the time away from the last pass (a background task expired) before it was through. This is not
    /// the user's pause: the phase is `.idle` and the pass is taken up again at the next opportunity.
    public var isInterrupted = false

    /// A pass is at work.
    public var isRunning: Bool {
        switch phase {
        case .scanning, .reconciling, .uploading: true
        case .idle, .notAuthorized, .paused, .upToDate, .incomplete, .failed: false
        }
    }

    /// The phase for the log (Settings › Export diagnostics): its name and numbers only. File names, pause reasons and
    /// error messages are left out; they can contain names of the user's files, account and server.
    public var phaseLogDescription: String {
        switch phase {
        case .idle: isInterrupted ? "idle (interrupted)" : "idle"
        case .notAuthorized: "not authorized"
        case .scanning: "scanning"
        case .reconciling(_, let total): "reconciling \(total) items"
        case .uploading(_, let total, _): "uploading \(total) items"
        case .paused: "paused"
        case .upToDate: "up to date"
        case .incomplete(let failed): "incomplete, \(failed) failed"
        case .failed: blocker.map { "failed (\($0))" } ?? "failed"
        }
    }

    /// Counts for the log line at the end of a pass.
    public var countsLogDescription: String {
        "uploaded this pass \(uploadedThisPass), pending \(pending), failed \(failed), skipped \(skipped)"
            + (isLimitedAccess ? ", limited access" : "")
    }

    /// Problems that stop the whole backup, not just one file.
    public enum Blocker: Sendable, Equatable {
        /// The account's quota is used up (507).
        case insufficientStorage
        /// The login is no longer valid (401).
        case unauthorized
        /// The server refuses the upload (403), e.g. a read-only folder or a file access rule.
        case forbidden
        /// The server's certificate is not trusted, or it asks for a client certificate.
        case serverTrust
        /// This device has no room for the file that would be uploaded.
        case deviceStorageFull
    }

    public init() {}
}
