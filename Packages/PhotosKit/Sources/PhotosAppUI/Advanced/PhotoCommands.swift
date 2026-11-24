// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Observation
import PhotosCore
import PhotosDomain
import PhotosMedia
import PhotosModel
import SwiftUI
import UniformTypeIdentifiers

#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

// MARK: - Rotate and Copy on a selection (SPEC §6.2: Image ▸ Rotate, Edit ▸ Copy)

/// Image ▸ Rotate Left/Right outside the editor. Saves like the editor's "Overwrite original" (`PhotoEditSaving`): a new
/// version of the file; photos in read-only shares and formats that can't be written back are left as they are and
/// reported.
enum PhotoRotation {
    /// The selection can be rotated: at least one photo in it can be changed in place.
    static func canRotate(_ items: [MediaItem]) -> Bool {
        items.contains { PhotoEditSaving.overwriteProblem($0) == nil }
    }

    /// The photos of the selection (videos are not rotated, as in Photos).
    static func photos(_ items: [MediaItem]) -> [MediaItem] {
        items.filter { $0.kind == .image }
    }

    static func edits(clockwise: Bool) -> PhotoEdits {
        var edits = PhotoEdits()
        edits.rotate(clockwise: clockwise)
        return edits
    }
}

/// Edit ▸ Copy of photos: the originals are downloaded and put on the pasteboard as image data (photos) and as files, so
/// they paste into documents and mail as pictures and into Finder or Files as files.
enum PhotoClipboard {
    /// More at once would download and hold too much; Export is the way for large selections.
    static let limit = 100

    enum Failure: LocalizedError {
        case tooMany

        var errorDescription: String? {
            String(
                localized: "Up to \(PhotoClipboard.limit) items can be copied at once. Use Export for more.", bundle: .module,
                comment: "Edit › Copy of photos with a too large selection.")
        }
    }

    /// Where the copied files live until the next copy (pasting in Finder copies them from here).
    static var directory: URL { FileManager.default.temporaryDirectory.appending(path: "Clipboard") }

    /// A fresh folder for this copy; the files of the previous one are removed.
    static func prepareDirectory() throws -> URL {
        try? FileManager.default.removeItem(at: directory)
        let folder = directory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// The original under its own name in `folder`.
    static func namedCopy(of item: MediaItem, in folder: URL, services: AccountServices) async throws -> URL {
        let original = try await services.images.originals.original(
            fileId: item.fileId, etag: item.etag, url: services.originalURL(for: item))
        try Task.checkCancellation()
        let target = MediaFileNaming.freeURL(for: item.name, in: folder)
        try FileManager.default.copyItem(at: original, to: target)
        return target
    }

    /// The type of a file the pasteboard is told, from its name, else its MIME type.
    static func type(of item: MediaItem) -> UTType {
        UTType(filenameExtension: (item.name as NSString).pathExtension) ?? UTType(mimeType: item.mimeType)
            ?? (item.kind == .video ? .movie : .image)
    }

    /// Puts the downloaded files on the general pasteboard: photos with their data and their file, videos as files.
    @MainActor static func write(_ files: [(item: MediaItem, url: URL)]) {
        #if canImport(UIKit)
            let providers: [NSItemProvider] = files.map { file in
                let provider = NSItemProvider(contentsOf: file.url) ?? NSItemProvider()
                provider.suggestedName = file.item.name
                return provider
            }
            UIPasteboard.general.setItemProviders(providers, localOnly: false, expirationDate: nil)
        #else
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            let entries: [NSPasteboardItem] = files.map { file in
                let entry = NSPasteboardItem()
                if file.item.kind == .image, let data = try? Data(contentsOf: file.url, options: .mappedIfSafe) {
                    entry.setData(data, forType: NSPasteboard.PasteboardType(type(of: file.item).identifier))
                }
                entry.setString(file.url.absoluteString, forType: .fileURL)
                return entry
            }
            pasteboard.writeObjects(entries)
        #endif
    }
}

/// Originals for the system share menu and sheet, downloaded only when a share service asks for them.
enum MediaItemProviders {
    static func make(_ items: [MediaItem], services: AccountServices) -> [NSItemProvider] {
        items.map { provider(for: $0, services: services) }
    }

