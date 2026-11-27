// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import LocalAuthentication
import PhotosCore
import PhotosMedia
import PhotosModel
import PhotosNetworking
import PhotosStore
import SwiftUI

/// Settings (SPEC §7.25).
public struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(SessionModel.self) private var session
    @State private var addingAccount = false
    @State private var removeAccount: Account?
    @State private var pickingFolder = false
    @State private var configError: String?
    @State private var cacheSize: Int64 = 0
    /// The preview cache's limit: the user's, or scaled by the free space (SPEC §18.2).
    @State private var cacheLimit = CacheLimits.defaultPreviewBytes
    @State private var pins: [OfflineManager.Pin] = []
    @State private var reviewedCertificate: CertificateProblem?
    /// Import Library… (iPhone, iPad, Vision Pro; the Mac has it in the File menu).
    @State private var importingLibrary = false
    /// In the App Group: the widgets and the share extension follow it.
    @AppStorage(AppLockSettings.enabledKey, store: AppLockSettings.defaults) private var appLock = false
    @AppStorage(OfflineManager.wifiOnlyKey) private var offlineWifiOnly = true
    @AppStorage(AppLockSettings.timeoutKey, store: AppLockSettings.defaults) private var appLockTimeout = AppLockSettings.defaultTimeout

    /// The page shown: one of the pages, or the list of pages (SPEC §20.4).
    let page: SettingsPage

    public init(page: SettingsPage = .all) {
        self.page = page
    }

    /// "1.2 GB, up to 2 GB".
    private var cacheUsage: String {
        let used = Formatters.bytes(cacheSize)
        let limit = Formatters.bytes(cacheLimit)
        return String(
            localized: "\(used), up to \(limit)", bundle: .module,
            comment: "Settings › Storage, the preview cache: its size and its limit, e.g. \"1.2 GB, up to 2 GB\".")
    }

    public var body: some View {
        #if os(macOS)
            form
        #else
            if page == .all { SettingsHome() } else { form }
        #endif
    }

    /// The page's sections.
    @ViewBuilder var sections: some View {
        switch page {
        case .all:
            // A link to Settings opened in a window (Mac): the list of pages.
            ForEach(SettingsPage.shown) { (page: SettingsPage) in
                NavigationLink(page.title) { SettingsPageView(page: page) }
            }
        case .accounts: accountsSections
        case .library: librarySections
        case .notifications: notificationsSections
        case .general:
            librarySections
            notificationsSections
        case .backup: EmptyView()
        case .storage: storageSections
        case .privacy: privacySections
        case .desktop: EmptyView()
        case .advanced: advancedSections
        case .about: aboutSection
        }
    }

    var form: some View {
        Form {
            sections
        }
        .formStyle(.grouped)
        .navigationTitle(title)
        #if os(macOS)
            // As tall as its content (up to a limit, then it scrolls): the Settings window follows the selected tab.
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: MacSettingsLayout.width)
            .frame(maxHeight: MacSettingsLayout.maxHeight)
            .fixedSize(horizontal: false, vertical: true)
        #endif
        .sheet(isPresented: $pickingFolder) {
            ServerFolderPicker(excluded: session.features.userConfig.photosSourceFolders) { folder in addFolder(folder) }
        }
        .task {
            cacheSize = session.services?.images.cache.totalSize() ?? 0
            cacheLimit = CacheLimits.current().previewBytes
            pins = (try? await session.offline?.pins()) ?? []
        }
        .sheet(isPresented: $addingAccount) { AddAccountSheet() }
        .certificateReview($reviewedCertificate) { problem in
            Task { await session.trust(problem) }
        }
        .confirmationDialog(
            String(localized: "Remove this account?", bundle: .module),
            isPresented: Binding(get: { removeAccount != nil }, set: { if !$0 { removeAccount = nil } }), titleVisibility: .visible
        ) {
            Button(String(localized: "Remove account", bundle: .module), role: .destructive) {
                if let account = removeAccount { Task { await app.removeAccount(account.id) } }
            }
        } message: {
            Text(
                "The app's access to the account is revoked and all its data is removed from this device. Nothing is deleted on the server.",
                bundle: .module)
        }
    }

    // MARK: Pages

    /// Accounts, then the server of the account shown and its sync.
    @ViewBuilder var accountsSections: some View {
        Section(String(localized: "Accounts", bundle: .module)) {
            ForEach(app.accounts) { account in
                HStack {
                    // Name and server are read together, then whether it is the account shown.
                    VStack(alignment: .leading) {
                        Text(account.displayName)
                        Text(account.hostDisplayName).font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    // The check mark is part of this element, not a tiny one of its own (SPEC §20.3).
                    .accessibilityValue(
                        account.id == session.account.id ? Text("Current account", bundle: .module) : Text(verbatim: "")
                    )
                    .accessibilityAddTraits(account.id == session.account.id ? .isSelected : [])
                    Spacer()
                    if account.id == session.account.id {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                            .accessibilityHidden(true)
                    } else {
                        Button(String(localized: "Switch", bundle: .module)) { app.switchTo(account.id) }
                            .buttonStyle(.borderless)
                    }
                    // Visible, not only in the context menu or behind a swipe. Asks before anything happens.
                    Button(String(localized: "Log out…", bundle: .module), role: .destructive) { removeAccount = account }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text("Log out \(account.displayName)", bundle: .module))
                }
                .contextMenu {
                    Button(String(localized: "Remove account", bundle: .module), role: .destructive) { removeAccount = account }
                }
                .swipeActions {
                    Button(String(localized: "Remove", bundle: .module), role: .destructive) { removeAccount = account }
                }
            }
            if app.canAddAccount {
                Button(String(localized: "Add account…", bundle: .module)) { addingAccount = true }
            }
        }
        Section(String(localized: "Server", bundle: .module)) {
            LabeledContent(String(localized: "Nextcloud", bundle: .module), value: session.features.serverVersion.string)
            if let photos = session.features.photosAppVersion {
                LabeledContent(String(localized: "Photos app", bundle: .module), value: photos)
            }
            LabeledContent(
                String(localized: "Photos features", bundle: .module),
                value: session.features.hasExtendedFeatures
                    ? String(localized: "Extended", bundle: .module) : String(localized: "Standard", bundle: .module))
            NavigationLink(String(localized: "Server features", bundle: .module)) { ServerFeaturesView() }
            Button(String(localized: "Sync now", bundle: .module)) { Task { await session.syncNow(forceReconcile: true) } }
                .disabled(session.syncStatus.isWorking)
            syncStatusRow
            accountStateRows
        }
    }

    /// What the library shows and how, and with whom it is shared.
    @ViewBuilder var librarySections: some View {
        Section {
            ForEach(session.features.userConfig.photosSourceFolders, id: \.self) { folder in
                HStack {
                    Label(folder, systemImage: "folder")
                    Spacer()
                    Button(role: .destructive) {
                        removeFolder(folder)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(session.features.userConfig.photosSourceFolders.count <= 1)
                    .accessibilityLabel(Text("Remove \(folder)", bundle: .module))
                    .help(String(localized: "Remove \(folder)", bundle: .module))
                }
            }
            // A picker over the server's folders, not a path to type.
            Button(
                PlatformWording.title(
                    mac: LocalizedStringResource("Add Folder…", bundle: .module),
                    other: LocalizedStringResource("Add folder…", bundle: .module))
            ) { pickingFolder = true }
            if let configError { Text(configError).foregroundStyle(.red).font(.footnote) }
        } header: {
            Text("Timeline folders", bundle: .module)
        } footer: {
            Text("Photos and videos in these folders of your Nextcloud appear in the library.", bundle: .module)
        }
        Section {
            LabeledContent(String(localized: "Upload folder", bundle: .module), value: session.features.userConfig.photosLocation)
            #if !os(macOS)
                Button {
                    importingLibrary = true
                } label: {
                    Label(
                        String(
                            localized: "Import from Other Services…", bundle: .module,
                            comment: "Settings row that opens the import of Google Photos, iCloud, Facebook and Instagram exports."),
                        systemImage: "square.and.arrow.down.on.square")
                }
                .sheet(isPresented: $importingLibrary) { ImportLibrarySheet() }
            #endif
        } header: {
            Text("Library", bundle: .module)
        } footer: {
            Text("These settings are shared with the Photos app on the web.", bundle: .module)
        }
        TimelineDisplaySection()
        // Colour from photos, moving covers (SPEC §16.8).
        LookSettingsSection()
        // Sharing and family (SPEC §16.7).
        PartnerSharingSection()
        FamilyLibrarySettingsSection()
        LockScreenAlbumSettingsSection()
        // Settings › Show Tips (SPEC §22.2).
        TipsSettingsSection()
    }

    @ViewBuilder var notificationsSections: some View {
        Section {
            // Off unregisters this device on the server and the push service; on asks for permission and registers.
            Toggle(
                String(localized: "Notifications", bundle: .module),
                isOn: Binding(get: { app.pushEnabled }, set: { value in Task { await app.setPushEnabled(value) } }))
            if session.features.has(.onThisDayNotifications) {
                Toggle(
                    String(localized: "On this day", bundle: .module),
                    isOn: Binding(
                        get: { session.features.userConfig.onThisDayNotifications ?? true },
                        set: { value in
                            Task { try? await session.setUserConfig(.onThisDayNotifications) { $0.onThisDayNotifications = value } }
                        }))
            }
        } header: {
            Text("Notifications", bundle: .module)
        } footer: {
            if session.features.has(.notifications) {
                Text("Notifications are delivered through Nextcloud's push service.", bundle: .module)
            } else {
                Text(
                    "Notifications are delivered through Nextcloud's push service. This server has no Notifications app, so it doesn't send any.",
                    bundle: .module)
            }
        }
        SearchAndActivitySettings(part: .sharedAlbums)
        PhotoOfTheDaySettingsSection()
        WeeklyPromptSettingsSection()
    }

    @ViewBuilder var storageSections: some View {
        Section(String(localized: "Storage", bundle: .module)) {
            LabeledContent(String(localized: "Preview cache", bundle: .module), value: cacheUsage)
            Button(String(localized: "Clear cache", bundle: .module)) {
                session.services?.images.cache.removeAll()
                Task { await session.services?.images.originals.removeAll() }
                cacheSize = 0
            }
            NavigationLink(CacheDiagnosticsView.title) { CacheDiagnosticsView() }
        }
        LibraryThumbnailsSettingsSection()
        SmartOfflineSettingsSection()
        Section(String(localized: "Available offline", bundle: .module)) {
            Toggle(String(localized: "Download only on Wi-Fi", bundle: .module), isOn: $offlineWifiOnly)
                .onChange(of: offlineWifiOnly) { _, _ in Task { await session.offline?.syncPins() } }
            if pins.isEmpty {
                Text("Albums you make available offline appear here.", bundle: .module).foregroundStyle(.secondary)
            }
            ForEach(pins) { pin in
                LabeledContent(
                    pin.title,
                    value: String(localized: "\(pin.fileCount) files · \(Formatters.bytes(pin.bytes))", bundle: .module))
            }
            if !pins.isEmpty {
                Button(String(localized: "Remove all offline files", bundle: .module), role: .destructive) {
                    Task {
                        try? await session.offline?.removeAll()
                        pins = []
                    }
                }
            }
        }
    }

    /// App lock, and what the app works out about the photos on this device.
    @ViewBuilder var privacySections: some View {
        Section {
            Toggle(DeviceLockWording.current.toggleTitle, isOn: $appLock)
                // Required by the organisation (SPEC §5.1.9): on, and it can't be turned off.
                .disabled(app.managed.enforcesAppLock)
                // Widgets show a placeholder instead of photos while app lock is on.
                .onChange(of: appLock) { _, _ in
                    AppLock.shared.settingChanged()
                    app.reloadWidgets()
                    // Nothing in Spotlight while app lock is on; indexed again when it is turned off.
                    Task { await session.updateSpotlight(force: true) }
                    // The photo of the day shows no photo while app lock is on.
                    Task { await session.photoOfTheDaySettingsChanged() }
                }
            if appLock {
                Picker(String(localized: "Lock after", bundle: .module), selection: $appLockTimeout) {
                    Text("Immediately", bundle: .module).tag(0.0)
                    Text("1 minute", bundle: .module).tag(60.0)
                    Text("5 minutes", bundle: .module).tag(300.0)
                    Text("15 minutes", bundle: .module).tag(900.0)
                }
            }
        } header: {
            Text("App lock", bundle: .module, comment: "Settings › Privacy & security: section of the app lock.")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if app.managed.enforcesAppLock { Text(ManagedWording.appLockRequired) }
                Text(DeviceLockWording.current.archiveNote)
            }
        }
        SearchAndActivitySettings(part: .analysis)
    }

    /// The niche features, the tools that change the server's files, and what helps when something goes wrong.
    @ViewBuilder var advancedSections: some View {
        AdvancedFeaturesSection()
        // Folder rules, smart albums, GPS track (SPEC §16.4).
        OrganizeSettingsSection()
        #if os(macOS)
            // The menu bar extra (SPEC §16.5.4).
            MenuBarExtraSection()
        #endif
        DiagnosticsSection()
    }

    var aboutSection: some View {
        Section(String(localized: "About", bundle: .module)) {
            LabeledContent(String(localized: "Version", bundle: .module), value: app.appVersion)
            Link(
                String(localized: "Source code", bundle: .module),
                destination: URL(string: "https://github.com/nextcloud/photos-apple")!)
            Link(String(localized: "Privacy", bundle: .module), destination: URL(string: "https://nextcloud.com/privacy/")!)
            NavigationLink(String(localized: "Licences", bundle: .module)) { LicensesView() }
            Text(
                "Nextcloud Photos is free software under the MIT licence. It uses GRDB (MIT).",
                bundle: .module
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    /// The sync's state with one symbol for all of them: the arrows turn while it syncs and become a check mark when it
    /// is through; the counts roll (SPEC §17.3).
    @ViewBuilder var syncStatusRow: some View {
        switch session.syncStatus {
        case .failed(let message, _):
            LabeledContent {
                Button(String(localized: "Retry", bundle: .module)) { Task { await session.syncNow() } }
            } label: {
                Text("Couldn't sync", bundle: .module)
                Text(message).foregroundStyle(.red)
            }
        default:
            let row: SyncStatusRow = SyncStatusRow(session.syncStatus)
            LabeledContent {
                HStack(spacing: 8) {
                    if let count = row.count {
                        Text(count.formatted()).rollingNumber(count)
                    } else if let value = row.value {
                        Text(value)
                    }
                    ChromeStatusSymbol(kind: .sync, state: row.symbol)
                }
            } label: {
                Text(row.title)
            }
        }
    }

    /// What is wrong with the account itself: its server's certificate changed, or its login was revoked.
    @ViewBuilder var accountStateRows: some View {
        if let problem = session.certificateProblem {
            LabeledContent {
                Button(String(localized: "Review…", bundle: .module)) { reviewedCertificate = problem }
            } label: {
                Label(
                    String(localized: "The server's certificate changed", bundle: .module),
                    systemImage: "lock.trianglebadge.exclamationmark")
                Text("Nothing is synced until you have reviewed and trusted the new certificate.", bundle: .module)
            }
        }
        if session.isSignedOut {
            LabeledContent {
                Button(String(localized: "Log in again", bundle: .module)) { addingAccount = true }
            } label: {
                Label(String(localized: "Signed out", bundle: .module), systemImage: "person.crop.circle.badge.exclamationmark")
                SignedOutView.reason(session)
            }
        }
    }

    /// The Mac's Settings window is titled after the selected tab; elsewhere this is the page's title.
    var title: String { page.title }

    func addFolder(_ folder: String) {
        Task {
            do {
                try await session.setUserConfig(.photosSourceFolders) { config in
                    if !config.photosSourceFolders.contains(folder) { config.photosSourceFolders.append(folder) }
                }
            } catch { configError = error.localizedDescription }
        }
    }

    func removeFolder(_ folder: String) {
        Task {
            do {
                try await session.setUserConfig(.photosSourceFolders) { $0.photosSourceFolders.removeAll { $0 == folder } }
            } catch { configError = error.localizedDescription }
        }
    }
}

/// Diagnostics: which optional server features were detected.
struct ServerFeaturesView: View {
    @Environment(SessionModel.self) private var session

    var body: some View {
        List {
            if let error = session.featureDetectionError {
                Section { Text(error).foregroundStyle(.red) }
            }
            ForEach(ServerFeature.Origin.allCases, id: \.self) { origin in
                Section {
                    ForEach(ServerFeature.allCases.filter { $0.origin == origin }, id: \.self) { feature in
                        LabeledContent(feature.localizedName) {
                            Image(systemName: session.features.has(feature) ? "checkmark.circle.fill" : "minus.circle")
                                .foregroundStyle(session.features.has(feature) ? .green : .secondary)
                                .accessibilityLabel(
                                    session.features.has(feature)
                                        ? Text("Available", bundle: .module) : Text("Not available", bundle: .module))
                        }
                    }
                } header: {
                    Text(Self.title(of: origin))
                } footer: {
                    if origin == .extended && !session.features.hasExtendedFeatures {
                        Text(
                            "This server runs the standard Photos app. Features of newer Photos versions appear here and in the app as soon as the server offers them.",
                            bundle: .module)
                    } else if origin == ServerFeature.Origin.allCases.last {
                        Text(
                            "Detected \(session.features.detectedAt.formatted(date: .abbreviated, time: .shortened)).", bundle: .module)
                    }
                }
            }
            Section(String(localized: "Media types", bundle: .module)) {
                Text(session.features.allMimeTypes.joined(separator: ", ")).font(.footnote)
            }
        }
        .navigationTitle(String(localized: "Server features", bundle: .module))
        .toolbar {
            Button(String(localized: "Detect again", bundle: .module)) { Task { await session.refreshFeatures() } }
        }
    }

    static func title(of origin: ServerFeature.Origin) -> String {
        switch origin {
        case .core: String(localized: "Nextcloud and Photos", bundle: .module)
        case .extended: String(localized: "Newer Photos versions", bundle: .module)
        case .assistant: String(localized: "Assistant", bundle: .module)
        case .companion: String(localized: "Additional server APIs", bundle: .module)
        }
    }
}

/// How the device unlocks, for the wording of the app lock (Touch ID and a password on a Mac, Face ID and a passcode on an iPhone…).
enum DeviceLockWording: Equatable {
    case faceID, touchID, opticID
    /// No biometry: only the passcode (iPhone, iPad, Vision Pro) or the login password (Mac).
    case none

    static var current: DeviceLockWording {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return DeviceLockWording(context.biometryType)
    }

    init(_ type: LABiometryType) {
        switch type {
        case .faceID: self = .faceID
        case .touchID: self = .touchID
        case .opticID: self = .opticID
        default: self = .none
        }
    }

    var toggleTitle: String {
        #if os(macOS)
            switch self {
            case .touchID: String(localized: "Lock with Touch ID or password", bundle: .module)
            default: String(localized: "Lock with your password", bundle: .module)
            }
        #else
            switch self {
            case .faceID: String(localized: "Lock with Face ID or passcode", bundle: .module)
            case .touchID: String(localized: "Lock with Touch ID or passcode", bundle: .module)
            case .opticID: String(localized: "Lock with Optic ID or passcode", bundle: .module)
            case .none: String(localized: "Lock with passcode", bundle: .module)
            }
        #endif
    }

    var archiveNote: String {
        #if os(macOS)
            switch self {
            case .touchID: String(localized: "Archived photos always need Touch ID or your password.", bundle: .module)
            default: String(localized: "Archived photos always need your password.", bundle: .module)
            }
        #else
            switch self {
            case .faceID: String(localized: "Archived photos always need Face ID or your passcode.", bundle: .module)
            case .touchID: String(localized: "Archived photos always need Touch ID or your passcode.", bundle: .module)
            case .opticID: String(localized: "Archived photos always need Optic ID or your passcode.", bundle: .module)
            case .none: String(localized: "Archived photos always need your passcode.", bundle: .module)
            }
        #endif
    }
}

/// Picks a folder of the user's Nextcloud by browsing it (Settings → Timeline folders, the backup folder).
struct ServerFolderPicker: View {
    /// Folders that are already chosen; they cannot be picked again.
    var excluded: [String] = []
    /// The confirming button; "Add This Folder" when nil.
    var confirmTitle: String?
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            ServerFolderList(folder: "/", excluded: excluded, confirmTitle: confirmTitle, pick: pick, cancel: { dismiss() })
                .navigationDestination(for: String.self) { folder in
                    ServerFolderList(folder: folder, excluded: excluded, confirmTitle: confirmTitle, pick: pick, cancel: { dismiss() })
                }
        }
        .sheetMinimumSize(width: 420, height: 440)
    }

    func pick(_ folder: String) {
        onPick(folder)
        dismiss()
    }
}

