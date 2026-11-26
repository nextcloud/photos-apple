// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import SwiftUI

/// The pages of Settings (SPEC §20.4). iPhone, iPad and Vision Pro list them on the first screen of Settings, with a
/// search field over every setting; the Mac's Settings window has a tab per page (`MacSettingsPage`), with Library and
/// Notifications together under General, as Mac apps do.
public enum SettingsPage: String, CaseIterable, Hashable, Sendable, Identifiable {
    /// The list of pages (iPhone, iPad, Vision Pro), or a link to Settings opened in a window (Mac).
    case all
    /// Accounts, the server and the sync.
    case accounts
    /// Timeline folders, upload folder, display, appearance, partner and family sharing (iPhone, iPad, Vision Pro).
    case library
    /// Notifications, photo of the day, weekly prompts (iPhone, iPad, Vision Pro).
    case notifications
    /// Library and Notifications together: the Mac's General tab.
    case general
    /// The backup screen (iPhone, iPad, Vision Pro: a page; Mac: a tab of the Settings window).
    case backup
    /// Preview cache, thumbnails, smart offline, offline albums.
    case storage
    /// App lock and the analysis of photos on this device.
    case privacy
    /// Desktop pictures (Mac).
    case desktop
    /// The Advanced features switch, folder rules, the menu bar extra (Mac), diagnostics.
    case advanced
    case about

    public var id: String { rawValue }

    /// The pages the first screen of Settings lists, in its groups (iPhone, iPad, Vision Pro).
    static let listed: [[SettingsPage]] = [[.accounts], [.library, .notifications, .backup, .storage, .privacy], [.advanced, .about]]

    /// The pages of this platform, in order: what the first screen lists, or the Mac's tabs.
    static var shown: [SettingsPage] {
        #if os(macOS)
            [.general, .accounts, .backup, .storage, .privacy, .desktop, .advanced, .about]
        #else
            listed.flatMap { $0 }
        #endif
    }

    var title: String {
        switch self {
        case .all: String(localized: "Settings", bundle: .module)
        case .accounts: String(localized: "Accounts", bundle: .module)
        case .library: String(localized: "Library", bundle: .module)
        case .notifications: String(localized: "Notifications", bundle: .module)
        case .general: String(localized: "General", bundle: .module)
        case .backup: String(localized: "Backup", bundle: .module)
        case .storage:
            PlatformWording.title(
                mac: LocalizedStringResource("Storage", bundle: .module),
                other: LocalizedStringResource(
                    "Storage & cache", bundle: .module, comment: "Settings page: preview cache, thumbnails, offline photos."))
        case .privacy:
            PlatformWording.title(
                mac: LocalizedStringResource("Privacy", bundle: .module),
                other: LocalizedStringResource(
                    "Privacy & security", bundle: .module, comment: "Settings page: app lock and the analysis of photos on this device."))
        case .desktop: String(localized: "Desktop", bundle: .module)
        case .advanced:
            String(localized: "Advanced", bundle: .module, comment: "Settings page: advanced features, folder rules, diagnostics.")
        case .about: String(localized: "About", bundle: .module)
        }
    }

    var systemImage: String {
        switch self {
        case .all, .general: "gearshape"
        case .accounts: "person.crop.circle"
        case .library: "photo.on.rectangle"
        case .notifications: "bell.badge"
        case .backup: "icloud.and.arrow.up"
        case .storage: "internaldrive"
        case .privacy: "hand.raised"
        case .desktop: "menubar.dock.rectangle"
        case .advanced: "slider.horizontal.3"
        case .about: "info.circle"
        }
    }

    /// The Mac tab a page is in (Library and Notifications are General there).
    var macTab: SettingsPage {
        switch self {
        case .library, .notifications, .all: .general
        default: self
        }
    }
}

/// Every setting by its title, for the search on the first screen of Settings: the title as the page shows it, the page
/// it is on, and other words people may type (English; titles are matched in the user's language).
struct SettingsIndex {
    struct Entry: Hashable, Identifiable {
        var title: String
        var page: SettingsPage
        var keywords: [String] = []
        var id: String { page.rawValue + "/" + title }
    }

