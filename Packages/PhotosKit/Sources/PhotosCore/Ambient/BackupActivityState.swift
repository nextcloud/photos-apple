// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosBackup

/// What the backup's Live Activity, its widget and its controls show (SPEC §15.4): a small, stable summary of the
/// engine's status. It is the Live Activity's content state, so it is Codable and has nothing the lock screen must not
/// show (no file names, no account or server).
public struct BackupActivityState: Codable, Hashable, Sendable {
    public enum Phase: String, Codable, Sendable {
        /// Looking for new photos and asking the server what it has.
        case preparing
        case uploading
        /// Waiting: for Wi-Fi, for Low Power Mode to end, for the user (`message` says what for).
        case paused
        /// The pass is through; `failed` items could not be uploaded.
        case done
        /// Stopped by something the user has to fix (`message`), or no access to the photos.
        case stopped
    }

    public var phase: Phase
    /// Uploaded in this pass.
    public var done: Int
    /// Everything this pass uploads (`done` included).
    public var total: Int
    /// Still to upload.
    public var remaining: Int
    /// The size of what is still to upload; 0 when unknown.
    public var remainingBytes: Int64
    public var failed: Int
    /// Why the backup waits or stopped, ready to show.
    public var message: String?

    public init(
        phase: Phase, done: Int = 0, total: Int = 0, remaining: Int = 0, remainingBytes: Int64 = 0, failed: Int = 0, message: String? = nil
    ) {
        self.phase = phase
        self.done = done
        self.total = total
        self.remaining = remaining
        self.remainingBytes = remainingBytes
        self.failed = failed
        self.message = message
    }

    /// 0…1 while uploading; nil when the phase says nothing about it.
    public var fraction: Double? {
        switch phase {
        case .uploading: total > 0 ? min(1, Double(done) / Double(total)) : 0
        case .done: 1
        case .preparing, .paused, .stopped: nil
        }
    }

    /// The pass has ended (the activity ends with this state).
    public var isFinal: Bool { phase == .done || phase == .stopped }

    /// The summary of an engine status. Nil while nothing happens (idle, never run).
    public init?(status: BackupStatus) {
        let remaining = status.pending
        let bytes = status.pendingBytes
        switch status.phase {
        case .scanning:
            self.init(phase: .preparing, remaining: remaining, remainingBytes: bytes)
        case .reconciling(_, let total):
            // `total`: what is compared with the server; most of it is uploaded next on a first or large backup.
            self.init(phase: .preparing, total: total, remaining: remaining, remainingBytes: bytes)
        case .uploading(let done, let total, _):
            self.init(
                phase: .uploading, done: done, total: total, remaining: max(total - done, 0), remainingBytes: bytes, failed: status.failed)
        case .paused(let reason):
            self.init(
                phase: .paused, done: status.uploadedThisPass, total: status.uploadedThisPass + remaining, remaining: remaining,
                remainingBytes: bytes, failed: status.failed, message: reason)
        case .upToDate:
            self.init(phase: .done, done: status.uploadedThisPass, total: status.uploadedThisPass)
        case .incomplete(let failed):
            self.init(
                phase: .done, done: status.uploadedThisPass, total: status.uploadedThisPass + remaining, remaining: remaining,
                remainingBytes: bytes, failed: failed, message: status.lastFailure)
        case .failed(let message):
            let text = status.blocker.map { BackupOutcome.blocked($0).message } ?? message
            self.init(phase: .stopped, done: status.uploadedThisPass, remaining: remaining, remainingBytes: bytes, message: text)
        case .notAuthorized:
            self.init(phase: .stopped, message: BackupOutcome.notAuthorized.message)
        case .idle where status.isInterrupted:
            // The system took the time away; the pass goes on with the next chance it gets.
            self.init(
                phase: .paused, done: status.uploadedThisPass, total: status.uploadedThisPass + remaining, remaining: remaining,
                remainingBytes: bytes, message: BackupActivityState.interruptedMessage)
        case .idle:
            return nil
        }
    }

    static var interruptedMessage: String {
        String(
            localized: "Continues when Nextcloud Photos runs again", bundle: .module,
            comment: "Backup Live Activity and widget: the system stopped the backup in the background; it goes on later.")
    }

    /// "12 photos left" — or what the backup waits for.
    public var headline: String {
        switch phase {
        case .preparing:
            String(localized: "Looking for new photos…", bundle: .module)
        case .uploading:
            String(
                localized: "\(remaining) left", bundle: .module,
                comment: "Backup Live Activity: number of photos and videos still to upload. Plural variations in the catalog.")
        case .paused:
            String(localized: "Backup paused", bundle: .module, comment: "Backup Live Activity and widget: title while it waits.")
        case .done:
            failed > 0
                ? String(
                    localized: "\(failed) not uploaded", bundle: .module,
                    comment: "Backup Live Activity: the pass ended, but this many items failed. Plural variations in the catalog.")
                : String(localized: "Backed up", bundle: .module, comment: "Backup Live Activity and widget: everything is on the server.")
        case .stopped:
            String(localized: "Backup stopped", bundle: .module, comment: "Backup Live Activity and widget: the user has to fix something.")
        }
    }

