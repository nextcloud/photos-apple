// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import OSLog
import Testing

@testable import PhotosCore

/// The diagnostics report: nothing that identifies the account, its server or its files gets into it.
@Suite struct DiagnosticsTests {
    static let secrets = ["alice", "Alice Example", "cloud.example.com", "alice@cloud.example.com", "al"]

    @Test func addressesPathsFileNamesAndTokensAreRemoved() {
        let cases: [(String, String)] = [
            ("GET https://cloud.example.com/remote.php/dav/files/alice/Photos/IMG_1.jpg failed", "GET <url> failed"),
            ("upload of IMG_0042.HEIC failed", "upload of <file> failed"),
            ("could not read /Photos/2026/Summer trip", "could not read <path> trip"),
            ("Authorization: Basic YWxpY2U6c2VjcmV0", "Authorization: Basic <token>"),
            ("app password aB3dE5gH7jK9mN1pQ3sT5vW7yZ9bC1dE3 rejected", "app password <token> rejected"),
            ("account alice@cloud.example.com signed out", "account <account> signed out"),
            ("sync failed for Alice Example on CLOUD.example.com", "sync failed for <account> on <account>"),
            ("mail bob@example.org", "mail <address>"),
            ("nc://login/server:https://x.test&user:bob&password:secret", "<url>"),
        ]
        for (line, expected) in cases { #expect(Diagnostics.redact(line, secrets: Self.secrets) == expected) }
    }

    @Test func ordinaryLogLinesStayReadable() {
        let lines = [
            "sync: idle → syncing", "reconciled: 504 items, 0 removed, 2 refreshed", "outbox: 3 failed operations",
            "server features changed (-): +albumCover,albumDescription -", "change: archive × 3",
            "The server returned an error (500).", "backup: uploading 12 of 340",
        ]
        for line in lines { #expect(Diagnostics.redact(line, secrets: Self.secrets) == line) }
        // A two-letter user name is only removed as a whole word.
        #expect(Diagnostics.redact("al signed in; all albums loaded", secrets: Self.secrets) == "<account> signed in; all albums loaded")
    }

    @Test func theReportCarriesVersionsAndFeaturesButNoAccount() {
        let context = Diagnostics.Context(
            appVersion: "1.2", system: "macOS 27.3", serverVersion: "36.0.1", photosVersion: "8.0.0",
            features: ["trashbin", "albumCover"],
            state: ["Sync: failed", "Sync error: The certificate of cloud.example.com is not trusted."],
            secrets: Self.secrets)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let entries = [
            Diagnostics.Entry(
                date: now.addingTimeInterval(-60), level: "error", category: "sync",
                message: "sync failed: 404 at https://cloud.example.com/a"),
            Diagnostics.Entry(date: now, level: "info", category: "session", message: "upload of\n/Photos/alice/IMG_1.jpg done"),
        ]
        let report = Diagnostics.report(context: context, entries: entries, hours: 48, now: now)
        #expect(report.contains("App: 1.2"))
        #expect(report.contains("System: macOS 27.3"))
        #expect(report.contains("Nextcloud: 36.0.1"))
        #expect(report.contains("Photos app: 8.0.0"))
        #expect(report.contains("Features: albumCover, trashbin"))
        #expect(report.contains("Sync error: The certificate of <account> is not trusted."))
        #expect(report.contains("error [sync] sync failed: 404 at <url>"))
        #expect(report.contains("info [session] upload of <path> done"))
        for secret in ["alice", "cloud.example.com", "IMG_1", "Alice"] { #expect(!report.contains(secret), "\(secret)") }
        #expect(report.hasSuffix("\n"))
    }

    /// The app's own entries can be read back from the log store, and only those.
    @Test func entriesOfThisProcessAreCollected() throws {
        let marker = "diagnostics-test-\(UUID().uuidString.prefix(8))"
        // As the export asks: two days back, long before this process started.
        let started = Date().addingTimeInterval(-48 * 3600)
        Logger(subsystem: Diagnostics.subsystem, category: "test").notice("marker \(marker, privacy: .public)")
        Logger(subsystem: Diagnostics.subsystem, category: "test").info("info \(marker, privacy: .public)")
        Logger(subsystem: "com.example.other", category: "test").notice("other \(marker, privacy: .public)")
        let entries = try Diagnostics.entries(since: started)
        #expect(entries.contains { $0.message == "marker \(marker)" && $0.category == "test" && $0.level == "notice" })
        #expect(entries.contains { $0.message == "info \(marker)" && $0.level == "info" })
        #expect(!entries.contains { $0.message.hasPrefix("other") })
        #expect(try Diagnostics.entries(since: Date().addingTimeInterval(60)).isEmpty)
    }
}
