// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import OSLog
import PhotosModel
import PhotosStore

/// The diagnostics report testers export from Settings (SPEC §4.5): the app's own log entries plus what is needed to
/// read them (app, system and server versions, detected features). Never account names, addresses, file names or tokens.
public enum Diagnostics {
    public static let subsystem = "com.nextcloud.photos"

    /// One log entry of the app.
    public struct Entry: Sendable, Equatable {
        public var date: Date
        public var level: String
        public var category: String
        public var message: String

        public init(date: Date, level: String, category: String, message: String) {
            self.date = date
            self.level = level
            self.category = category
            self.message = message
        }
    }

    /// What the report says about the app and the server, and what must not appear in it.
    public struct Context: Sendable, Equatable {
        public var appVersion: String
        public var system: String
        public var serverVersion: String?
        public var photosVersion: String?
        public var features: [String]
        public var state: [String]
        /// Strings of the account (host, user id, login and display name) that are taken out wherever they appear.
        public var secrets: [String]

        public init(
            appVersion: String, system: String, serverVersion: String? = nil, photosVersion: String? = nil, features: [String] = [],
            state: [String] = [], secrets: [String] = []
        ) {
            self.appVersion = appVersion
            self.system = system
            self.serverVersion = serverVersion
            self.photosVersion = photosVersion
            self.features = features
            self.state = state
            self.secrets = secrets
        }
    }

    // MARK: Redaction

    private static let mediaExtensions =
        "jpe?g|heic|heif|png|gif|webp|avif|bmp|tiff?|dng|raw|cr2|cr3|nef|arw|orf|rw2|mov|mp4|m4v|avi|mkv|webm|3gp|mpe?g|xmp|aae|pdf|json|sqlite|der|p12"

    private static func compile(_ patterns: [(String, String)]) -> [(NSRegularExpression, String)] {
        patterns.map { (try! NSRegularExpression(pattern: $0.0), $0.1) }  // literals below: a failure is a programming error
    }

    /// Applied first: whole addresses, before anything inside them is replaced.
    private static let addressPatterns = compile([
        ("(?i)\\b(bearer|basic)\\s+[A-Za-z0-9+/=._~-]+", "$1 <token>"),
        ("[A-Za-z][A-Za-z0-9+.-]*://[^\\s\"'<>]+", "<url>"),
    ])

    /// Applied after the account's own strings.
    private static let contentPatterns = compile([
        ("[^\\s\"'<>/@]+@[^\\s\"'<>/@]+\\.[^\\s\"'<>/@]+", "<address>"),
        ("(?<![A-Za-z0-9<])(?:/[^\\s\"'/]+){2,}/?", "<path>"),
        ("(?i)[^\\s\"'<>/]+\\.(?:\(mediaExtensions))\\b", "<file>"),
        ("\\b[A-Za-z0-9_-]{24,}\\b", "<token>"),
    ])

    private static func apply(_ patterns: [(NSRegularExpression, String)], to text: String) -> String {
        var result = text
        for (regex, template) in patterns {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
        }
        return result
    }

