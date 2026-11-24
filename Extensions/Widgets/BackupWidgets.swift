// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import AppIntents
import PhotosBackup
import PhotosCore
import SwiftUI
import WidgetKit

#if os(iOS)
    import ActivityKit
#endif

// MARK: - Backup status widget (SPEC §7.22, §15.4)

/// The backup at a glance: on the Lock Screen (circular, rectangular, inline) and as a small widget. It reads the snapshot
/// the app writes into the App Group whenever the backup's phase changes (`BackupPresence`).
struct BackupStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: AmbientKinds.backupStatus, provider: BackupStatusProvider()) { entry in
            BackupStatusView(entry: entry)
        }
        .configurationDisplayName(String(localized: "Backup", comment: "Widget name: the photo backup's status."))
        .description(String(localized: "How the backup of your photos is doing.", comment: "Widget description."))
        .supportedFamilies(Self.families)
    }

    static var families: [WidgetFamily] {
        #if os(iOS)
            [.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline]
        #else
            [.systemSmall]
        #endif
    }
}

struct BackupStatusEntry: TimelineEntry {
    var date: Date
    var snapshot: BackupWidgetSnapshot?
}

struct BackupStatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> BackupStatusEntry {
        BackupStatusEntry(
            date: Date(),
            snapshot: BackupWidgetSnapshot(
                isEnabled: true, isSetUp: true, state: BackupActivityState(phase: .uploading, done: 4, total: 16, remaining: 12),
                pending: 12, lastRun: nil))
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (BackupStatusEntry) -> Void) {
        completion(BackupStatusEntry(date: Date(), snapshot: BackupWidgetSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<BackupStatusEntry>) -> Void) {
        // The app reloads the widget when something changes; the entries every quarter of an hour keep "Last backup …
        // ago" current.
        let now = Date()
        let snapshot = BackupWidgetSnapshot.load()
        let entries = (0..<8).map { BackupStatusEntry(date: now.addingTimeInterval(Double($0) * 900), snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(2 * 3600))))
    }
}

/// What the widget says, from the snapshot.
struct BackupStatusSummary {
    var symbol: String
    var title: String
    var detail: String?
    var fraction: Double?

    init(_ snapshot: BackupWidgetSnapshot?) {
        guard let snapshot, snapshot.isSetUp else {
            symbol = "icloud.slash"
            title = String(localized: "Backup is off", comment: "Backup widget: backup is not set up or turned off.")
            detail = String(localized: "Turn it on in the app", comment: "Backup widget, below \"Backup is off\".")
            return
        }
        guard snapshot.isEnabled else {
            symbol = "icloud.slash"
            title = String(localized: "Backup is off", comment: "Backup widget: backup is not set up or turned off.")
            detail = nil
            return
        }
        if let state = snapshot.state, state.phase != .done {
            symbol = Self.symbol(state.phase)
            title = state.headline
            detail = state.detail
            fraction = state.fraction
            return
        }
        if snapshot.pending > 0 {
            symbol = "icloud.and.arrow.up"
            title = String(
                localized: "\(snapshot.pending) waiting",
                comment: "Backup widget: items not uploaded yet. Plural variations in the catalog.")
        } else {
            symbol = "checkmark.icloud"
            title = String(localized: "Backed up", comment: "Backup widget and Live Activity: everything is on the server.")
        }
        detail = nil
        fraction = snapshot.pending > 0 ? nil : 1
    }

    /// "Last backup 5 minutes ago".
    static func lastBackup(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        let relative = formatter.localizedString(for: min(date, now), relativeTo: now)
        return String(
            localized: "Last backup \(relative)", comment: "Backup widget: when the last backup ran, e.g. “Last backup 5 minutes ago”.")
    }

    static func symbol(_ phase: BackupActivityState.Phase) -> String {
        switch phase {
        case .preparing: "magnifyingglass"
        case .uploading: "icloud.and.arrow.up"
        case .paused: "pause.circle"
        case .done: "checkmark.icloud"
        case .stopped: "exclamationmark.icloud"
        }
    }
}

struct BackupStatusView: View {
    let entry: BackupStatusEntry
    @Environment(\.widgetFamily) private var family

    var summary: BackupStatusSummary { BackupStatusSummary(entry.snapshot) }

    var body: some View {
        content
            .widgetURL(URL(string: "nextcloudphotos://backup"))
            .containerBackground(for: .widget) { Color.clear }
    }

