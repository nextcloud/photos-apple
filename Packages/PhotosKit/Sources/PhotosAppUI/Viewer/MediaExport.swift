// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreTransferable
import Photos
import PhotosCore
import PhotosModel
import SwiftUI
import UniformTypeIdentifiers

/// Saving originals to the device library or a folder, and sharing them (SPEC §7.3, §7.24). The app saves through
/// `MediaSaveModel`, which adds progress, Cancel and the result.
enum MediaExport {
    enum Destination: Sendable {
        /// The device's photo library (add-only permission).
        case photoLibrary
        /// A folder the user picked (Mac).
        case folder(URL)
    }

    /// Downloads the originals and saves them, one after the other; `progress` is told how many are done.
    static func save(
        _ items: [MediaItem], to destination: Destination, services: AccountServices,
        progress: @MainActor @Sendable (Int) -> Void = { _ in }
    ) async -> MediaSaveResult {
        var result: MediaSaveResult
        switch destination {
        case .photoLibrary:
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                return MediaSaveResult(total: items.count, failures: [ExportError.notAllowed.localizedDescription])
            }
            result = await MediaSaveRunner.run(items, progress: progress) { item in
                try await addToPhotoLibrary(item, services: services)
            }
        case .folder(let folder):
            result = await MediaSaveRunner.run(items, progress: progress) { item in
                try await copyOriginal(of: item, to: folder, services: services)
            }
            result.folder = folder
        }
        return result
    }

    /// Adds the original to the Photos library. Live Photos keep both resources.
    static func addToPhotoLibrary(_ item: MediaItem, services: AccountServices) async throws {
        let file = try await services.images.originals.original(
            fileId: item.fileId, etag: item.etag, url: services.originalURL(for: item))
        var videoFile: URL?
        if let peer = item.livePhotoPeer, let video = try? services.library.item(peer) {
            videoFile = try? await services.images.originals.original(
                fileId: video.fileId, etag: video.etag, url: services.originalURL(for: video))
        }
        try Task.checkCancellation()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = item.name
            request.addResource(with: item.kind == .video ? .video : .photo, fileURL: file, options: options)
            if let videoFile {
                request.addResource(with: .pairedVideo, fileURL: videoFile, options: nil)
            }
            request.creationDate = item.capturedAt
            if let latitude = item.latitude, let longitude = item.longitude {
                request.location = CLLocation(latitude: latitude, longitude: longitude)
            }
        }
    }

    /// Copies the original into `folder` under its own name (" 2", " 3"… when that is taken).
    static func copyOriginal(of item: MediaItem, to folder: URL, services: AccountServices) async throws {
        let file = try await services.images.originals.original(
            fileId: item.fileId, etag: item.etag, url: services.originalURL(for: item))
        try Task.checkCancellation()
        try FileManager.default.copyItem(at: file, to: MediaFileNaming.freeURL(for: item.name, in: folder))
    }

    enum ExportError: LocalizedError {
        case notAllowed

        var errorDescription: String? {
            String(
                localized: "Nextcloud Photos is not allowed to add photos to your library. You can change this in Settings.",
                bundle: .module)
        }
    }
}

/// An original file that is downloaded when shared.
struct ShareableMedia: Transferable {
    let item: MediaItem
    let services: AccountServices

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .item) { media in
            let file = try await media.services.images.originals.original(
                fileId: media.item.fileId, etag: media.item.etag, url: media.services.originalURL(for: media.item))
            // Give the file its real name for the receiving app.
            let named = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: media.item.name)
            try FileManager.default.createDirectory(at: named.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: file, to: named)
            return SentTransferredFile(named)
        }
    }
}

/// Share button for originals.
struct ShareMediaButton: View {
    let items: [MediaItem]
    @Environment(SessionModel.self) private var session

    var body: some View {
        if let services = session.services, !items.isEmpty {
            ShareLink(items: items.map { ShareableMedia(item: $0, services: services) }) { _ in
                SharePreview(items.count == 1 ? items[0].name : String(localized: "\(items.count) items", bundle: .module))
            } label: {
                Label(String(localized: "Share", bundle: .module), systemImage: "square.and.arrow.up")
            }
        }
    }
}
