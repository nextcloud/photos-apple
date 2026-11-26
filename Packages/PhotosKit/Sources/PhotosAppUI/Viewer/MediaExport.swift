// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import CoreTransferable
import Photos
import PhotosCore
import PhotosMedia
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
    /// - Parameter originals: the files as they are, without their edits (SPEC §16.3: edited photos are exported
    ///   edited unless the original is asked for).
    static func save(
        _ items: [MediaItem], to destination: Destination, services: AccountServices, originals: Bool = false,
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
                try await addToPhotoLibrary(item, services: services, original: originals)
            }
        case .folder(let folder):
            result = await MediaSaveRunner.run(items, progress: progress) { item in
                try await copyOriginal(of: item, to: folder, services: services, original: originals)
            }
            result.folder = folder
        }
        return result
    }

    /// Adds the photo to the Photos library: edited when it has an edit (a still, also of a Live Photo), else the
    /// original. Live Photos keep both resources.
    static func addToPhotoLibrary(_ item: MediaItem, services: AccountServices, original: Bool = false) async throws {
        if !original, let edited = try await EditedExport.file(for: item, services: services) {
            defer { try? FileManager.default.removeItem(at: edited.deletingLastPathComponent()) }
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = edited.lastPathComponent
                request.addResource(with: .photo, fileURL: edited, options: options)
                request.creationDate = item.capturedAt
                if let latitude = item.latitude, let longitude = item.longitude {
                    request.location = CLLocation(latitude: latitude, longitude: longitude)
                }
            }
            return
        }
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

    /// Copies the original into `folder` under its own name (" 2", " 3"… when that is taken); an edited photo as
    /// `<name> (edited)` unless `original` is asked for.
    static func copyOriginal(of item: MediaItem, to folder: URL, services: AccountServices, original: Bool = false) async throws {
        if !original, let edited = try await EditedExport.file(for: item, services: services) {
            defer { try? FileManager.default.removeItem(at: edited.deletingLastPathComponent()) }
            try FileManager.default.copyItem(at: edited, to: MediaFileNaming.freeURL(for: edited.lastPathComponent, in: folder))
            return
        }
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

/// Edited photos as files (SPEC §16.3): the recipe rendered on the original at full resolution, for export and sharing.
enum EditedExport {
    /// The edited photo in a folder of its own (the caller removes the folder), or nil when the photo has no edit.
    static func file(for item: MediaItem, services: AccountServices) async throws -> URL? {
        guard item.kind == .image, let recipe = services.edits.recipe(for: item.fileId), recipe.changesStill else { return nil }
        let original = try await services.images.originals.original(
            fileId: item.fileId, etag: item.etag, url: services.originalURL(for: item))
        var still: CGImage?
        if recipe.live?.changesStill == true, item.isLivePhoto {
            let motion = try await LiveEffectFiles.motion(of: item, services: services)
            still = try await EditorView.fullStill(recipe, motion: motion)
        }
        try Task.checkCancellation()
        let folder = FileManager.default.temporaryDirectory.appending(path: "Export/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try EditRendering.renderFile(recipe, original: original, name: item.name, still: still, to: folder)
    }

    /// A Loop or Bounce as a video or an animated GIF (SPEC §16.3.3), in a folder of its own.
    static func effect(of item: MediaItem, gif: Bool, services: AccountServices) async throws -> URL {
        let recipe = services.edits.recipe(for: item.fileId)
        let effect = recipe?.live?.effect ?? .loop
        let motion = try await LiveEffectFiles.motion(of: item, services: services)
        let folder = FileManager.default.temporaryDirectory.appending(path: "Export/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = (item.name as NSString).deletingPathExtension + " (\(LiveEffectWording.title(effect)))"
        let target = folder.appending(path: base + (gif ? ".gif" : ".mp4"))
        if gif {
            try await LivePhotoEffects.writeGIF(of: motion, effect: effect, edits: recipe, to: target)
        } else {
            // Three rounds: a shared Loop or Bounce plays a while even where videos do not repeat.
            try await LivePhotoEffects.writeVideo(of: motion, effect: effect, edits: recipe, maxPixelSize: 1920, repeats: 3, to: target)
        }
        return target
    }
}

/// A Live Photo's Loop or Bounce, made when shared.
struct ShareableLiveEffect: Transferable {
    let item: MediaItem
    let gif: Bool
    let services: AccountServices

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .item) { media in
            SentTransferredFile(try await EditedExport.effect(of: media.item, gif: media.gif, services: media.services))
        }
    }
}

/// A photo that is downloaded when shared: edited when it has an edit (SPEC §16.3), unless `original`.
struct ShareableMedia: Transferable {
    let item: MediaItem
    let services: AccountServices
    var original = false

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .item) { media in
            if !media.original, let edited = try await EditedExport.file(for: media.item, services: media.services) {
                return SentTransferredFile(edited)
            }
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
    /// The side of the square that takes the taps, for an icon in a plain bar (SPEC §20.3); nil: the label's own size.
    var target: CGFloat? = nil
    @Environment(SessionModel.self) private var session

    var body: some View {
        if let services = session.services, !items.isEmpty {
            ShareLink(items: items.map { ShareableMedia(item: $0, services: services) }) { _ in
                SharePreview(items.count == 1 ? items[0].name : String(localized: "\(items.count) items", bundle: .module))
            } label: {
                Label(String(localized: "Share", bundle: .module), systemImage: "square.and.arrow.up")
                    .frame(width: target, height: target)
                    .contentShape(.rect)
            }
        }
    }
}