    let entries: [Entry]

    /// The settings of this platform.
    static var current: SettingsIndex { SettingsIndex(entries: entries(isMac: Self.isMac)) }

    static var isMac: Bool {
        #if os(macOS)
            true
        #else
            false
        #endif
    }

    // swift-format-ignore: FunctionBodyLength
    /// The settings of the Mac or of the other platforms (Lock Screen album and import are not on the Mac, the menu bar
    /// extra and desktop pictures only there).
    static func entries(isMac: Bool) -> [Entry] {
        func entry(_ title: String, _ page: SettingsPage, _ keywords: [String] = []) -> Entry {
            Entry(title: title, page: isMac ? page.macTab : page, keywords: keywords)
        }
        var result: [Entry] = [
            entry(String(localized: "Accounts", bundle: .module), .accounts, ["login", "log out", "sign in", "sign out", "switch"]),
            entry(String(localized: "Add account…", bundle: .module), .accounts, ["login", "sign in"]),
            entry(String(localized: "Server features", bundle: .module), .accounts, ["nextcloud", "version", "capabilities"]),
            entry(String(localized: "Sync now", bundle: .module), .accounts, ["refresh", "reload", "server"]),
            entry(String(localized: "Timeline folders", bundle: .module), .library, ["source", "folders", "media folders"]),
            entry(String(localized: "Upload folder", bundle: .module), .library, ["camera uploads", "location"]),
            entry(String(localized: "Show memories", bundle: .module), .library, ["stories", "strip", "for you"]),
            entry(String(localized: "Square tiles", bundle: .module), .library, ["grid", "aspect ratio", "crop"]),
            entry(String(localized: "Stack copies of a photo", bundle: .module), .library, ["duplicates", "raw", "heic", "jpeg"]),
            entry(
                String(localized: "Appearance", bundle: .module), .library, ["viewer background", "colors", "tint", "live photo covers"]),
            entry(String(localized: "Partner sharing", bundle: .module), .library, ["partner", "share my photos"]),
            entry(FamilyWording.title, .library, ["family", "shared library"]),
            entry(String(localized: "Notifications", bundle: .module), .notifications, ["push", "alerts"]),
            entry(String(localized: "On this day", bundle: .module), .notifications, ["memories", "years ago"]),
            entry(String(localized: "New photos in shared albums", bundle: .module), .notifications, ["activity", "shared albums"]),
            entry(String(localized: "Photo of the Day", bundle: .module), .notifications, ["daily"]),
            entry(PromptWording.title, .notifications, ["prompt", "reminder", "weekend"]),
            entry(String(localized: "Preview cache", bundle: .module), .storage, ["cache", "space", "clear", "size"]),
            entry(String(localized: "Thumbnails", bundle: .module), .storage, ["whole library", "cellular", "cache"]),
            entry(String(localized: "Smart offline", bundle: .module), .storage, ["offline", "space", "originals"]),
            entry(String(localized: "Available offline", bundle: .module), .storage, ["offline", "download", "wi-fi"]),
            // `CacheDiagnosticsView.title`, which is the main actor's.
            entry(String(localized: "Cache performance", bundle: .module), .storage, ["cache", "diagnostics"]),
            entry(DeviceLockWording.current.toggleTitle, .privacy, ["face id", "touch id", "optic id", "passcode", "password", "lock"]),
            entry(String(localized: "Recognize what's in photos", bundle: .module), .privacy, ["search", "labels", "on-device"]),
            entry(String(localized: "Find similar photos", bundle: .module), .privacy, ["similar", "on-device"]),
            entry(String(localized: "Describe photos", bundle: .module), .privacy, ["descriptions", "captions", "on-device"]),
            entry(AdvancedFeaturesWording.toggleTitle, .advanced, ["stickers", "insights", "collage", "postcard", "culling", "rating"]),
            entry(String(localized: "Folder Rules", bundle: .module), .advanced, ["organize", "rules", "automatic"]),
            entry(String(localized: "Export diagnostics…", bundle: .module), .advanced, ["log", "report", "problem", "bug"]),
            entry(String(localized: "Keep log across restarts", bundle: .module), .advanced, ["log"]),
            entry(String(localized: "Version", bundle: .module), .about, ["about", "build"]),
            entry(String(localized: "Licences", bundle: .module), .about, ["licenses", "open source", "source code"]),
            entry(String(localized: "Backup", bundle: .module), .backup, ["camera roll", "auto upload", "upload"]),
        ]
        if isMac {
            result.append(entry(MenuBarExtraSettings.title, .advanced, ["menu bar", "status item"]))
            result.append(entry(String(localized: "Desktop", bundle: .module), .desktop, ["wallpaper", "desktop picture"]))
        } else {
            result.append(
                entry(
                    String(localized: "Import from Other Services…", bundle: .module), .library,
                    ["google photos", "takeout", "icloud", "facebook", "instagram"]))
            result.append(entry(LockScreenWording.title, .library, ["lock screen", "wallpaper", "shuffle"]))
        }
        return result
    }

