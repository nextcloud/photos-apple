// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Observation
import PhotosBackup
import PhotosCore
import PhotosModel
import SwiftUI

#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif

/// The running card import of the app (SPEC §15.2). It outlives the import sheet: the sheet can be closed while the
/// files upload, and the toolbar (and the Dock on the Mac) show how far it is.
@MainActor
@Observable
final class CardImportCenter {
    static let shared = CardImportCenter()

    struct Job: Identifiable {
        let id = UUID()
        var deviceName: String
        var progress = CardImportProgress()
        /// Eject the card or camera when the import is through.
        var ejectAfter: Bool
        var ejectProblem: String?
        var ejected = false
        var startedAt = Date()
    }

    private(set) var job: Job?
    @ObservationIgnored private var task: Task<Void, Never>?
    #if os(iOS)
        @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif

    var isRunning: Bool { job?.progress.isRunning == true }

    /// The file the per-account record of imported files is kept in.
    static func ledgerURL(_ account: AccountID) -> URL {
        AppPaths.accountDirectory(account).appending(path: "card-imports.json")
    }

    func start(
        _ groups: [CardGroup], from device: any CardDevice, options: CardImportOptions, ejectAfter: Bool, session: SessionModel
    ) {
        guard !isRunning, let services = session.services, !groups.isEmpty else { return }
        let importer = CardImporter(
            api: services.api, database: services.database, source: device.source, options: options,
            ledgerURL: Self.ledgerURL(session.account.id))
        job = Job(deviceName: device.name, ejectAfter: ejectAfter)
        beginBackgroundTime()
        task = Task { [weak self] in
            let result = await importer.run(groups) { progress in
                Task { @MainActor in self?.update(progress) }
            }
            guard let self else { return }
            self.update(result)
            if result.phase == .finished, ejectAfter, device.canEject {
                do {
                    try await device.eject()
                    self.job?.ejected = true
                } catch {
                    self.job?.ejectProblem = error.localizedDescription
                }
            }
            self.task = nil
            self.endBackgroundTime()
            DockProgress.show(nil)
            DockProgress.finished()
            await session.syncNow()
        }
    }

    private func update(_ progress: CardImportProgress) {
        guard job != nil else { return }
        // A late progress update of a file must not undo the final result.
        if let current = job?.progress, !current.isRunning, progress.isRunning { return }
        job?.progress = progress
        DockProgress.show(progress.isRunning ? progress.fraction : nil)
    }

    func cancel() {
        task?.cancel()
    }

    /// Forgets a finished import (the summary was seen).
    func dismiss() {
        guard !isRunning else { return }
        job = nil
    }

    private func beginBackgroundTime() {
        #if os(iOS)
            // The upload goes on for a while when the app is left; a longer import continues when it is back.
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "card-import") { [weak self] in
                MainActor.assumeIsolated { self?.endBackgroundTime() }
            }
        #endif
    }

    private func endBackgroundTime() {
        #if os(iOS)
            if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
            backgroundTask = .invalid
        #endif
    }
}

/// The import's progress on the Dock icon (Mac): a bar under the icon while it runs, a bounce when it is through and
/// the app is in the background.
@MainActor
enum DockProgress {
    #if os(macOS)
        private static var view: DockProgressView?
    #endif

    /// 0…1, or nil to show the plain icon.
    static func show(_ fraction: Double?) {
        #if os(macOS)
            let tile = NSApp.dockTile
            guard let fraction else {
                if view != nil {
                    view = nil
                    tile.contentView = nil
                    tile.display()
                }
                return
            }
            let shown = view ?? DockProgressView(frame: NSRect(origin: .zero, size: tile.size))
            if view == nil {
                view = shown
                tile.contentView = shown
            }
            // Redrawn in steps of a percent: the Dock is drawn by another process.
            let rounded = (fraction * 100).rounded() / 100
            guard rounded != shown.fraction else { return }
            shown.fraction = rounded
            tile.display()
        #endif
    }

    static func finished() {
        #if os(macOS)
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        #endif
    }
}

#if os(macOS)
    /// The app icon with a progress bar along its lower edge.
    final class DockProgressView: NSView {
        var fraction: Double = 0

        override func draw(_ dirtyRect: NSRect) {
            NSApp.applicationIconImage?.draw(in: bounds)
            let bar = NSRect(x: bounds.width * 0.1, y: bounds.height * 0.08, width: bounds.width * 0.8, height: bounds.height * 0.1)
            let track = NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2)
            NSColor.black.withAlphaComponent(0.55).setFill()
            track.fill()
            var filled = bar.insetBy(dx: 2, dy: 2)
            filled.size.width = max(filled.height, filled.width * fraction)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: filled, xRadius: filled.height / 2, yRadius: filled.height / 2).fill()
        }
    }
#endif

/// Toolbar items of the Library for work that runs in the background: a card import and photos open in other apps
/// (SPEC §15.2).
struct PhotographerStatusItems: View {
    var body: some View {
        CardImportIndicator()
        #if os(macOS)
            ExternalEditsIndicator()
        #endif
    }
}