    static func provider(for item: MediaItem, services: AccountServices) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = item.name
        let type = PhotoClipboard.type(of: item)
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            let progress = Progress(totalUnitCount: 1)
            let task = Task {
                do {
                    let folder = FileManager.default.temporaryDirectory.appending(path: "Share/\(UUID().uuidString)")
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let file = try await PhotoClipboard.namedCopy(of: item, in: folder, services: services)
                    progress.completedUnitCount = 1
                    completion(file, false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            progress.cancellationHandler = { task.cancel() }
            return progress
        }
        return provider
    }
}

/// What a rotate or a copy did, for the status banner and the alert.
struct PhotoTaskResult: Equatable {
    enum Kind: Equatable {
        case rotate, copy
    }

    var kind: Kind
    var run: MediaSaveResult

    var confirmation: String? {
        let done = run.saved
        guard done > 0 else { return nil }
        switch kind {
        case .rotate:
            return done == run.total
                ? String(localized: "Rotated \(done) photos", bundle: .module, comment: "Status after Image › Rotate.")
                : String(localized: "Rotated \(done) of \(run.total) photos", bundle: .module, comment: "Status after Image › Rotate.")
        case .copy:
            return String(localized: "Copied \(done) items", bundle: .module, comment: "Status after Edit › Copy of photos.")
        }
    }

    var failureTitle: String {
        switch kind {
        case .rotate: String(localized: "Couldn't rotate", bundle: .module)
        case .copy: String(localized: "Couldn't copy", bundle: .module)
        }
    }

    /// The reasons, each said once ("2 photos were not rotated. The photo is shared with you without permission…").
    var failureMessage: String? {
        guard let first = run.failures.first else { return nil }
        let reasons: [String] = run.failures.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        let count = run.failed
        let summary: String =
            switch kind {
            case .rotate: String(localized: "\(count) photos were not rotated.", bundle: .module)
            case .copy: String(localized: "\(count) items could not be copied.", bundle: .module)
            }
        return reasons.count == 1 ? "\(summary) \(first)" : summary
    }
}

/// Runs Rotate and Copy on a selection with progress, Cancel and a result, like `MediaSaveModel` does for Export.
@MainActor
@Observable
final class PhotoTaskModel {
    struct Progress: Equatable {
        var kind: PhotoTaskResult.Kind
        var done: Int
        var total: Int
    }

    private(set) var progress: Progress?
    private(set) var result: PhotoTaskResult?
    @ObservationIgnored private var task: Task<Void, Never>?

    var isRunning: Bool { task != nil }

    /// Rotates the photos of `items` a quarter turn, each saved as a new version of its file; then syncs.
    func rotate(_ items: [MediaItem], clockwise: Bool, session: SessionModel) {
        guard !isRunning, let services = session.services else { return }
        let photos = PhotoRotation.photos(items)
        guard !photos.isEmpty else { return }
        let edits = PhotoRotation.edits(clockwise: clockwise)
        start(.rotate, total: photos.count) { progress in
            let run = await MediaSaveRunner.run(photos, progress: progress) { item in
                try await PhotoEditSaving.overwrite(item, with: edits, services: services)
            }
            if run.saved > 0 { await session.syncNow() }
            return run
        }
    }

    /// Downloads the originals of `items` and puts them on the pasteboard once all are there.
    func copy(_ items: [MediaItem], services: AccountServices) {
        guard !isRunning, !items.isEmpty else { return }
        guard items.count <= PhotoClipboard.limit else {
            result = PhotoTaskResult(
                kind: .copy, run: MediaSaveResult(total: items.count, failures: [PhotoClipboard.Failure.tooMany.localizedDescription]))
            return
        }
        start(.copy, total: items.count) { progress in
            guard let folder = try? PhotoClipboard.prepareDirectory() else {
                return MediaSaveResult(total: items.count, failures: [CocoaError(.fileWriteUnknown).localizedDescription])
            }
            let collected = CopiedFiles()
            var run = await MediaSaveRunner.run(items, progress: progress) { item in
                let url = try await PhotoClipboard.namedCopy(of: item, in: folder, services: services)
                await collected.add(item, url)
            }
            let files = await collected.files
            // A cancelled copy leaves the pasteboard as it was.
            if run.wasCancelled || files.isEmpty {
                run.saved = 0
                return run
            }
            PhotoClipboard.write(files)
            return run
        }
    }

