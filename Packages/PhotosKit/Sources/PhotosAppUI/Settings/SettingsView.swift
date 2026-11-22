// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosModel
import PhotosStore
import SwiftUI

/// Settings (SPEC §7.25).
public struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(SessionModel.self) private var session
    @State private var addingAccount = false
    @State private var removeAccount: Account?
    @State private var newFolder = ""
    @State private var configError: String?
    @State private var cacheSize: Int64 = 0
    @State private var pins: [OfflineManager.Pin] = []
    @AppStorage("appLockEnabled") private var appLock = false
    @AppStorage("pushEnabled") private var pushEnabled = true
    @AppStorage("appLockTimeout") private var appLockTimeout = 60.0

    /// A Settings page. iOS shows all pages in one list; the macOS Settings window shows one per tab.
    public enum Page: Hashable, Sendable {
        case all, general, accounts, storage, server, about
    }

    let page: Page

    public init(page: Page = .all) {
        self.page = page
    }

    func shows(_ section: Page) -> Bool { page == .all || page == section }

    public var body: some View {
        Form {
            if shows(.accounts) {
                Section(String(localized: "Accounts", bundle: .module)) {
                    ForEach(app.accounts) { account in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(account.displayName)
                                Text(account.hostDisplayName).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if account.id == session.account.id {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            } else {
                                Button(String(localized: "Switch", bundle: .module)) { app.switchTo(account.id) }
                            }
                        }
                        .contextMenu {
                            Button(String(localized: "Remove account", bundle: .module), role: .destructive) { removeAccount = account }
                        }
                        .swipeActions {
                            Button(String(localized: "Remove", bundle: .module), role: .destructive) { removeAccount = account }
                        }
                    }
                    Button(String(localized: "Add account…", bundle: .module)) { addingAccount = true }
                }
            }

            if shows(.general) {
                Section {
                    LabeledContent(String(localized: "Timeline folders", bundle: .module)) {
                        Text(session.features.userConfig.photosSourceFolders.joined(separator: ", "))
                    }
                    HStack {
                        TextField(String(localized: "Add folder, e.g. /Camera", bundle: .module), text: $newFolder)
                            .autocorrectionDisabled()
                        Button(String(localized: "Add", bundle: .module)) { addFolder() }
                            .disabled(!newFolder.hasPrefix("/"))
                    }
                    ForEach(session.features.userConfig.photosSourceFolders, id: \.self) { folder in
                        HStack {
                            Text(folder)
                            Spacer()
                            Button(role: .destructive) {
                                removeFolder(folder)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .disabled(session.features.userConfig.photosSourceFolders.count <= 1)
                        }
                    }
                    LabeledContent(String(localized: "Upload folder", bundle: .module), value: session.features.userConfig.photosLocation)
                    Toggle(
                        String(localized: "Square tiles", bundle: .module),
                        isOn: Binding(
                            get: { !session.features.userConfig.croppedLayout },
                            set: { square in
                                Task {
                                    do { try await session.setUserConfig(.croppedLayout) { $0.croppedLayout = !square } } catch {
                                        configError = error.localizedDescription
                                    }
                                }
                            }))
                    if let configError { Text(configError).foregroundStyle(.red).font(.footnote) }
                } header: {
                    Text("Library", bundle: .module)
                } footer: {
                    Text("These settings are shared with the Photos app on the web.", bundle: .module)
                }
            }

            if shows(.general) {
                Section {
                    Toggle(String(localized: "Notifications", bundle: .module), isOn: $pushEnabled)
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
                    Text("Notifications are delivered through Nextcloud's push service.", bundle: .module)
                }
            }

            if shows(.general) {
                Section {
                    Toggle(String(localized: "Lock with Face ID or passcode", bundle: .module), isOn: $appLock)
                    if appLock {
                        Picker(String(localized: "Lock after", bundle: .module), selection: $appLockTimeout) {
                            Text("Immediately", bundle: .module).tag(0.0)
                            Text("1 minute", bundle: .module).tag(60.0)
                            Text("5 minutes", bundle: .module).tag(300.0)
                            Text("15 minutes", bundle: .module).tag(900.0)
                        }
                    }
                } header: {
                    Text("Privacy", bundle: .module)
                } footer: {
                    Text("Archived photos always need Face ID or your passcode.", bundle: .module)
                }
            }

            if shows(.storage) {
                Section(String(localized: "Storage", bundle: .module)) {
                    LabeledContent(String(localized: "Preview cache", bundle: .module), value: Formatters.bytes(cacheSize))
                    Button(String(localized: "Clear cache", bundle: .module)) {
                        session.services?.images.cache.removeAll()
                        Task { await session.services?.images.originals.removeAll() }
                        cacheSize = 0
                    }
                }
            }

            if shows(.storage) {
                Section(String(localized: "Available offline", bundle: .module)) {
                    if pins.isEmpty {
                        Text("Albums you make available offline appear here.", bundle: .module).foregroundStyle(.secondary)
                    }
                    ForEach(pins) { pin in
                        LabeledContent(pin.title, value: "\(pin.fileCount) · \(Formatters.bytes(pin.bytes))")
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

            if shows(.server) {
                Section(String(localized: "Server", bundle: .module)) {
                    LabeledContent(String(localized: "Nextcloud", bundle: .module), value: session.features.serverVersion.string)
                    if let photos = session.features.photosAppVersion {
                        LabeledContent(String(localized: "Photos app", bundle: .module), value: photos)
                    }
                    NavigationLink(String(localized: "Server features", bundle: .module)) { ServerFeaturesView() }
                    Button(String(localized: "Sync now", bundle: .module)) { Task { await session.syncNow(forceReconcile: true) } }
                        .disabled(session.syncStatus.isWorking)
                    syncStatusRow
                }
            }

            if shows(.about) {
                Section(String(localized: "About", bundle: .module)) {
                    LabeledContent(String(localized: "Version", bundle: .module), value: app.appVersion)
                    Link(
                        String(localized: "Source code", bundle: .module),
                        destination: URL(string: "https://github.com/nextcloud/photos-ios")!)
                    Link(String(localized: "Privacy", bundle: .module), destination: URL(string: "https://nextcloud.com/privacy/")!)
                    Text(
                        "Nextcloud Photos is free software under the MIT licence. It uses NextcloudKit (GPL-3.0-or-later) and GRDB (MIT).",
                        bundle: .module
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(String(localized: "Settings", bundle: .module))
        #if os(macOS)
            .frame(minWidth: 460, idealWidth: 520, minHeight: 360)
        #endif
        .task {
            cacheSize = session.services?.images.cache.totalSize() ?? 0
            pins = (try? await session.offline?.pins()) ?? []
        }
        .sheet(isPresented: $addingAccount) {
            NavigationStack { LoginView(isAddingAccount: true) }
                .frame(minWidth: 420, minHeight: 560)
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

    @ViewBuilder var syncStatusRow: some View {
        switch session.syncStatus {
        case .idle(let last), .offline(let last):
            LabeledContent(
                String(localized: "Last sync", bundle: .module), value: last?.formatted(date: .abbreviated, time: .shortened) ?? "–")
        case .initialSync(let count):
            LabeledContent(String(localized: "Loading library", bundle: .module), value: "\(count)")
        case .syncing:
            LabeledContent(String(localized: "Syncing", bundle: .module)) { ProgressView().controlSize(.small) }
        case .reconciling(let count):
            LabeledContent(String(localized: "Checking library", bundle: .module), value: "\(count)")
        case .failed(let message, _):
            Text(message).foregroundStyle(.red).font(.footnote)
        }
    }

    func addFolder() {
        let folder = newFolder.trimmingCharacters(in: .whitespaces)
        newFolder = ""
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
            Section {
                ForEach(ServerFeature.allCases, id: \.self) { feature in
                    LabeledContent(feature.displayName) {
                        Image(systemName: session.features.has(feature) ? "checkmark.circle.fill" : "minus.circle")
                            .foregroundStyle(session.features.has(feature) ? .green : .secondary)
                    }
                }
            } footer: {
                Text("Detected \(session.features.detectedAt.formatted(date: .abbreviated, time: .shortened)).", bundle: .module)
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
}

#if os(macOS)
    /// The macOS Settings window: one tab per page, like other Mac apps.
    public struct MacSettingsView: View {
        @Environment(AppModel.self) private var app

        public init() {}

        public var body: some View {
            if let session = app.session {
                TabView {
                    Tab(String(localized: "General", bundle: .module), systemImage: "gearshape") { SettingsView(page: .general) }
                    Tab(String(localized: "Accounts", bundle: .module), systemImage: "person.crop.circle") { SettingsView(page: .accounts) }
                    Tab(String(localized: "Backup", bundle: .module), systemImage: "icloud.and.arrow.up") {
                        NavigationStack { BackupScreen() }.frame(minWidth: 460, minHeight: 420)
                    }
                    Tab(String(localized: "Storage", bundle: .module), systemImage: "internaldrive") { SettingsView(page: .storage) }
                    Tab(String(localized: "Server", bundle: .module), systemImage: "server.rack") {
                        NavigationStack { SettingsView(page: .server) }
                    }
                    Tab(String(localized: "About", bundle: .module), systemImage: "info.circle") { SettingsView(page: .about) }
                }
                .environment(session)
                .scenePadding()
                .frame(width: 560, height: 520)
            } else {
                Text("Log in to Nextcloud Photos to change its settings.", bundle: .module).padding(40)
            }
        }
    }
#endif
