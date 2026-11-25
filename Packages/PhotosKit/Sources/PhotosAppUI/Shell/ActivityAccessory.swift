// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosBackup
import PhotosCore
import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

// MARK: - What runs in the background (SPEC §17.3)

/// One background activity as the tab bar's accessory shows it: uploads, the backup, an import.
struct ChromeActivity: Equatable {
    /// In the order the accessory prefers them when several run: what the user started just now comes first.
    enum Kind: Int, CaseIterable, Comparable {
        case cardImport, libraryImport, upload, backup

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }

        var symbol: ChromeStatusSymbol.Kind {
            switch self {
            case .upload: .upload
            case .backup: .backup
            case .cardImport, .libraryImport: .importing
            }
        }
    }

    var kind: Kind
    /// `.working` while it runs; `.done` or `.failed` once it has ended.
    var state: ChromeSymbolState
    var done = 0
    var total = 0
    /// 0…1.
    var fraction: Double = 0
    /// The camera or card an import reads from.
    var source: String?
}

/// Turns the app's models into `ChromeActivity` values. Pure, so the decisions are tested.
enum ChromeActivities {
    /// The manual uploads of this batch: the transfers that were not finished yet when the batch began (`baseline` holds
    /// those that were). Nil when none of them runs and none has finished.
    static func upload(_ transfers: [Transfer], baseline: Set<UUID>) -> ChromeActivity? {
        let batch: [Transfer] = transfers.filter { !baseline.contains($0.id) }
        guard !batch.isEmpty else { return nil }
        let finished: Int = batch.filter(\.isFinished).count
        let running: Double = batch.reduce(0) { sum, transfer in
            if case .uploading(let value) = transfer.state { return sum + value }
            return sum
        }
        let failed: Bool = batch.contains { if case .failed = $0.state { true } else { false } }
        let state: ChromeSymbolState = finished < batch.count ? .working : (failed ? .failed : .done)
        return ChromeActivity(
            kind: .upload, state: state, done: finished, total: batch.count,
            fraction: min(1, (Double(finished) + running) / Double(batch.count)))
    }

    /// The transfers a new batch does not count: those finished when nothing was uploading.
    static func uploadBaseline(_ transfers: [Transfer]) -> Set<UUID> {
        Set(transfers.filter(\.isFinished).map(\.id))
    }

    /// The backup, only while it uploads: looking for new photos and checking the server happen at every start and
    /// would make the accessory flicker for nothing. Once a pass that uploaded ends, its outcome.
    static func backup(_ status: BackupStatus, isEnabled: Bool, wasUploading: Bool) -> ChromeActivity? {
        guard isEnabled else { return nil }
        let uploaded: Int = status.uploadedThisPass
        switch status.phase {
        case .uploading(let done, let total, _) where total > 0:
            return ChromeActivity(
                kind: .backup, state: .working, done: done, total: total, fraction: min(1, Double(done) / Double(total)))
        case .uploading, .scanning, .reconciling:
            // Between two rounds of a pass that uploads: it goes on, without a count for a moment.
            return wasUploading ? ChromeActivity(kind: .backup, state: .working, done: uploaded) : nil
        case .upToDate:
            return wasUploading ? ChromeActivity(kind: .backup, state: .done, done: uploaded, total: uploaded, fraction: 1) : nil
        case .incomplete, .failed, .notAuthorized:
            return wasUploading ? ChromeActivity(kind: .backup, state: .failed, fraction: 1) : nil
        case .idle where status.pending == 0 && !status.isInterrupted:
            return wasUploading ? ChromeActivity(kind: .backup, state: .done, done: uploaded, total: uploaded, fraction: 1) : nil
        case .idle, .paused:
            // Paused by the user or the system: no outcome to show.
            return wasUploading ? ChromeActivity(kind: .backup, state: .idle) : nil
        }
    }

    /// An import of other services' exports (SPEC §15.7).
    static func libraryImport(isRunning: Bool, isFinished: Bool, progress: ImportProgress) -> ChromeActivity? {
        if isRunning {
            return ChromeActivity(
                kind: .libraryImport, state: .working, done: progress.processed, total: progress.total, fraction: progress.fraction)
        }
        guard isFinished else { return nil }
        let failed: Bool = if case .stopped = progress.phase { true } else { progress.failed > 0 }
        return ChromeActivity(
            kind: .libraryImport, state: failed ? .failed : .done, done: progress.processed, total: progress.total, fraction: 1)
    }