/// The card import in the toolbar: a ring while it runs, its summary when it is through.
struct CardImportIndicator: View {
    @State private var center = CardImportCenter.shared
    @State private var showing = false

    var body: some View {
        if let job = center.job {
            Button {
                showing = true
            } label: {
                if job.progress.isRunning {
                    Gauge(value: job.progress.fraction) { Text("") }
                        .gaugeStyle(.accessoryCircularCapacity)
                        .scaleEffect(0.5)
                        .frame(width: 28, height: 28)
                        .accessibilityLabel(CardImportWording.runningTitle(job))
                } else {
                    Image(systemName: job.progress.failed > 0 ? "exclamationmark.triangle" : "sdcard.fill")
                        .accessibilityLabel(CardImportWording.resultTitle(job.progress))
                }
            }
            .help(job.progress.isRunning ? CardImportWording.runningTitle(job) : CardImportWording.resultTitle(job.progress))
            .popover(isPresented: $showing) {
                CardImportStatusView(job: job).padding().frame(width: 320, alignment: .leading)
            }
        }
    }
}

/// How far the import is, or what it did.
struct CardImportStatusView: View {
    let job: CardImportCenter.Job
    @State private var center = CardImportCenter.shared

    var body: some View {
        let progress = job.progress
        VStack(alignment: .leading, spacing: 10) {
            Label(job.deviceName, systemImage: "sdcard").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
            if progress.isRunning {
                ProgressView(value: progress.fraction) {
                    Text(CardImportWording.runningDetail(progress)).font(.callout)
                } currentValueLabel: {
                    Text(
                        "\(ByteCountFormatter.string(fromByteCount: progress.processedBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file))",
                        bundle: .module, comment: "Card import progress: bytes done of all bytes."
                    )
                    .monospacedDigit()
                }
                Button(String(localized: "Stop Import", bundle: .module, comment: "Stops a running card import.")) { center.cancel() }
            } else {
                Text(CardImportWording.resultTitle(progress)).font(.callout)
                ForEach(CardImportWording.resultDetails(job), id: \.self) { line in
                    Text(line).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !progress.failures.isEmpty {
                    DisclosureGroup(String(localized: "Details", bundle: .module)) {
                        ScrollView {
                            Text(progress.failures.joined(separator: "\n")).font(.caption).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 140)
                    }
                }
                Button(String(localized: "Done", bundle: .module)) { center.dismiss() }
            }
        }
    }
}

enum CardImportWording {
    static func runningTitle(_ job: CardImportCenter.Job) -> String {
        String(
            localized: "Importing from \(job.deviceName)… \(Int((job.progress.fraction * 100).rounded())) %", bundle: .module,
            comment: "Toolbar help while a card import runs: device name and percent.")
    }

    static func runningDetail(_ progress: CardImportProgress) -> String {
        if progress.phase == .deleting {
            return String(localized: "Deleting the imported files from the card…", bundle: .module, comment: "Card import progress.")
        }
        return String(
            localized: "\(min(progress.processedFiles + 1, progress.totalFiles)) of \(progress.totalFiles)", bundle: .module,
            comment: "Card import progress: file number of all files.")
    }

    static func resultTitle(_ progress: CardImportProgress) -> String {
        switch progress.phase {
        case .cancelled:
            return String(
                localized: "Import stopped: \(progress.uploaded) items imported", bundle: .module,
                comment: "Card import summary after Stop. Plural variations.")
        case .stopped(let reason):
            return String(localized: "Import stopped: \(reason)", bundle: .module, comment: "Card import summary: why it stopped.")
        default:
            return progress.failed == 0
                ? String(
                    localized: "Imported \(progress.uploaded) items", bundle: .module, comment: "Card import summary. Plural variations.")
                : String(
                    localized: "Imported \(progress.uploaded) items, \(progress.failed) failed", bundle: .module,
                    comment: "Card import summary with failures: imported and failed files.")
        }
    }

    static func resultDetails(_ job: CardImportCenter.Job) -> [String] {
        var lines: [String] = []
        let progress = job.progress
        if progress.verified > 0 {
            lines.append(
                String(
                    localized: "\(progress.verified) files verified on your Nextcloud.", bundle: .module,
                    comment: "Card import summary line. Plural variations."))
        }
        if progress.deleted > 0 {
            lines.append(
                String(
                    localized: "\(progress.deleted) files deleted from the card.", bundle: .module,
                    comment: "Card import summary line. Plural variations."))
        }
        if progress.keptOnCard > 0, progress.phase == .finished {
            lines.append(
                String(
                    localized: "\(progress.keptOnCard) files were kept on the card because they could not be verified.", bundle: .module,
                    comment: "Card import summary line. Plural variations."))
        }
        if job.ejected {
            lines.append(String(localized: "The card was ejected.", bundle: .module, comment: "Card import summary line."))
        } else if let problem = job.ejectProblem {
            lines.append(
                String(localized: "The card could not be ejected: \(problem)", bundle: .module, comment: "Card import summary line."))
        }
        return lines
    }
}
