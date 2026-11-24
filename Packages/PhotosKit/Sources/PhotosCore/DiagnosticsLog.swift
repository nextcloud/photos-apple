// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The part of the diagnostics log that survives restarts (SPEC §4.5): the app's own log entries, redacted before they are
/// written, in a few small files in the app's container (`diagnostics.log`, then `diagnostics.1.log` …). When the current file
/// is full it becomes `.1`, `.1` becomes `.2`, and the oldest is dropped, so the log never takes more than
/// `maxBytes × (rotations + 1)`. Nothing leaves the device unless the user exports diagnostics.
public struct PersistentLog: Sendable {
    public let directory: URL
    public let maxBytes: Int
    public let rotations: Int

    public init(directory: URL, maxBytes: Int = 256 * 1024, rotations: Int = 2) {
        self.directory = directory
        self.maxBytes = maxBytes
        self.rotations = rotations
    }

    /// The app's log, in the shared container.
    public static var standard: PersistentLog { PersistentLog(directory: AppPaths.logs) }

    /// Whether the log is kept (Settings › Diagnostics). On unless the user turned it off.
    public static let enabledKey = "diagnosticsLogEnabled"

    /// Never while the organisation turned logging off (managed `disable_log`, SPEC §5.1.9).
    public static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        guard !ManagedConfiguration.current(defaults).disablesLog else { return false }
        return defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    var current: URL { directory.appending(path: "diagnostics.log") }

    func rotated(_ index: Int) -> URL { directory.appending(path: "diagnostics.\(index).log") }

    /// The files, oldest first.
    var files: [URL] { (1...max(rotations, 1)).reversed().map(rotated) + [current] }

    /// Appends lines; rotates first when they would not fit into the current file.
    public func append(_ lines: [String]) throws {
        guard !lines.isEmpty else { return }
        // A single line never exceeds the limit (an entry is at most a few kilobytes; cut to be safe).
        let text = lines.map { String($0.prefix(maxBytes / 4)) }.joined(separator: "\n") + "\n"
        let data = Data(text.utf8)
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let size = (try? current.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > 0, size + data.count > maxBytes { rotate() }
        if manager.fileExists(atPath: current.path(percentEncoded: false)) {
            let handle = try FileHandle(forWritingTo: current)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: current, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    private func rotate() {
        let manager = FileManager.default
        try? manager.removeItem(at: rotated(rotations))
        if rotations > 1 {
            for index in stride(from: rotations - 1, through: 1, by: -1) {
                try? manager.moveItem(at: rotated(index), to: rotated(index + 1))
            }
        }
        if rotations > 0 {
            try? manager.moveItem(at: current, to: rotated(1))
        } else {
            try? manager.removeItem(at: current)
        }
    }

    /// Every line that is kept, oldest first.
    public func lines() -> [String] {
        files.flatMap { file -> [Substring] in
            guard let data = try? Data(contentsOf: file) else { return [] }
            return String(decoding: data, as: UTF8.self).split(separator: "\n")
        }.map(String.init)
    }

    public func removeAll() {
        for file in files { try? FileManager.default.removeItem(at: file) }
    }
}

/// Copies the app's log entries into the `PersistentLog`: when the app goes to the background, every few minutes while it
/// runs, and before an export. The system keeps an app's own entries only for its running process, so without this the log
/// of a run that crashed or was ended would be gone.
public actor DiagnosticsLogWriter {
    public static let shared = DiagnosticsLogWriter(log: .standard)

    /// Marks the lines of this run of the app, so an export lists earlier runs apart from the current one.
    public nonisolated let run: String
    let log: PersistentLog
    private var writtenUntil: Date = .distantPast

    init(log: PersistentLog, run: String = String(UUID().uuidString.prefix(8)).lowercased()) {
        self.log = log
        self.run = run
    }

    /// One line of the file: run, time, level, category and the redacted message.
    static func line(_ entry: Diagnostics.Entry, run: String, secrets: [String]) -> String {
        let time = entry.date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        let message = Diagnostics.redact(entry.message, secrets: secrets).replacingOccurrences(of: "\n", with: " ")
        return "\(run) \(time) \(entry.level) [\(entry.category)] \(message)"
    }

    /// Writes the entries that are not in the file yet.
    /// - Parameters:
    ///   - secrets: the accounts' strings, taken out of every line before it is written (`Diagnostics.redact`).
    ///   - entries: what to write, for tests; else the process's own entries from the system log.
    public func flush(secrets: [String], enabled: Bool = PersistentLog.isEnabled(), entries: [Diagnostics.Entry]? = nil) {
        guard enabled else { return }
        let all = entries ?? ((try? Diagnostics.entries(since: writtenUntil)) ?? [])
        let new = all.filter { $0.date > writtenUntil }
        guard let last = new.last else { return }
        writtenUntil = last.date
        try? log.append(new.map { Self.line($0, run: run, secrets: secrets) })
    }

    /// The kept lines of earlier runs of the app (this run's entries are read from the system log at export).
    public func earlierRuns() -> [String] {
        log.lines().filter { !$0.hasPrefix(run + " ") }
    }

    public func removeAll() {
        log.removeAll()
    }
}
