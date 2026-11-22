// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreTransferable
import Photos
import PhotosCore
import PhotosModel
import SwiftUI
import UniformTypeIdentifiers

/// Export to the device library and sharing of originals (SPEC §7.3, §7.24).
enum MediaExport {
    /// Downloads originals and adds them to the Photos library (add-only permission). Live Photos keep both resources.
    static func saveToPhotoLibrary(_ items: [MediaItem], services: AccountServices) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw ExportError.notAllowed
        }
        for item in items {
            let file = try await services.images.originals.original(
                fileId: item.fileId, etag: item.etag, url: services.originalURL(for: item))
            var videoFile: URL?
            if let peer = item.livePhotoPeer, let video = try? services.library.item(peer) {
                videoFile = try? await services.images.originals.original(
                    fileId: video.fileId, etag: video.etag, url: services.originalURL(for: video))
            }
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
