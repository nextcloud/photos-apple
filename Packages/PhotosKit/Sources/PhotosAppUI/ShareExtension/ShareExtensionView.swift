// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosCore
import PhotosModel
import PhotosNetworking
import PhotosStore
import SwiftUI
import UniformTypeIdentifiers

/// UI of the share extension: upload shared photos and videos to Nextcloud, optionally into an album (SPEC §7.24).
public struct ShareExtensionView: View {
    let providers: [NSItemProvider]
    let complete: @MainActor () -> Void
    let cancel: @MainActor () -> Void

    @State private var registry = AccountRegistry.load()
    @State private var accountId: AccountID?
    @State private var albums: [Album] = []
    @State private var albumId: String = ""
    @State private var files: [URL] = []
    @State private var phase: Phase = .preparing
    @State private var progress: Double = 0

    enum Phase: Equatable {
        case preparing
        case ready
        case uploading
        case failed(String)
    }

    public init(providers: [NSItemProvider], complete: @escaping @MainActor () -> Void, cancel: @escaping @MainActor () -> Void) {
        self.providers = providers
        self.complete = complete
        self.cancel = cancel
    }

    var account: Account? { registry.accounts.first { $0.id == accountId } ?? registry.activeAccount }

    public var body: some View {
        NavigationStack {
            Form {
                if registry.accounts.isEmpty {
                    Text("Open Nextcloud Photos and log in first.", bundle: .module)
                } else {
                    Section {
                        Text("\(files.count) items", bundle: .module)
                        Picker(String(localized: "Account", bundle: .module), selection: $accountId) {
                            ForEach(registry.accounts) { account in
                                Text("\(account.displayName) – \(account.hostDisplayName)").tag(Optional(account.id))
                            }
                        }
                        Picker(String(localized: "Album", bundle: .module), selection: $albumId) {
                            Text("No album", bundle: .module).tag("")
                            ForEach(albums) { album in Text(album.title).tag(album.id) }
                        }
                    } footer: {
                        Text(
                            "Uploaded to \(AccountServices.loadFeatures(account?.id ?? AccountID(rawValue: ""))?.userConfig.photosLocation ?? "/Photos").",
                            bundle: .module)
                    }
                    switch phase {
                    case .uploading: ProgressView(value: progress)
                    case .failed(let message): Text(message).foregroundStyle(.red)
                    default: EmptyView()
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(String(localized: "Nextcloud Photos", bundle: .module))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", bundle: .module)) { cancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Upload", bundle: .module)) { Task { await upload() } }
                        .disabled(phase != .ready || files.isEmpty || account == nil)
                }
            }
        }
        .task {
            accountId = registry.activeAccount?.id
            files = await Self.loadFiles(providers)
            phase = .ready
        }
        .task(id: accountId) { loadAlbums() }
    }

    func loadAlbums() {
        guard let account, let database = try? AccountDatabase(url: AppPaths.database(account.id)) else {
            albums = []
            return
        }
        albums = (try? CollectionStore(database: database).albums(.own)) ?? []
    }

    func upload() async {
        guard let account, let password = Keychain().string(for: Keychain.passwordKey(account.id.rawValue)) else {
            phase = .failed(String(localized: "Please log in again in Nextcloud Photos.", bundle: .module))
            return
        }
        phase = .uploading
        let http = HTTPClient(trustStore: TrustStore(directory: AppPaths.certificates))
        let connection = ServerConnection(
            serverURL: account.serverURL, userId: account.userId, loginName: account.loginName, appPassword: password,
            userAgent: UserAgent.make(appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"))
        let api = PhotosAPI(dav: DAVClient(http: http, connection: connection), ocs: OCSClient(http: http, connection: connection))
        let uploader = Uploader(dav: api.dav)
        let folder = AccountServices.loadFeatures(account.id)?.userConfig.photosLocation ?? "/Photos"
        let album = albums.first { $0.id == albumId }
        do {
            for (index, file) in files.enumerated() {
                let uploaded = try await uploader.upload(
                    file: file, fileName: file.lastPathComponent, folder: folder, capturedAt: CaptureDate.read(file))
                if let album { try? await api.addToAlbum(album, userPath: uploaded.path) }
                progress = Double(index + 1) / Double(files.count)
                try? FileManager.default.removeItem(at: file)
            }
            complete()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Copies shared images and videos to temporary files.
    static func loadFiles(_ providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            guard let type = [UTType.image, .movie, .item].first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) })
            else { continue }
            let url: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadFileRepresentation(for: type, openInPlace: false) { file, _, _ in
                    guard let file else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let target = FileManager.default.temporaryDirectory.appending(
                        path: "Share/\(UUID().uuidString)/\(file.lastPathComponent)")
                    try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    continuation.resume(returning: (try? FileManager.default.copyItem(at: file, to: target)) != nil ? target : nil)
                }
            }
            if let url { urls.append(url) }
        }
        return urls
    }
}
