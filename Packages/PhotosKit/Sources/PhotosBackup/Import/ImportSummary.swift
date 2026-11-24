// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// What an import brought home, for the "Welcome home" summary and the report file (SPEC §15.7).
public struct ImportSummary: Sendable, Equatable {
    public struct SourceCount: Sendable, Equatable, Identifiable {
        public var source: ImportSourceKind
        public var count: Int
        public var id: ImportSourceKind { source }
    }

    /// On the server now: uploaded, or found there already.
    public var home = 0
    public var photos = 0
    public var videos = 0
    public var uploaded = 0
    public var alreadyThere = 0
    /// Albums that hold at least one of the photos.
    public var albums = 0
    public var years: ClosedRange<Int>?
    public var sources: [SourceCount] = []
    public var favorites = 0
    public var captions = 0
    /// Photos whose capture time, position or caption the import wrote into the file.
    public var metadataAdded = 0
    public var archived = 0
    /// Copies within an export and the same photo in two exports, imported once.
    public var copiesInExports = 0
    public var skipped: [ImportSkipReason: Int] = [:]
    public var skippedExamples: [ImportSkipReason: [String]] = [:]
    public var failed = 0
    public var failures: [String] = []
    /// Items the import has not reached (it was stopped).
    public var notYetDone = 0
    public var destination = ""

    public init() {}

    /// Reasons that mean a photo of the export did not arrive (the others are left out on purpose).
    static let lossReasons: Set<ImportSkipReason> = [.missingFile, .listedWithoutFile, .unreadableIndex, .unsupportedType]

    /// Every photo and video of the exports is on the server, apart from what was left out on purpose (deleted ones,
    /// photos in conversations).
    public var nothingLost: Bool {
        failed == 0 && notYetDone == 0 && Self.lossReasons.allSatisfy { (skipped[$0] ?? 0) == 0 }
    }

    public var skippedOnPurpose: Int { skipped.filter { !Self.lossReasons.contains($0.key) }.values.reduce(0, +) }
    public var notImported: Int { failed + notYetDone + skipped.filter { Self.lossReasons.contains($0.key) }.values.reduce(0, +) }

    public static func make(plan: ImportPlan, journal: ImportJournal, progress: ImportProgress, options: ImportOptions) -> ImportSummary {
        var summary = ImportSummary()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var years: [Int] = []
        var bySource: [ImportSourceKind: Int] = [:]
        var albumTitles = Set<String>()
        for item in plan.items {
            guard let entry = journal.entries[item.id] else {
                summary.notYetDone += 1
                continue
            }
            switch entry.state {
            case .failed:
                summary.failed += 1
                if summary.failures.count < 200 { summary.failures.append("\(item.name): \(entry.error ?? "")") }
                continue
            case .uploaded: summary.uploaded += 1
            case .duplicate: summary.alreadyThere += 1
            }
            summary.home += 1
            if item.kind == .video { summary.videos += 1 } else { summary.photos += 1 }
            bySource[item.source, default: 0] += 1
            if let date = item.takenAt { years.append(calendar.component(.year, from: date)) }
            if entry.favorited { summary.favorites += 1 }
            if entry.commented { summary.captions += 1 }
            if entry.metadataAdded { summary.metadataAdded += 1 }
            if item.metadata.hidden && options.hiddenToArchive && entry.state == .uploaded { summary.archived += 1 }
            if !entry.albums.isEmpty { albumTitles.formUnion(entry.albums) }
        }
        summary.albums = albumTitles.count
        if let first = years.min(), let last = years.max() { summary.years = first...last }
        summary.sources = bySource.map { SourceCount(source: $0.key, count: $0.value) }.sorted { $0.count > $1.count }
        summary.copiesInExports = plan.duplicatesInExport + plan.duplicatesAcrossSources
        summary.skipped = plan.skipped
        summary.skippedExamples = plan.skippedExamples
        summary.destination = options.destination
        return summary
    }

    // MARK: Text

    public static func title(of source: ImportSourceKind) -> String {
        switch source {
        case .googlePhotos: String(localized: "Google Photos", bundle: .module, comment: "An import source: the Google service.")
        case .iCloudPhotos: String(localized: "iCloud Photos", bundle: .module, comment: "An import source: Apple's service.")
        case .facebook: String(localized: "Facebook", bundle: .module, comment: "An import source.")
        case .instagram: String(localized: "Instagram", bundle: .module, comment: "An import source.")
        case .photosLibrary:
            String(localized: "Photos Library", bundle: .module, comment: "An import source: the Photos app's library on this Mac.")
        case .files: String(localized: "Other files", bundle: .module, comment: "An import source: photos not from a known service.")
        }
    }

