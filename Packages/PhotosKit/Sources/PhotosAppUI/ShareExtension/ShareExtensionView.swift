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
    /// Files an upload was started for. A second attempt must not create "name (2)" when the first one did arrive.
    @State private var attempted: Set<URL> = []

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
                                Text(verbatim: "\(account.displayName) – \(account.hostDisplayName)").tag(Optional(account.id))
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
                    Button(uploadTitle) { Task { await upload() } }
                        .disabled(!canUpload)
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

    /// After a failure the rest can be tried again.
    var canUpload: Bool {
        switch phase {
        case .ready, .failed: !files.isEmpty && account != nil
        case .preparing, .uploading: false
        }
    }

    var uploadTitle: String {
        if case .failed = phase { return String(localized: "Try again", bundle: .module) }
        return String(localized: "Upload", bundle: .module)
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
        progress = 0
        // The app's trust settings and client certificates (shared container and keychain group).
        let http = AppModel.makeHTTPClient()
        let connection = ServerConnection(
            serverURL: account.serverURL, userId: account.userId, loginName: account.loginName, appPassword: password,
            userAgent: UserAgent.make(appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"))
        let api = PhotosAPI(dav: DAVClient(http: http, connection: connection), ocs: OCSClient(http: http, connection: connection))
        // Requests are repeated after transient failures; a large file that was interrupted continues where it stopped.
        let uploader = Uploader(dav: api.dav)
        let folder = AccountServices.loadFeatures(account.id)?.userConfig.photosLocation ?? "/Photos"
        let album = albums.first { $0.id == albumId }
        let total = files.count
        let retried = attempted
        attempted.formUnion(files)
        let result = await SequentialUploads.run(files) { file in
            let uploaded = try await uploader.upload(
                file: file, fileName: file.lastPathComponent, folder: folder, capturedAt: CaptureDate.read(file),
                conflict: retried.contains(file) ? .skipIfSameSize : .rename)
            if let album { try? await api.addToAlbum(album, userPath: uploaded.path) }
        } done: { file in
            // What is uploaded leaves the list, so a second attempt only sends the rest.
            files.removeAll { $0 == file }
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
            progress = Double(total - files.count) / Double(max(total, 1))
        }
        if let error = result.error {
            phase = .failed(error.localizedDescription)
        } else {
            complete()
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
