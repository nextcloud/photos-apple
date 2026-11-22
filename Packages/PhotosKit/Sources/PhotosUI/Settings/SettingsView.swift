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

    public init() {}

    public var body: some View {
        Form {
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

            Section(String(localized: "Storage", bundle: .module)) {
                LabeledContent(String(localized: "Preview cache", bundle: .module), value: Formatters.bytes(cacheSize))
                Button(String(localized: "Clear cache", bundle: .module)) {
                    session.services?.images.cache.removeAll()
                    Task { await session.services?.images.originals.removeAll() }
                    cacheSize = 0
                }
            }

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

            Section(String(localized: "About", bundle: .module)) {
                LabeledContent(String(localized: "Version", bundle: .module), value: app.appVersion)
                Link(
                    String(localized: "Source code", bundle: .module), destination: URL(string: "https://github.com/nextcloud/photos-ios")!)
                Link(String(localized: "Privacy", bundle: .module), destination: URL(string: "https://nextcloud.com/privacy/")!)
                Text(
                    "Nextcloud Photos is free software under the MIT licence. It uses NextcloudKit (GPL-3.0-or-later) and GRDB (MIT).",
                    bundle: .module
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(String(localized: "Settings", bundle: .module))
        .task { cacheSize = session.services?.images.cache.totalSize() ?? 0 }
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