    /// An import from a camera or memory card (SPEC §15.2).
    static func cardImport(_ progress: CardImportProgress?, device: String?) -> ChromeActivity? {
        guard let progress else { return nil }
        let state: ChromeSymbolState
        switch progress.phase {
        case .importing, .deleting: state = .working
        case .finished: state = progress.failed > 0 ? .failed : .done
        case .stopped: state = .failed
        case .cancelled: return nil
        }
        return ChromeActivity(
            kind: .cardImport, state: state, done: progress.processedFiles, total: progress.totalFiles,
            fraction: state == .working ? progress.fraction : 1, source: device)
    }

    /// What the accessory shows: the running activity first in `Kind` order; else the one that has just ended (it shows
    /// its check mark for `ChromeMotion.finishedLinger`); else nothing, and the accessory goes away.
    static func shown(_ activities: [ChromeActivity], ended: ChromeActivity?) -> ChromeActivity? {
        if let running = activities.filter({ $0.state == .working }).min(by: { $0.kind < $1.kind }) { return running }
        return ended
    }

    /// The activity that has just ended: it was running in `previous` and is not any more in `current`. Its outcome is
    /// the one `current` reports, or "done" when it has gone without one.
    static func ended(previous: [ChromeActivity], current: [ChromeActivity]) -> ChromeActivity? {
        let stillRunning: Set<ChromeActivity.Kind> = Set(current.filter { $0.state == .working }.map(\.kind))
        let stopped: [ChromeActivity] = previous.filter { $0.state == .working && !stillRunning.contains($0.kind) }
        guard let last = stopped.min(by: { $0.kind < $1.kind }) else { return nil }
        if let outcome = current.first(where: { $0.kind == last.kind }) {
            // Stopped without an outcome (paused): the accessory just goes.
            return outcome.state == .idle ? nil : outcome
        }
        var finished = last
        finished.state = .done
        finished.done = last.total
        finished.fraction = 1
        return finished
    }

    /// How many others run besides the one shown.
    static func othersRunning(_ activities: [ChromeActivity], shown: ChromeActivity?) -> Int {
        activities.filter { $0.state == .working && $0.kind != shown?.kind }.count
    }
}

// MARK: - Wording

enum ChromeActivityWording {
    /// The accessory's first line.
    static func title(_ activity: ChromeActivity) -> String {
        switch (activity.kind, activity.state) {
        case (.upload, .working):
            String(localized: "Uploading", bundle: .module, comment: "Tab bar accessory: manual uploads are running.")
        case (.upload, .failed):
            String(localized: "Some uploads failed", bundle: .module)
        case (.upload, _):
            String(localized: "Uploads finished", bundle: .module)
        case (.backup, .working):
            String(localized: "Backing up", bundle: .module, comment: "Tab bar accessory: the backup is uploading.")
        case (.backup, .failed):
            String(localized: "Backup needs attention", bundle: .module, comment: "Tab bar accessory: a backup pass ended with problems.")
        case (.backup, _):
            String(localized: "Backup up to date", bundle: .module, comment: "Tab bar accessory: a backup pass has finished.")
        case (.libraryImport, .working), (.cardImport, .working):
            if let source = activity.source, !source.isEmpty {
                String(
                    localized: "Importing from \(source)", bundle: .module,
                    comment: "Tab bar accessory: an import from a camera or memory card (its name) is running.")
            } else {
                String(localized: "Importing", bundle: .module, comment: "Tab bar accessory: an import is running.")
            }
        case (.libraryImport, .failed), (.cardImport, .failed):
            String(localized: "Import needs attention", bundle: .module, comment: "Tab bar accessory: an import ended with problems.")
        case (.libraryImport, _), (.cardImport, _):
            String(localized: "Import finished", bundle: .module, comment: "Tab bar accessory: an import has finished.")
        }
    }

    /// "12 of 400" while it runs.
    static func count(_ activity: ChromeActivity) -> String? {
        guard activity.state == .working, activity.total > 0 else { return nil }
        return String(
            localized: "\(activity.done) of \(activity.total)", bundle: .module,
            comment: "Tab bar accessory: items done of all items of an upload, backup or import.")
    }