    /// The settings whose title, page or keywords contain every word of `query` (ignoring case and accents), in the
    /// order of the pages.
    func search(_ query: String) -> [Entry] {
        let words: [String] = query.split(whereSeparator: \.isWhitespace).map { Self.folded(String($0)) }
        guard !words.isEmpty else { return [] }
        let order: [SettingsPage] = SettingsPage.allCases
        return entries.filter { entry in
            let haystack: String = Self.folded(([entry.title, entry.page.title] + entry.keywords).joined(separator: " "))
            return words.allSatisfy { haystack.contains($0) }
        }
        .sorted { (order.firstIndex(of: $0.page) ?? 0) < (order.firstIndex(of: $1.page) ?? 0) }
    }

    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }
}

#if !os(macOS)
    /// The first screen of Settings: the account, the pages, and a search over every setting (iPhone, iPad, Vision Pro).
    struct SettingsHome: View {
        @Environment(SessionModel.self) private var session
        @State private var query = ""

        var body: some View {
            List {
                if query.isEmpty {
                    ForEach(SettingsPage.listed.indices, id: \.self) { (group: Int) in
                        Section {
                            ForEach(SettingsPage.listed[group]) { (page: SettingsPage) in
                                NavigationLink(value: page) { row(page) }
                                    .accessibilityIdentifier("settings-page-" + page.rawValue)
                            }
                        }
                    }
                } else {
                    results
                }
            }
            .navigationTitle(SettingsPage.all.title)
            .searchable(text: $query, prompt: Text("Search settings", bundle: .module, comment: "Settings: prompt of the search field."))
            .navigationDestination(for: SettingsPage.self) { (page: SettingsPage) in SettingsPageView(page: page) }
        }

        @ViewBuilder func row(_ page: SettingsPage) -> some View {
            if page == .accounts {
                // The account shown, like the Apple Account at the top of the system's Settings.
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.account.displayName)
                        Text(session.account.hostDisplayName).font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: page.systemImage)
                }
                .accessibilityElement(children: .combine)
                .accessibilityHint(Text(page.title))
            } else if page == .backup, let status = backupStatus {
                LabeledContent {
                    Text(status)
                } label: {
                    Label(page.title, systemImage: page.systemImage)
                }
            } else {
                Label(page.title, systemImage: page.systemImage)
            }
        }

        var backupStatus: String? {
            let backup = session.backup
            return BackupRowStatus.text(isAvailable: backup.isAvailable, isEnabled: backup.settings.isEnabled, status: backup.status)
        }

        @ViewBuilder var results: some View {
            let found: [SettingsIndex.Entry] = SettingsIndex.current.search(query)
            if found.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ForEach(found) { (entry: SettingsIndex.Entry) in
                    NavigationLink(value: entry.page) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title)
                            Text(entry.page.title).font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
#endif

/// One page of Settings; Backup is the backup screen itself.
struct SettingsPageView: View {
    let page: SettingsPage

    var body: some View {
        if page == .backup {
            BackupScreen()
        } else {
            SettingsView(page: page)
        }
    }
}