/// One level of the server's folder tree.
struct ServerFolderList: View {
    let folder: String
    let excluded: [String]
    var confirmTitle: String?
    let pick: (String) -> Void
    let cancel: () -> Void
    @Environment(SessionModel.self) private var session
    @State private var folders: [FolderEntry] = []
    @State private var loaded = false
    @State private var error: String?

    var title: String {
        folder == "/" ? String(localized: "All files", bundle: .module) : (folder as NSString).lastPathComponent
    }

    var body: some View {
        List(folders) { entry in
            NavigationLink(value: entry.path) {
                Label(entry.name, systemImage: "folder")
            }
        }
        .overlay {
            if !loaded {
                SkeletonRows(count: 6, thumbnail: 24).frame(maxHeight: .infinity, alignment: .top)
            } else if let error {
                ContentUnavailableView(
                    String(localized: "Couldn't load folders", bundle: .module), systemImage: "exclamationmark.triangle",
                    description: Text(error))
            } else if folders.isEmpty {
                ContentUnavailableView(String(localized: "No subfolders", bundle: .module), systemImage: "folder")
            }
        }
        .navigationTitle(title)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Label(folder, systemImage: "folder").lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Spacer()
            }
            .font(.callout)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "Cancel", bundle: .module)) { cancel() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(confirmTitle ?? String(localized: "Add This Folder", bundle: .module)) { pick(folder) }
                    .disabled(folder == "/" || excluded.contains(folder))
            }
        }
        .task {
            guard let services = session.services else { return }
            do {
                // All subfolders are offered, also those without media in them yet.
                folders = try await services.api.folder(folder, mimeTypes: [], nomedia: []).folders
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            } catch {
                self.error = error.localizedDescription
            }
            loaded = true
        }
    }
}