    /// What a tap opens.
    static func hint(_ kind: ChromeActivity.Kind) -> String {
        switch kind {
        case .upload: String(localized: "Shows the uploads", bundle: .module, comment: "Accessibility hint of the tab bar accessory.")
        case .backup: String(localized: "Opens Backup", bundle: .module, comment: "Accessibility hint of the tab bar accessory.")
        case .libraryImport, .cardImport:
            String(localized: "Shows the import", bundle: .module, comment: "Accessibility hint of the tab bar accessory.")
        }
    }

    static func others(_ count: Int) -> String {
        String(
            localized: "+\(count) more", bundle: .module,
            comment: "Tab bar accessory: how many other uploads, backups or imports run besides the one shown.")
    }
}

#if os(iOS)
    // MARK: - The tab bar's accessory (iPhone)

    extension View {
        /// The slim bar above the tab bar while uploads, the backup or an import run, like Music's mini player (SPEC §17.3).
        /// A tap calls `open` with what it shows. Hidden when nothing runs; only where the tab bar is at the bottom.
        func activityAccessory(isAvailable: Bool, open: @escaping @MainActor (ChromeActivity.Kind) -> Void) -> some View {
            modifier(ActivityAccessoryHost(isAvailable: isAvailable, open: open))
        }
    }

    private struct ActivityAccessoryHost: ViewModifier {
        let isAvailable: Bool
        let open: @MainActor (ChromeActivity.Kind) -> Void
        @Environment(SessionModel.self) private var session
        @State private var card = CardImportCenter.shared
        /// The transfers that were finished before the running batch began.
        @State private var uploadBaseline: Set<UUID> = []
        /// The backup uploaded in this pass: its end is shown.
        @State private var backupWasUploading = false
        @State private var previous: [ChromeActivity] = []
        @State private var ended: ChromeActivity?
        /// What the accessory showed last: it keeps showing it while it goes away.
        @State private var lastShown: ChromeActivity?
        #if DEBUG
            @State private var demo: [ChromeActivity]?
        #endif

        var activities: [ChromeActivity] {
            #if DEBUG
                if let demo { return demo }
            #endif
            let importer = ImportController.controller(for: session)
            let candidates: [ChromeActivity?] = [
                ChromeActivities.cardImport(card.job?.progress, device: card.job?.deviceName),
                ChromeActivities.libraryImport(
                    isRunning: importer.stage == .running, isFinished: importer.stage == .finished, progress: importer.progress),
                ChromeActivities.upload(session.transfers.transfers, baseline: uploadBaseline),
                ChromeActivities.backup(
                    session.backup.status, isEnabled: session.backup.settings.isEnabled, wasUploading: backupWasUploading),
            ]
            return candidates.compactMap { $0 }
        }

        func body(content: Content) -> some View {
            let current: [ChromeActivity] = activities
            let shown: ChromeActivity? = ChromeActivities.shown(current, ended: ended)
            content
                .tabViewBottomAccessory(isEnabled: isAvailable && shown != nil) {
                    if let activity = shown ?? lastShown {
                        ActivityAccessoryView(
                            activity: activity, others: ChromeActivities.othersRunning(current, shown: activity)
                        ) { open(activity.kind) }
                    }
                }
                .environment(\.activityAccessoryKinds, isAvailable ? Set(shown.map { [$0.kind] } ?? []) : [])
                .onChange(of: current, initial: true) { old, new in update(old: old, new: new) }
                .onChange(of: session.transfers.activeCount, initial: true) { old, _ in
                    // At launch and when a new batch begins: what had finished before is not counted.
                    if old == 0 { uploadBaseline = ChromeActivities.uploadBaseline(session.transfers.transfers) }
                }
                .onChange(of: session.backup.status.phase, initial: true) { _, phase in
                    if case .uploading = phase { backupWasUploading = true }
                }
                .task(id: ended) {
                    guard ended != nil else { return }
                    try? await Task.sleep(for: ChromeMotion.finishedLinger)
                    guard !Task.isCancelled else { return }
                    ended = nil
                    backupWasUploading = false
                    uploadBaseline = ChromeActivities.uploadBaseline(session.transfers.transfers)
                }
                #if DEBUG
                    .task { await runDemo() }
                #endif
        }

        func update(old: [ChromeActivity], new: [ChromeActivity]) {
            if let finished = ChromeActivities.ended(previous: old, current: new) {
                ended = finished
            } else if new.contains(where: { $0.state == .working }) {
                ended = nil
            }
            if let shown = ChromeActivities.shown(new, ended: ended) { lastShown = shown }
        }

        #if DEBUG
            /// Screenshots and UI checks: `PHOTOS_DEBUG_ACTIVITY=upload|backup|import` plays a made-up activity from 0 to
            /// its end (nothing is uploaded).
            func runDemo() async {
                guard let raw = ProcessInfo.processInfo.environment["PHOTOS_DEBUG_ACTIVITY"] else { return }
                let kind: ChromeActivity.Kind =
                    switch raw {
                    case "backup": .backup
                    case "import": .libraryImport
                    default: .upload
                    }
                let total = 24
                try? await Task.sleep(for: .seconds(4))
                for done in 0...total {
                    demo = [ChromeActivity(kind: kind, state: .working, done: done, total: total, fraction: Double(done) / Double(total))]
                    try? await Task.sleep(for: .milliseconds(done == 0 ? 3000 : 700))
                }
                demo = [ChromeActivity(kind: kind, state: .done, done: total, total: total, fraction: 1)]
                try? await Task.sleep(for: .seconds(6))
                demo = []
            }
        #endif
    }

    /// The accessory's content: the activity's animated symbol, what it is and how far, and a progress ring. Above the
    /// tab bar it has two lines; beside the minimised tab bar (`.inline`) one.
    struct ActivityAccessoryView: View {
        let activity: ChromeActivity
        var others = 0
        let open: () -> Void
        @Environment(\.tabViewBottomAccessoryPlacement) private var placement

        var body: some View {
            Button(action: open) {
                HStack(spacing: 12) {
                    ChromeStatusSymbol(kind: activity.kind.symbol, state: activity.state)
                        .font(.body.weight(.semibold))
                        .frame(width: 26)
                    if placement == .inline {
                        inlineText
                    } else {
                        expandedText
                    }
                    Spacer(minLength: 4)
                    if activity.state == .working {
                        ActivityProgressRing(fraction: activity.fraction).frame(width: 20, height: 20)
                    }
                }
                .padding(.horizontal, 16)
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(accessibilityLabel))
            .accessibilityHint(Text(ChromeActivityWording.hint(activity.kind)))
            .accessibilityAddTraits([.isButton, .updatesFrequently])
            .accessibilityIdentifier("activity-accessory")
        }

        var expandedText: some View {
            VStack(alignment: .leading, spacing: 0) {
                Text(ChromeActivityWording.title(activity))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let count = ChromeActivityWording.count(activity) {
                        Text(count).rollingNumber(activity.done)
                    }
                    if others > 0 { Text(ChromeActivityWording.others(others)) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }

        var inlineText: some View {
            HStack(spacing: 6) {
                Text(ChromeActivityWording.title(activity)).lineLimit(1)
                if let count = ChromeActivityWording.count(activity) {
                    Text(count).foregroundStyle(.secondary).rollingNumber(activity.done)
                }
            }
            .font(.footnote.weight(.medium))
        }

        var accessibilityLabel: String {
            [
                ChromeActivityWording.title(activity), ChromeActivityWording.count(activity),
                others > 0 ? ChromeActivityWording.others(others) : nil,
            ]
            .compactMap { $0 }.joined(separator: ", ")
        }
    }

    /// A thin determinate ring; the GPU animates the trim.
    struct ActivityProgressRing: View {
        let fraction: Double
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: max(0.02, min(1, fraction)))
                    .stroke(.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .animation(reduceMotion ? nil : .smooth, value: fraction)
            .accessibilityHidden(true)
        }
    }
#endif

extension EnvironmentValues {
    /// What the tab bar's accessory shows right now: a toolbar indicator of the same thing steps back (iPhone).
    @Entry var activityAccessoryKinds: Set<ChromeActivity.Kind> = []
}

#if canImport(UIKit)
    extension UIViewController {
        /// Tells the navigation and tab bars which scroll view this screen scrolls, for a scroll view SwiftUI does not
        /// know about (a UIKit grid): the tab bar minimises when it scrolls down (`tabBarMinimizeBehavior`) and the bars
        /// get their scroll edge effect. Set on every controller up to the navigation controller, the SwiftUI hosting
        /// controllers in between included.
        func registerContentScrollView(_ scrollView: UIScrollView) {
            var controller: UIViewController? = self
            while let current = controller, !(current is UINavigationController), !(current is UITabBarController) {
                current.setContentScrollView(scrollView, for: [.top, .bottom])
                controller = current.parent
            }
        }
    }
#endif