    private func start(
        _ kind: PhotoTaskResult.Kind, total: Int,
        _ work: @escaping @MainActor (_ progress: @escaping @MainActor @Sendable (Int) -> Void) async -> MediaSaveResult
    ) {
        result = nil
        progress = Progress(kind: kind, done: 0, total: total)
        task = Task { [weak self] in
            let run = await work { [weak self] done in self?.progress = Progress(kind: kind, done: done, total: total) }
            self?.result = PhotoTaskResult(kind: kind, run: run)
            self?.task = nil
            self?.progress = nil
        }
    }

    func cancel() {
        task?.cancel()
    }

    func dismissResult() {
        result = nil
    }

    /// The files of a copy, in the order they were downloaded.
    private actor CopiedFiles {
        var files: [(item: MediaItem, url: URL)] = []

        func add(_ item: MediaItem, _ url: URL) {
            files.append((item, url))
        }
    }
}

extension View {
    /// Progress with Cancel while `model` rotates or copies, then "Rotated 3 photos" for a moment, or an alert with what
    /// failed.
    func photoTaskStatus(_ model: PhotoTaskModel) -> some View {
        modifier(PhotoTaskStatus(model: model))
    }
}

private struct PhotoTaskStatus: ViewModifier {
    let model: PhotoTaskModel

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let progress = model.progress {
                    banner { running(progress) }
                } else if let result = model.result, let confirmation = result.confirmation {
                    banner {
                        Label(confirmation, systemImage: result.run.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle")
                    }
                }
            }
            .animation(.default, value: model.progress != nil)
            .animation(.default, value: model.result)
            .task(id: model.result) {
                guard let result = model.result else { return }
                if let confirmation = result.confirmation { AccessibilityNotification.Announcement(confirmation).post() }
                guard result.run.failures.isEmpty else { return }
                try? await Task.sleep(for: .seconds(result.confirmation == nil ? 0 : 4))
                if !Task.isCancelled { model.dismissResult() }
            }
            .alert(
                model.result?.failureTitle ?? "",
                isPresented: Binding(get: { model.result?.failureMessage != nil }, set: { if !$0 { model.dismissResult() } })
            ) {
            } message: {
                Text(model.result?.failureMessage ?? "")
            }
    }

    func banner<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: .rect(cornerRadius: 12))
            .padding()
            .transition(.opacity)
    }

    func running(_ progress: PhotoTaskModel.Progress) -> some View {
        HStack(spacing: 12) {
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                .progressViewStyle(.circular)
                .controlSize(.small)
                .accessibilityHidden(true)
            Text(text(progress)).monospacedDigit()
            Button(String(localized: "Cancel", bundle: .module)) { model.cancel() }
        }
        .accessibilityElement(children: .contain)
    }

    func text(_ progress: PhotoTaskModel.Progress) -> String {
        let current = min(progress.done + 1, progress.total)
        switch progress.kind {
        case .rotate:
            return String(localized: "Rotating \(current) of \(progress.total)…", bundle: .module, comment: "Progress of Image › Rotate.")
        case .copy:
            return String(localized: "Copying \(current) of \(progress.total)…", bundle: .module, comment: "Progress of Edit › Copy.")
        }
    }
}

// MARK: - Recent albums ("Add to Album" submenu)

/// The albums the user added photos to last, per account, in the account's folder (removed with the account).
@MainActor
enum RecentAlbumsStore {
    static func file(_ account: AccountID) -> URL {
        AppPaths.accountDirectory(account).appending(path: "recent-albums.json")
    }

    static func used(_ account: AccountID) -> [String] {
        guard let data = try? Data(contentsOf: file(account)) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    static func note(_ album: Album, account: AccountID) {
        let list = RecentAlbums.noting(album.id, in: used(account))
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: file(account), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