#if os(macOS)
    enum MacSettingsLayout {
        static let width: CGFloat = 560
        static let maxHeight: CGFloat = 640
    }

    /// The macOS Settings window: one tab per page, like other Mac apps. The window is titled after the selected tab and is
    /// as tall as that tab's content.
    public struct MacSettingsView: View {
        @Environment(AppModel.self) private var app
        /// The selected tab; the command palette sets it before it opens the window (SPEC §16.2).
        @AppStorage(MacSettingsPage.storageKey) private var page = MacSettingsPage.general.rawValue

        public init() {}

        /// The selected tab; a tab of an earlier version (Server) opens the one that has its settings now.
        var selection: Binding<String> {
            Binding(get: { MacSettingsPage(stored: page).rawValue }, set: { page = $0 })
        }

        @ViewBuilder func content(_ tab: MacSettingsPage) -> some View {
            switch tab {
            case .backup: NavigationStack { BackupScreen() }.frame(width: MacSettingsLayout.width, height: 440)
            // Desktop pictures from the library (SPEC §15.4).
            case .desktop: DesktopPictureSettingsPane()
            // In a stack: Server features, Cache diagnostics and Licences are pushed.
            default: NavigationStack { SettingsView(page: tab.page) }
            }
        }

        public var body: some View {
            // The Settings window is a window of its own: it needs the lock too, and shows nothing in Guest Mode.
            AppLockGate {
                if GuestMode.shared.isActive { GuestModeCover().frame(width: 360, height: 240) } else { settings }
            }
        }

        @ViewBuilder var settings: some View {
            if let session = app.session {
                TabView(selection: selection) {
                    ForEach(MacSettingsPage.allCases, id: \.self) { (tab: MacSettingsPage) in
                        Tab(tab.page.title, systemImage: tab.page.systemImage, value: tab.rawValue) {
                            content(tab)
                        }
                    }
                }
                .environment(session)
            } else {
                Text("Log in to Nextcloud Photos to change its settings.", bundle: .module).padding(40)
            }
        }
    }
#endif

/// What Settings › Server says about the sync, without its failure (SPEC §17.3).
struct SyncStatusRow: Equatable {
    var title: String
    /// A count that rolls (items loaded, checked).
    var count: Int?
    /// Or a text (the time of the last sync).
    var value: String?
    var symbol: ChromeSymbolState

    init(_ status: SyncStatus) {
        switch status {
        case .idle(let last), .offline(let last):
            title = String(localized: "Last sync", bundle: .module)
            value = last?.formatted(date: .abbreviated, time: .shortened) ?? "–"
            if case .idle = status, last != nil { symbol = .done } else { symbol = .idle }
        case .initialSync(let count):
            title = String(localized: "Loading library", bundle: .module)
            self.count = count
            symbol = .working
        case .syncing:
            title = String(localized: "Syncing", bundle: .module)
            symbol = .working
        case .reconciling(let count):
            title = String(localized: "Checking library", bundle: .module)
            self.count = count
            symbol = .working
        case .failed:
            title = String(localized: "Couldn't sync", bundle: .module)
            symbol = .failed
        }
    }
}