    @ViewBuilder var content: some View {
        switch family {
        #if os(iOS)
            case .accessoryCircular:
                if let fraction = summary.fraction, fraction < 1 {
                    Gauge(value: fraction) {
                        Image(systemName: summary.symbol)
                    }
                    .gaugeStyle(.accessoryCircularCapacity)
                } else {
                    ZStack {
                        AccessoryWidgetBackground()
                        Image(systemName: summary.symbol).font(.title2)
                    }
                }
            case .accessoryInline:
                Label(summary.title, systemImage: summary.symbol)
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 2) {
                    Label(summary.title, systemImage: summary.symbol).font(.headline).widgetAccentable()
                    if let detail = summary.detail { Text(detail).font(.caption).lineLimit(2) }
                    if let fraction = summary.fraction, fraction < 1 { ProgressView(value: fraction) }
                    if summary.detail == nil, let lastRun = entry.snapshot?.lastRun {
                        Text(BackupStatusSummary.lastBackup(lastRun, now: entry.date)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
        #endif
        default:
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: summary.symbol).font(.title2).foregroundStyle(BackupColors.accent).widgetAccentable()
                Spacer(minLength: 0)
                Text(summary.title).font(.headline).lineLimit(2)
                if let detail = summary.detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                if let fraction = summary.fraction, fraction < 1 { ProgressView(value: fraction).tint(BackupColors.accent) }
                if summary.detail == nil, let lastRun = entry.snapshot?.lastRun {
                    Text(BackupStatusSummary.lastBackup(lastRun, now: entry.date)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

enum BackupColors {
    /// Nextcloud blue.
    static let accent = Color(red: 0, green: 0.51, blue: 0.79)
}

#if os(iOS)
    // MARK: - Live Activity (SPEC §15.4)

    /// The backup on the Lock Screen and in the Dynamic Island while a larger pass runs: photos left, their size, why it
    /// waits, and that it is done.
    struct BackupLiveActivityWidget: Widget {
        var body: some WidgetConfiguration {
            ActivityConfiguration(for: BackupActivityAttributes.self) { context in
                BackupActivityView(state: context.state, isStale: context.isStale)
                    .activityBackgroundTint(nil)
                    .widgetURL(URL(string: "nextcloudphotos://backup"))
            } dynamicIsland: { context in
                let state = context.state
                return DynamicIsland {
                    DynamicIslandExpandedRegion(.leading) {
                        Image(systemName: BackupStatusSummary.symbol(state.phase))
                            .font(.title2)
                            .foregroundStyle(BackupColors.accent)
                    }
                    DynamicIslandExpandedRegion(.trailing) {
                        if state.phase == .uploading {
                            Text("\(state.done) of \(state.total)", comment: "Backup Live Activity: uploaded of all in this pass.")
                                .font(.callout.monospacedDigit())
                        }
                    }
                    DynamicIslandExpandedRegion(.center) {
                        Text(state.headline).font(.headline).lineLimit(1)
                    }
                    DynamicIslandExpandedRegion(.bottom) {
                        BackupActivityDetails(state: state, isStale: context.isStale)
                    }
                } compactLeading: {
                    Image(systemName: BackupStatusSummary.symbol(state.phase)).foregroundStyle(BackupColors.accent)
                } compactTrailing: {
                    if state.phase == .uploading {
                        Text(state.remaining, format: .number).monospacedDigit().foregroundStyle(BackupColors.accent)
                    } else if state.phase == .done {
                        Image(systemName: "checkmark").foregroundStyle(.green)
                    } else {
                        Image(systemName: "pause.fill").foregroundStyle(.orange)
                    }
                } minimal: {
                    if let fraction = state.fraction, state.phase == .uploading {
                        ProgressView(value: fraction) { Image(systemName: "arrow.up") }
                            .progressViewStyle(.circular)
                            .tint(BackupColors.accent)
                    } else {
                        Image(systemName: BackupStatusSummary.symbol(state.phase)).foregroundStyle(BackupColors.accent)
                    }
                }
                .widgetURL(URL(string: "nextcloudphotos://backup"))
                .keylineTint(BackupColors.accent)
            }
        }
    }

    /// The Lock Screen's banner.
    struct BackupActivityView: View {
        let state: BackupActivityState
        let isStale: Bool

        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: BackupStatusSummary.symbol(state.phase))
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(BackupColors.accent, in: .circle)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(state.headline).font(.headline)
                        Spacer()
                        Text("Nextcloud Photos").font(.caption2).foregroundStyle(.secondary)
                    }
                    BackupActivityDetails(state: state, isStale: isStale)
                }
            }
            .padding(16)
        }
    }

