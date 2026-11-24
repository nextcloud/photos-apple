// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosModel
import SwiftUI

/// What smart offline's texts say (SPEC §15.8.1).
enum SmartOfflineWording {
    static func budgetTitle(_ budget: SmartOfflineBudget) -> String {
        switch budget {
        case .off: String(localized: "Off", bundle: .module)
        case .small:
            String(localized: "Small · 1 GB", bundle: .module, comment: "Smart offline storage budget option in Settings.")
        case .medium:
            String(localized: "Medium · 5 GB", bundle: .module, comment: "Smart offline storage budget option in Settings.")
        case .large:
            String(localized: "Large · 20 GB", bundle: .module, comment: "Smart offline storage budget option in Settings.")
        }
    }

    /// "1.2 GB · 1,840 photos".
    static func usage(_ summary: SmartOfflineSummary) -> String {
        String(
            localized: "\(Formatters.bytes(summary.bytes)) · \(summary.count) photos", bundle: .module,
            comment: "Space smart offline uses and how many photos it keeps, in Settings. Plural variations in the catalog.")
    }

    /// What the kept photos cover, as one sentence; nil when nothing is kept.
    static func coverage(_ summary: SmartOfflineSummary, locale: Locale = .current) -> String? {
        guard summary.count > 0 else { return nil }
        var parts: [String] = []
        if let since = summary.recentSince {
            let month = since.formatted(.dateTime.month(.wide).year().locale(locale))
            parts.append(
                String(
                    localized: "your photos since \(month)", bundle: .module,
                    comment: "Part of the list of what smart offline keeps; the argument is a month and year, e.g. August 2026."))
        }
        if summary.favorites > 0 {
            parts.append(
                String(
                    localized: "\(summary.favorites) favorites", bundle: .module,
                    comment: "Part of the list of what smart offline keeps. Plural variations in the catalog."))
        }
        if summary.onThisDay > 0 {
            parts.append(
                String(
                    localized: "\(summary.onThisDay) photos of the coming days' memories", bundle: .module,
                    comment: "Part of the list of what smart offline keeps: photos of On this day memories of the next days."))
        }
        if summary.albums > 0 {
            parts.append(
                String(
                    localized: "photos of \(summary.albums) albums you opened recently", bundle: .module,
                    comment: "Part of the list of what smart offline keeps. Plural variations in the catalog."))
        }
        guard !parts.isEmpty else { return nil }
        return parts.formatted(.list(type: .and).locale(locale))
    }

    /// The footer of the Settings section: what it keeps and when it downloads, in the platform's words.
    static var footer: String {
        #if os(macOS)
            String(
                localized:
                    "Keeps the photos you're most likely to look at without a connection: your recent photos, favorites, the coming days' memories and albums you opened recently. It downloads on Wi-Fi while your Mac isn't busy and makes room for newer photos by itself. Albums you make available offline are kept in addition.",
                bundle: .module, comment: "Footer of Settings › Smart offline on the Mac.")
        #elseif os(visionOS)
            String(
                localized:
                    "Keeps the photos you're most likely to look at without a connection: your recent photos, favorites, the coming days' memories and albums you opened recently. It downloads on Wi-Fi while the app is open and makes room for newer photos by itself. Albums you make available offline are kept in addition.",
                bundle: .module, comment: "Footer of Settings › Smart offline on Apple Vision Pro.")
        #else
            String(
                localized:
                    "Keeps the photos you're most likely to look at without a connection: your recent photos, favorites, the coming days' memories and albums you opened recently. It downloads on Wi-Fi, mostly while charging, and makes room for newer photos by itself. Albums you make available offline are kept in addition.",
                bundle: .module, comment: "Footer of Settings › Smart offline on iPhone and iPad.")
        #endif
    }
}

/// Settings › Storage › Smart offline: the budget, previews or originals, and what it keeps now.
struct SmartOfflineSettingsSection: View {
    @Environment(SessionModel.self) private var session
    @AppStorage(SmartOfflineSettings.budgetKey) private var budget: SmartOfflineBudget = .default
    @AppStorage(SmartOfflineSettings.qualityKey) private var quality: SmartOfflineQuality = .screen
    @State private var summary = SmartOfflineSummary()
    @State private var working = false

    var body: some View {
        Section {
            Picker(String(localized: "Space to use", bundle: .module, comment: "Smart offline storage budget picker."), selection: $budget)
            {
                ForEach(SmartOfflineBudget.allCases, id: \.self) { budget in
                    Text(SmartOfflineWording.budgetTitle(budget)).tag(budget)
                }
            }
            .onChange(of: budget) { _, _ in apply() }
            if budget != .off {
                Toggle(
                    String(
                        localized: "Keep originals", bundle: .module, comment: "Smart offline: keep original files instead of previews."),
                    isOn: Binding(get: { quality == .original }, set: { quality = $0 ? .original : .screen })
                )
                .onChange(of: quality) { _, _ in apply() }
            }
            LabeledContent(String(localized: "In use", bundle: .module, comment: "Space smart offline uses now, in Settings.")) {
                if working {
                    ProgressView().controlSize(.small)
                } else {
                    Text(SmartOfflineWording.usage(summary))
                }
            }
            if let coverage = SmartOfflineWording.coverage(summary) {
                Text(
                    "Kept now: \(coverage).", bundle: .module,
                    comment: "What smart offline keeps, e.g. \"Kept now: your photos since August 2026, 12 favorites and …\"."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        } header: {
            Text("Smart offline", bundle: .module, comment: "Settings section title.")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(SmartOfflineWording.footer)
                if quality == .screen && budget != .off {
                    Text(
                        "Photos are kept as large as your screen shows them; videos as a still picture.", bundle: .module,
                        comment: "Footer of Settings › Smart offline when previews are kept.")
                }
            }
        }
        .task { await refresh() }
    }

    func refresh() async {
        summary = await session.smartOffline?.summary() ?? SmartOfflineSummary()
    }

    func apply() {
        working = true
        Task {
            await session.smartOfflineSettingsChanged()
            await refresh()
            working = false
        }
    }
}

/// The bar over a grid while offline: what can be looked at (SPEC §15.8.1).
struct OfflineAvailabilityBanner: View {
    @Environment(SessionModel.self) private var session
    @State private var summary = SmartOfflineSummary()

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("Offline – showing saved photos", bundle: .module)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
        } icon: {
            Image(systemName: "wifi.slash")
        }
        .accessibilityElement(children: .combine)
        .font(.footnote)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
        .padding(.horizontal)
        .padding(.bottom, 12)
        .task { summary = await session.smartOffline?.summary() ?? SmartOfflineSummary() }
    }

    var detail: String? {
        guard summary.count > 0, let coverage = SmartOfflineWording.coverage(summary) else { return nil }
        return String(
            localized: "Available in full: \(coverage).", bundle: .module,
            comment:
                "Second line of the offline banner: what smart offline keeps, e.g. \"Available in full: your photos since August 2026 and 12 favorites.\""
        )
    }
}

/// Whether a photo can be looked at without a connection (Info panel): kept by smart offline or an offline album.
enum OfflineAvailability {
    @MainActor static func isAvailable(_ item: MediaItem, session: SessionModel) -> Bool {
        session.smartOffline?.isKept(item.fileId) == true || session.offline?.localFile(fileId: item.fileId, etag: item.etag) != nil
    }
}