    /// Takes addresses, paths, file names, tokens and the given account strings out of a line.
    public static func redact(_ text: String, secrets: [String] = []) -> String {
        var result = apply(addressPatterns, to: text)
        // Longest first: a host that contains the user name is replaced as a whole.
        let known = Set(secrets.map { $0.trimmingCharacters(in: .whitespaces) }).filter { $0.count >= 2 }
        for secret in known.sorted(by: { ($0.count, $0) > ($1.count, $1) }) {
            let escaped = NSRegularExpression.escapedPattern(for: secret)
            // Short strings only as whole words: a user called "al" must not eat half of every line.
            let pattern = secret.count < 4 ? "(?i)(?<![A-Za-z0-9])\(escaped)(?![A-Za-z0-9])" : "(?i)\(escaped)"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "<account>")
        }
        return apply(contentPatterns, to: result)
    }

    // MARK: Report

    /// The report as text. Every line that comes from the log is redacted.
    public static func report(context: Context, entries: [Entry], hours: Int, now: Date = Date()) -> String {
        let stamp = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
        var lines: [String] = [
            "Nextcloud Photos diagnostics",
            "Created: \(now.formatted(stamp))",
            "App: \(context.appVersion)",
            "System: \(context.system)",
            "Nextcloud: \(context.serverVersion ?? "unknown")",
            "Photos app: \(context.photosVersion ?? "unknown")",
            "Features: \(context.features.isEmpty ? "none" : context.features.sorted().joined(separator: ", "))",
        ]
        lines += context.state.map { redact($0, secrets: context.secrets) }
        lines.append("")
        lines.append(
            "Log of this run of the app, last \(hours) hours (\(entries.count) entries). Account names, addresses, file names and tokens are removed."
        )
        lines.append("")
        let time = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        for entry in entries {
            let message = redact(entry.message, secrets: context.secrets).replacingOccurrences(of: "\n", with: " ")
            lines.append("\(entry.date.formatted(time)) \(entry.level) [\(entry.category)] \(message)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The app's log entries since `since`. The system only hands an app the entries of its running process.
    public static func entries(since: Date) throws -> [Entry] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let predicate = NSPredicate(format: "subsystem == %@", subsystem)
        // From the start of the process, filtered by date here: a position before the process started gives nothing.
        return try store.getEntries(matching: predicate).compactMap { entry in
            guard let log = entry as? OSLogEntryLog, log.date >= since else { return nil }
            return Entry(date: log.date, level: levelName(log.level), category: log.category, message: log.composedMessage)
        }
    }

    static func levelName(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: "debug"
        case .info: "info"
        case .notice: "notice"
        case .error: "error"
        case .fault: "fault"
        default: "log"
        }
    }

    public static var systemDescription: String {
        #if os(macOS)
            let name = "macOS"
        #elseif os(visionOS)
            let name = "visionOS"
        #else
            let name = "iOS"
        #endif
        return "\(name) \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }

    /// What the report says about this app and account.
    @MainActor public static func context(app: AppModel, session: SessionModel?) -> Context {
        var context = Context(appVersion: app.appVersion, system: systemDescription)
        // Every account's strings are kept out, not only the active one's.
        for account in app.accounts {
            context.secrets += [account.userId, account.loginName, account.displayName, account.id.rawValue]
            if let host = account.serverURL.host() { context.secrets.append(host) }
        }
        context.state.append("Accounts: \(app.accounts.count)")
        guard let session else { return context }
        context.serverVersion = session.features.serverVersion.string
        context.photosVersion = session.features.photosAppVersion
        context.features = session.features.enabled.map(\.rawValue)
        context.state.append("Sync: \(session.syncStatus.logName)")
        if case .failed(let message, _) = session.syncStatus { context.state.append("Sync error: \(message)") }
        context.state.append("Signed out: \(session.isSignedOut)")
        context.state.append("Certificate refused: \(session.certificateProblem != nil)")
        context.state.append("Failed changes: \(session.failedOperations.count)")
        if let error = session.featureDetectionError { context.state.append("Feature detection error: \(error)") }
        return context
    }

    /// Writes the report into a temporary file and returns it. Reading the log takes a moment: it runs off the main actor.
    @MainActor public static func export(app: AppModel, session: SessionModel?, hours: Int = 48) async throws -> URL {
        let context = context(app: app, session: session)
        return try await Task.detached(priority: .userInitiated) {
            let now = Date()
            let entries = try entries(since: now.addingTimeInterval(-Double(hours) * 3600))
            let text = report(context: context, entries: entries, hours: hours, now: now)
            let name = "NextcloudPhotos-diagnostics-\(now.formatted(.iso8601.year().month().day().dateSeparator(.dash))).txt"
            let directory = FileManager.default.temporaryDirectory.appending(path: "diagnostics-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appending(path: name)
            try Data(text.utf8).write(to: file, options: .atomic)
            return file
        }.value
    }
}
