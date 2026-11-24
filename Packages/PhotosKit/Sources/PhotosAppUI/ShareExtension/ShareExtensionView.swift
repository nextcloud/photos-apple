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
    /// Shared items that could not be read, and how many were shared.
    @State private var unreadable = 0
    @State private var shared = 0
    /// Where this share's copies are; removed when it ends.
    @State private var copies = SharedItems.directory.appending(path: UUID().uuidString)
    @State private var phase: Phase = .preparing
    @State private var progress: Double = 0
    /// The uploads, once started: the system sends them in a background session of their own, and the app finishes them
    /// when this extension has ended (SPEC §7.24).
    @State private var share: ShareUploads.Share?

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
        // With app lock on, the accounts, album names and the upload need the same unlock as the app (SPEC §8).
        AppLockGate(
            cancel: {
                SharedItems.remove(copies)
                cancel()
            }, inPlace: true
        ) { form }
    }

    var form: some View {
        NavigationStack {
            Form {
                if registry.accounts.isEmpty {
                    Text("Open Nextcloud Photos and log in first.", bundle: .module)
                } else {
                    Section {
                        Text("\(files.count) items", bundle: .module)
                        if let note = SharedItems.unreadableNote(unreadable: unreadable, of: shared) {
                            Label(note, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        }
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
                    Button(String(localized: "Cancel", bundle: .module)) {
                        Task {
                            await share?.cancel()
                            SharedItems.remove(copies)
                            cancel()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if phase == .uploading {
                        // The system goes on with the uploads; the app finishes them.
                        Button(String(localized: "Continue in Background", bundle: .module)) {
                            Task {
                                await share?.leaveToApp()
                                SharedItems.remove(copies)
                                complete()
                            }
                        }
                    } else {
                        Button(uploadTitle) { Task { await upload() } }
                            .disabled(!canUpload)
                    }
                }
            }
        }
        .task {
            accountId = registry.activeAccount?.id
            // What an earlier share left behind (the extension was ended in the middle).
            SharedItems.removeLeftovers()
            let loaded = await SharedItems.load(providers, into: copies)
            files = loaded.files
            unreadable = loaded.unreadable
            shared = providers.count
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
        guard let account else { return }
        phase = .uploading
        progress = 0
        let stopped: (any Error)?
        let share: ShareUploads.Share
        do {
            if let existing = self.share {
                share = existing
                stopped = await share.retryFailed()
            } else {
                let album = albums.first { $0.id == albumId }
                share = try await ShareUploads.start(account: account, album: album)
                self.share = share
                let folder = AccountServices.loadFeatures(account.id)?.userConfig.photosLocation ?? "/Photos"
                // The copies move into the container the app shares, where they wait for the system.
                let items = files.map { (file: $0, capturedAt: CaptureDate.read($0), sameSizeIsThisFile: false) }
                stopped = try await share.upload(items, folder: folder)
            }
        } catch NetworkError.unauthorized {
            phase = .failed(String(localized: "Please log in again in Nextcloud Photos.", bundle: .module))
            return
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        if let stopped {
            phase = .failed(stopped.localizedDescription)
            return
        }
        var last: ShareUploadProgress?
        for await update in await share.progressUpdates() {
            progress = update.fraction
            last = update
            if update.isThrough { break }
        }
        if let last, last.failed > 0 {
            phase = .failed(
                last.lastFailure.map {
                    String(localized: "\(last.failed) of \(last.total) items could not be uploaded: \($0)", bundle: .module)
                }
                    ?? String(localized: "\(last.failed) of \(last.total) items could not be uploaded.", bundle: .module))
        } else {
            SharedItems.remove(copies)
            complete()
        }
    }
}

/// The temporary copies of shared items (`tmp/Share/<share>/<item>/<file name>`).
enum SharedItems {
    static var directory: URL { FileManager.default.temporaryDirectory.appending(path: "Share") }

    /// Copies of another share older than this are leftovers. A share that is still uploading is younger, or its
    /// directory would be taken away under it.
    static let leftoverAge: TimeInterval = 3600

    struct Loaded: Sendable {
        var files: [URL] = []
        /// Items that are no photo, video or file, or whose data could not be read or copied.
        var unreadable = 0
    }

    /// Removes the copies of one share (it was cancelled or is through).
    static func remove(_ copies: URL) {
        try? FileManager.default.removeItem(at: copies)
    }

    /// Removes the copies of shares that never ended (the extension was ended while it was uploading).
    static func removeLeftovers(in directory: URL = directory, olderThan age: TimeInterval = leftoverAge, now: Date = Date()) {
        let files = FileManager.default
        let contents = (try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in contents {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if now.timeIntervalSince(modified) >= age { try? files.removeItem(at: url) }
        }
    }

    /// Says how many of the shared items are missing from the upload, or nil when all were read.
    static func unreadableNote(unreadable: Int, of total: Int) -> String? {
        guard unreadable > 0 else { return nil }
        if total == 1 { return String(localized: "The item could not be read.", bundle: .module) }
        return String(localized: "\(unreadable) of \(total) items could not be read.", bundle: .module)
    }

    /// Copies shared images and videos to temporary files below `copies` and counts what could not be read.
    @MainActor static func load(_ providers: [NSItemProvider], into copies: URL) async -> Loaded {
        var loaded = Loaded()
        for provider in providers {
            guard let type = [UTType.image, .movie, .item].first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) })
            else {
                loaded.unreadable += 1
                continue
            }
            let url: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadFileRepresentation(for: type, openInPlace: false) { file, _, _ in
                    guard let file else {
                        continuation.resume(returning: nil)
                        return
                    }
                    // The file is only there until this handler returns.
                    let target = copies.appending(path: "\(UUID().uuidString)/\(file.lastPathComponent)")
                    try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if (try? FileManager.default.copyItem(at: file, to: target)) != nil {
                        continuation.resume(returning: target)
                    } else {
                        try? FileManager.default.removeItem(at: target.deletingLastPathComponent())
                        continuation.resume(returning: nil)
                    }
                }
            }
            if let url { loaded.files.append(url) } else { loaded.unreadable += 1 }
        }
        return loaded
    }
}