    /// Progress, size left or the reason it waits, and the Pause / Back Up Now button.
    struct BackupActivityDetails: View {
        let state: BackupActivityState
        let isStale: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                if let fraction = state.fraction, state.phase == .uploading {
                    ProgressView(value: fraction).tint(BackupColors.accent)
                }
                HStack(alignment: .center) {
                    if let detail = lineText {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    switch state.phase {
                    case .uploading, .preparing:
                        Button(intent: PauseBackupIntent()) {
                            Label(String(localized: "Pause", comment: "Backup Live Activity button."), systemImage: "pause.fill")
                        }
                        .font(.caption.weight(.semibold))
                        .tint(BackupColors.accent)
                    case .paused:
                        Button(intent: BackUpNowControlIntent()) {
                            Label(String(localized: "Resume", comment: "Backup Live Activity button."), systemImage: "play.fill")
                        }
                        .font(.caption.weight(.semibold))
                        .tint(BackupColors.accent)
                    case .done, .stopped:
                        EmptyView()
                    }
                }
            }
        }

        var lineText: String? {
            if isStale, !state.isFinal {
                return String(
                    localized: "Continues in the background", comment: "Backup Live Activity: the app is suspended, uploads go on.")
            }
            return state.detail
        }
    }

    // MARK: - Controls (SPEC §15.4)

    /// "Backup" on or off, for Control Center, the Lock Screen and the Action button.
    struct BackupToggleControl: ControlWidget {
        var body: some ControlWidgetConfiguration {
            StaticControlConfiguration(kind: AmbientKinds.backupToggle, provider: BackupToggleValue()) { isOn in
                ControlWidgetToggle(isOn: isOn, action: SetBackupIntent()) {
                    Label(
                        String(localized: "Backup", comment: "Control Center control: photo backup on or off."),
                        systemImage: "icloud.and.arrow.up")
                } valueLabel: { isOn in
                    Label(
                        isOn
                            ? String(localized: "On", comment: "Backup control: value.")
                            : String(localized: "Off", comment: "Backup control: value."),
                        systemImage: isOn ? "icloud.and.arrow.up.fill" : "icloud.slash")
                }
                .tint(BackupColors.accent)
            }
            .displayName(LocalizedStringResource("Photo Backup", comment: "Control name in the controls gallery."))
            .description(LocalizedStringResource("Turns the backup to your Nextcloud on or off.", comment: "Control description."))
        }
    }

    struct BackupToggleValue: ControlValueProvider {
        var previewValue: Bool { true }

        func currentValue() async throws -> Bool {
            BackupSettings.load(from: AppPaths.layout.backupSettingsFile).isEnabled
        }
    }

    /// "Back Up Now", for Control Center, the Lock Screen and the Action button.
    struct BackUpNowControl: ControlWidget {
        var body: some ControlWidgetConfiguration {
            StaticControlConfiguration(kind: AmbientKinds.backUpNow) {
                ControlWidgetButton(action: BackUpNowControlIntent()) {
                    Label(
                        String(localized: "Back Up Now", comment: "Control Center control: starts a photo backup."),
                        systemImage: "arrow.clockwise.icloud")
                }
                .tint(BackupColors.accent)
            }
            .displayName(LocalizedStringResource("Back Up Now", comment: "Control name in the controls gallery."))
            .description(LocalizedStringResource("Uploads new photos to your Nextcloud.", comment: "Control description."))
        }
    }

    /// Opens the library.
    struct OpenLibraryControl: ControlWidget {
        var body: some ControlWidgetConfiguration {
            StaticControlConfiguration(kind: AmbientKinds.openLibrary) {
                ControlWidgetButton(action: OpenLibraryControlIntent()) {
                    Label(
                        String(localized: "Nextcloud Photos", comment: "Control Center control: opens the app."),
                        systemImage: "photo.on.rectangle")
                }
            }
            .displayName(LocalizedStringResource("Nextcloud Photos", comment: "Control name in the controls gallery."))
            .description(LocalizedStringResource("Opens your photo library.", comment: "Control description."))
        }
    }
#endif
