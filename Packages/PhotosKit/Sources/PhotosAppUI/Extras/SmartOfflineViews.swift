// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosMedia
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

/// What the "Keep thumbnails of the whole library" texts say (SPEC §18.3.1).
enum LibraryThumbnailsWording {
    /// "About 640 MB for 48,000 photos".
    static func estimate(bytes: Int64, photos: Int) -> String {
        String(
            localized: "About \(Formatters.bytes(bytes)) for \(photos) photos", bundle: .module,
            comment:
                "Settings › Thumbnails of the whole library, before it is turned on: the estimated space and the number of photos. Plural variations in the catalog."
        )
    }

    /// "12,340 of 48,000 photos".
    static func progress(done: Int, total: Int) -> String {
        String(
            localized: "\(done) of \(total) photos", bundle: .module,
            comment: "Settings › Thumbnails of the whole library: how many photos have their thumbnails on this device so far.")
    }

    /// "All 48,000 photos".
    static func complete(_ total: Int) -> String {
        String(
            localized: "All \(total) photos", bundle: .module,
            comment:
                "Settings › Thumbnails of the whole library: every photo's thumbnails are on this device. Plural variations in the catalog."
        )
    }

    /// Why nothing is downloaded now, in the platform's words.
    static var waiting: String {
        #if os(macOS)
            String(
                localized: "Waiting for a network that isn't metered", bundle: .module,
                comment:
                    "Settings › Thumbnails of the whole library on the Mac: paused on a personal hotspot, in Low Data Mode or in Low Power Mode."
            )
        #else
            String(
                localized: "Waiting for Wi-Fi", bundle: .module,
                comment:
                    "Settings › Thumbnails of the whole library: paused because there is no Wi-Fi (or Low Power Mode or Low Data Mode is on)."
            )
        #endif
    }

    /// The footer of the section, in the platform's words.
    static var footer: String {
        #if os(macOS)
            String(
                localized:
                    "Keeps a small picture of every photo on this Mac, so that your library shows pictures at once at every zoom level, also without a connection. They are downloaded while the app isn't loading anything else, and never slow down scrolling.",
                bundle: .module, comment: "Footer of Settings › Thumbnails of the whole library on the Mac.")
        #elseif os(visionOS)
            String(
                localized:
                    "Keeps a small picture of every photo on Apple Vision Pro, so that your library shows pictures at once at every zoom level, also without a connection. They are downloaded on Wi-Fi while the app is open and isn't loading anything else.",
                bundle: .module, comment: "Footer of Settings › Thumbnails of the whole library on Apple Vision Pro.")
        #else
            String(
                localized:
                    "Keeps a small picture of every photo, so that your library shows pictures at once at every zoom level, also without a connection. They are downloaded on Wi-Fi while the app isn't loading anything else, and while charging, never in Low Power Mode.",
                bundle: .module, comment: "Footer of Settings › Thumbnails of the whole library on iPhone and iPad.")
        #endif
    }
}

/// Settings › Storage › Thumbnails of the whole library (SPEC §18.3.1): the switch with the space it takes before it is
/// turned on, and how far the thumbnails are while it is on.
struct LibraryThumbnailsSettingsSection: View {
    @Environment(SessionModel.self) private var session
    @AppStorage(CacheLimits.wholeLibraryThumbnailsKey) private var enabled = LibraryThumbnailPlan.defaultEnabled
    @AppStorage(LibraryThumbnailSettings.cellularKey) private var cellular = false
    @State private var estimate: (photos: Int, bytes: Int64)?
    @State private var progress = LibraryThumbnailFiller.Progress()

    var body: some View {
        Section {
            Toggle(
                String(
                    localized: "Keep thumbnails of the whole library", bundle: .module,
                    comment: "Settings switch: keep a small preview of every photo of the library on the device."),
                isOn: $enabled
            )
            .onChange(of: enabled) { _, _ in Task { await session.libraryThumbnailsSettingChanged() } }
            if enabled {
                progressRow
                #if os(iOS)
                    Toggle(
                        String(
                            localized: "Use cellular data", bundle: .module,
                            comment: "Settings › Thumbnails of the whole library: also download them on cellular."),
                        isOn: $cellular
                    )
                    .onChange(of: cellular) { _, _ in Task { await session.libraryThumbnailsSettingChanged() } }
                #endif
            } else if let estimate, estimate.photos > 0 {
                Text(LibraryThumbnailsWording.estimate(bytes: estimate.bytes, photos: estimate.photos))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Thumbnails", bundle: .module, comment: "Settings section title: thumbnails of the whole library.")
        } footer: {
            Text(LibraryThumbnailsWording.footer)
        }
        .task(id: enabled) { await follow() }
    }

    @ViewBuilder var progressRow: some View {
        if progress.countedAt == nil && !progress.isRunning {
            ProgressView().controlSize(.small)
        } else if progress.isComplete && !progress.isRunning {
            LabeledContent(
                String(
                    localized: "Photos with thumbnails", bundle: .module,
                    comment: "Settings › Thumbnails of the whole library: label of how many photos have their thumbnails on the device."),
                value: LibraryThumbnailsWording.complete(progress.total))
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: progress.fraction)
                HStack {
                    Text(LibraryThumbnailsWording.progress(done: progress.done, total: progress.total))
                    Spacer()
                    if progress.isWaitingForConditions && !progress.isRunning {
                        Text(LibraryThumbnailsWording.waiting)
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// Off: the estimate. On: the progress, followed while the section is shown.
    func follow() async {
        guard let thumbnails = session.smartOffline?.thumbnails else { return }
        guard enabled else {
            estimate = await thumbnails.estimate()
            return
        }
        progress = thumbnails.progress
        if progress.countedAt == nil && !progress.isRunning {
            await thumbnails.count()
        }
        while !Task.isCancelled {
            progress = thumbnails.progress
            try? await Task.sleep(for: .seconds(1))
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