    public static func explanation(of reason: ImportSkipReason) -> String {
        switch reason {
        case .deleted:
            String(
                localized: "In the trash or recently deleted in the service", bundle: .module,
                comment: "Why photos were not imported (list in the import summary).")
        case .messages:
            String(
                localized: "Sent or received in conversations", bundle: .module,
                comment: "Why photos were not imported: they are photos from Facebook or Instagram messages.")
        case .missingFile:
            String(
                localized: "Listed in the export, but in none of the chosen files: choose all parts of the export", bundle: .module,
                comment: "Why photos were not imported: a ZIP part of the export was not chosen.")
        case .unsupportedType:
            String(
                localized: "A file type Nextcloud Photos cannot show", bundle: .module,
                comment: "Why files were not imported (list in the import summary).")
        case .unreadableIndex:
            String(
                localized: "Part of the export's description could not be read", bundle: .module,
                comment: "Why photos were not imported: an index or JSON file of the export is damaged.")
        case .listedWithoutFile:
            String(
                localized: "Listed by Apple without the photo itself (with Advanced Data Protection, Apple's export leaves photos out)",
                bundle: .module, comment: "Why photos were not imported from an iCloud data export.")
        }
    }

    /// "48 213 photos and videos · 312 albums · from 2004 to 2026"
    public var headline: String {
        var parts = [
            String(
                localized: "\(home) photos and videos", bundle: .module,
                comment: "Import summary: how many photos and videos are now on the server.")
        ]
        if albums > 0 {
            parts.append(String(localized: "\(albums) albums", bundle: .module, comment: "Import summary: number of albums."))
        }
        if let years {
            parts.append(
                years.lowerBound == years.upperBound
                    ? String(
                        localized: "from \(String(years.lowerBound))", bundle: .module, comment: "Import summary: the year of the photos.")
                    : String(
                        localized: "from \(String(years.lowerBound)) to \(String(years.upperBound))", bundle: .module,
                        comment: "Import summary: the years of the oldest and newest photo."))
        }
        return parts.joined(separator: " · ")
    }

    /// The report file: what was imported, from where, what was left out and why.
    public func reportText(date: Date = Date()) -> String {
        var lines: [String] = []
        lines.append(String(localized: "Nextcloud Photos import report", bundle: .module, comment: "Title of the import report file."))
        lines.append(date.formatted(date: .long, time: .shortened))
        lines.append("")
        lines.append(headline)
        lines.append(
            nothingLost
                ? String(localized: "Nothing lost.", bundle: .module, comment: "Import report: every photo arrived.")
                : String(
                    localized: "\(notImported) items were not imported (see below).", bundle: .module,
                    comment: "Import report: some photos did not arrive."))
        lines.append("")
        lines.append(String(localized: "Uploaded: \(uploaded)", bundle: .module, comment: "Import report line."))
        lines.append(
            String(
                localized: "Already on your Nextcloud: \(alreadyThere)", bundle: .module, comment: "Import report line: not uploaded twice."
            ))
        if copiesInExports > 0 {
            lines.append(
                String(
                    localized: "Copies in the exports, imported once: \(copiesInExports)", bundle: .module,
                    comment: "Import report line: the same photo in several album folders or exports."))
        }
        if favorites > 0 { lines.append(String(localized: "Favourites: \(favorites)", bundle: .module, comment: "Import report line.")) }
        if captions > 0 {
            lines.append(String(localized: "Captions kept as comments: \(captions)", bundle: .module, comment: "Import report line."))
        }
        if metadataAdded > 0 {
            lines.append(
                String(
                    localized: "Photos given back their date, place or caption: \(metadataAdded)", bundle: .module,
                    comment: "Import report line: the import wrote the capture date, location or caption into these files."))
        }
        if archived > 0 {
            lines.append(
                String(localized: "Hidden photos put into the archive: \(archived)", bundle: .module, comment: "Import report line."))
        }
        lines.append(String(localized: "Destination: \(destination)", bundle: .module, comment: "Import report line: the server folder."))
        if !sources.isEmpty {
            lines.append("")
            lines.append(String(localized: "Sources", bundle: .module, comment: "Import report: heading of the list of sources."))
            for source in sources { lines.append("- \(Self.title(of: source.source)): \(source.count)") }
        }
        let reasons = skipped.keys.sorted()
        if !reasons.isEmpty {
            lines.append("")
            lines.append(String(localized: "Left out", bundle: .module, comment: "Import report: heading of the skipped items."))
            for reason in reasons {
                lines.append("- \(Self.explanation(of: reason)): \(skipped[reason] ?? 0)")
                for example in skippedExamples[reason] ?? [] { lines.append("    \(example)") }
            }
        }
        if failed > 0 || notYetDone > 0 {
            lines.append("")
            lines.append(String(localized: "Not imported", bundle: .module, comment: "Import report: heading of the failed items."))
            if notYetDone > 0 {
                lines.append(
                    String(
                        localized: "- Not reached yet (the import was stopped; resume it to continue): \(notYetDone)", bundle: .module,
                        comment: "Import report line."))
            }
            for failure in failures { lines.append("- \(failure)") }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