    /// The line under the headline: the size left, what it waits for, or how many were uploaded.
    public var detail: String? {
        switch phase {
        case .preparing:
            return nil
        case .uploading:
            guard remainingBytes > 0 else { return nil }
            let size = ByteCountFormatter.string(fromByteCount: remainingBytes, countStyle: .file)
            return String(
                localized: "\(size) left", bundle: .module,
                comment: "Backup Live Activity: the size of what is still to upload, e.g. “1.2 GB left”.")
        case .paused, .stopped:
            return message
        case .done:
            if failed > 0 { return message }
            guard done > 0 else { return nil }
            return String(
                localized: "\(done) uploaded", bundle: .module,
                comment: "Backup Live Activity: how many photos and videos the finished pass uploaded. Plural variations in the catalog.")
        }
    }
}

/// When the backup shows a Live Activity (SPEC §15.4).
public enum BackupActivityPolicy {
    /// Fewer photos go up faster than a Live Activity would be worth showing (unless the user asked for the backup).
    public static let minimumItems = 10
    /// … unless they are large.
    public static let minimumBytes: Int64 = 100 * 1024 * 1024

    /// A pass this large (or one the user started from a control or Siri) gets a Live Activity. It may start while the
    /// pass still compares many photos with the server: the system only lets the app start one while it is in front, and
    /// the user often leaves the app before the uploads begin.
    public static func shouldStart(_ state: BackupActivityState, userRequested: Bool) -> Bool {
        switch state.phase {
        case .uploading:
            guard state.remaining > 0 else { return false }
            return userRequested || state.remaining >= minimumItems || state.remainingBytes >= minimumBytes
        case .preparing:
            return state.total >= minimumItems || state.remaining >= minimumItems
        case .paused, .done, .stopped:
            return false
        }
    }

    /// The minimum time between two updates of the activity with the same phase; a change of phase is sent at once.
    public static let updateInterval: TimeInterval = 2

    public static func shouldUpdate(from old: BackupActivityState?, to new: BackupActivityState, last: Date?, now: Date) -> Bool {
        guard let old else { return true }
        guard old != new else { return false }
        if old.phase != new.phase || old.message != new.message { return true }
        guard let last else { return true }
        return now.timeIntervalSince(last) >= updateInterval
    }

    /// How long a finished activity stays on the Lock Screen: a done backup goes after a while, a stopped one stays (the
    /// system's limit) so the user sees what to fix.
    /// 0: at once (the pass found nothing to upload).
    public static func dismissalDelay(_ state: BackupActivityState) -> TimeInterval? {
        guard state.phase == .done, state.failed == 0 else { return nil }
        return state.done == 0 ? 0 : 15 * 60
    }

    /// An activity the app does not update for this long is shown as out of date (the app was suspended).
    public static let staleAfter: TimeInterval = 10 * 60
}

/// What the backup widget and the Control Center toggle read (written by the app into the App Group, SPEC §15.4).
public struct BackupWidgetSnapshot: Codable, Hashable, Sendable {
    /// Backup is turned on.
    public var isEnabled: Bool
    /// Backup was set up for an account (turning it on from a control needs that).
    public var isSetUp: Bool
    /// The current or last pass; nil when nothing happened since the app started.
    public var state: BackupActivityState?
    /// Items still to upload (also between passes).
    public var pending: Int
    public var lastRun: Date?
    public var written: Date

    public init(
        isEnabled: Bool, isSetUp: Bool, state: BackupActivityState?, pending: Int, lastRun: Date?, written: Date = Date()
    ) {
        self.isEnabled = isEnabled
        self.isSetUp = isSetUp
        self.state = state
        self.pending = pending
        self.lastRun = lastRun
        self.written = written
    }

    public init(settings: BackupSettings, status: BackupStatus, now: Date = Date()) {
        self.init(
            isEnabled: settings.isEnabled, isSetUp: settings.accountId != nil, state: BackupActivityState(status: status),
            pending: status.pending, lastRun: status.lastRun, written: now)
    }

    /// The same for a widget: only what it shows (not when it was written).
    public func sameContent(as other: BackupWidgetSnapshot) -> Bool {
        var mine = self
        mine.written = other.written
        return mine == other
    }

    /// Where the app writes it: in the App Group, next to the backup options.
    public static func file(_ layout: StorageLayout = AppPaths.layout) -> URL {
        layout.backupSettingsFile.deletingLastPathComponent().appending(path: "backup-status.json")
    }

    public static func load(from file: URL = BackupWidgetSnapshot.file()) -> BackupWidgetSnapshot? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(BackupWidgetSnapshot.self, from: data)
    }

    public func save(to file: URL = BackupWidgetSnapshot.file()) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: file, options: .atomic)
    }
}
