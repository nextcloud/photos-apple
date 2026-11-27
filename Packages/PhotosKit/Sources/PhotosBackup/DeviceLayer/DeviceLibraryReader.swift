// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Photos
import PhotosModel
import UniformTypeIdentifiers

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// Reads the device's photos for the Library's device layer (SPEC §21.1). Never on the main thread: at 100 000 photos
/// the fetch takes a moment.
public enum DeviceLibraryReader {
    /// The photos and videos backup covers (its options: kinds, from date, albums, hidden), as PhotoKit describes them.
    /// Nothing is read from their files.
    public static func read(_ settings: BackupSettings) -> [DeviceLibraryItem] {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard settings.photos || settings.videos else { return [] }
        var items: [DeviceLibraryItem] = []
        if settings.albumIdentifiers.isEmpty {
            let result = PHAsset.fetchAssets(with: PhotoLibrarySource.fetchOptions(settings, newestFirst: true))
            items.reserveCapacity(result.count)
            result.enumerateObjects { asset, _, _ in items.append(item(asset)) }
        } else {
            items = PhotoLibrarySource().assets(settings).map(item)
        }
        return items
    }

    static func item(_ asset: PHAsset) -> DeviceLibraryItem {
        DeviceLibraryItem(
            localIdentifier: asset.localIdentifier, createdAt: asset.creationDate ?? asset.modificationDate ?? .distantPast,
            isVideo: asset.mediaType == .video, isFavorite: asset.isFavorite, isLivePhoto: asset.mediaSubtypes.contains(.photoLive),
            pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight, duration: asset.duration,
            // The fetch lists a burst's chosen frames and its representative, not every frame.
            burstIdentifier: asset.burstIdentifier)
    }
}

/// Pictures of device photos for the image pipeline (`ImagePipeline.setDevicePictureProvider`): PhotoKit's own
/// thumbnails and previews, from the device only (nothing is downloaded from iCloud for a tile).
public enum DevicePictures {
    public static func image(id: FileID, maxPixelSize: Int, directory: DeviceAssetDirectory = .shared) async -> CGImage? {
        guard let localIdentifier = directory.localIdentifier(of: id),
            let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
        else { return nil }
        return await image(asset, maxPixelSize: maxPixelSize)
    }

    static func image(_ asset: PHAsset, maxPixelSize: Int) async -> CGImage? {
        let options = PHImageRequestOptions()
        // One answer: the best picture of this size that is on the device.
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = maxPixelSize > 1024
        options.isSynchronous = false
        let side = CGFloat(max(maxPixelSize, 64))
        return await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
            PHImageManager.default().requestImage(
                for: asset, targetSize: CGSize(width: side, height: side), contentMode: .aspectFit, options: options
            ) { image, _ in
                #if os(macOS)
                    continuation.resume(returning: image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
                #else
                    continuation.resume(returning: image?.cgImage)
                #endif
            }
        }
    }
}

/// Sharing, deleting and the viewer's video of device photos (SPEC §21.1).
public enum DeviceAssetActions {
    /// The assets of these local identifiers that are still on the device.
    static func assets(_ localIdentifiers: [String]) -> [PHAsset] {
        guard !localIdentifiers.isEmpty else { return [] }
        var assets: [PHAsset] = []
        PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil).enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    /// Removes the photos from the device's library. The system asks the user to confirm; they go to Recently Deleted.
    /// Returns how many were removed (0 when the user declined).
    public static func delete(_ localIdentifiers: [String]) async throws -> Int {
        let count = assets(localIdentifiers).count
        guard count > 0 else { return 0 }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil))
            }
        } catch let error as PHPhotosError where error.code == .userCancelled {
            return 0
        }
        return count
    }

    /// Item providers for the system's share sheet or menu: each photo or video as its file (the current version, edits
    /// included), read from PhotoKit only when the receiver asks for it. Downloads the original from iCloud if needed.
    public static func itemProviders(_ localIdentifiers: [String]) -> [NSItemProvider] {
        assets(localIdentifiers).compactMap { asset in
            guard let resource = shared(asset) else { return nil }
            let name = PhotoLibrarySource.fileName(of: resource)
            let type = resource.contentType
            let localIdentifier = asset.localIdentifier
            let provider = NSItemProvider()
            #if !os(tvOS)
                provider.suggestedName = (name as NSString).deletingPathExtension
            #endif
            provider.registerFileRepresentation(for: type, visibility: .all) { completion in
                let progress = Progress(totalUnitCount: 1)
                // Read again here: PhotoKit's objects stay where they were made.
                guard let asset = assets([localIdentifier]).first, let resource = shared(asset) else {
                    completion(nil, false, CocoaError(.fileNoSuchFile))
                    return progress
                }
                let url = FileManager.default.temporaryDirectory.appending(path: "DeviceShare-\(UUID().uuidString)").appending(path: name)
                do {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                } catch {
                    completion(nil, false, error)
                    return progress
                }
                let options = PHAssetResourceRequestOptions()
                options.isNetworkAccessAllowed = true
                // The item provider's completion handler may be called from any thread, once; it is not marked Sendable.
                nonisolated(unsafe) let completion = completion
                PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                    progress.completedUnitCount = 1
                    completion(error == nil ? url : nil, false, error)
                }
                return progress
            }
            return provider
        }
    }

    /// The resource that is shared of an asset: its current version, edits included.
    static func shared(_ asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        let wanted: [PHAssetResourceType] = asset.mediaType == .video ? [.fullSizeVideo, .video] : [.fullSizePhoto, .photo]
        return wanted.lazy.compactMap { type in resources.first { $0.type == type } }.first
    }

    /// A device video to play: its file where PhotoKit has one, else a copy in the temporary directory (from iCloud when
    /// it is not on the device).
    public static func videoURL(localIdentifier: String) async -> URL? {
        guard let asset = assets([localIdentifier]).first, asset.mediaType == .video else { return nil }
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .automatic
        let direct: URL? = await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                continuation.resume(returning: (avAsset as? AVURLAsset)?.url)
            }
        }
        if let direct { return direct }
        guard let resource = shared(asset) else { return nil }
        let url = FileManager.default.temporaryDirectory.appending(path: "DeviceVideo-\(UUID().uuidString)")
            .appending(path: PhotoLibrarySource.fileName(of: resource))
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            try await PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options)
            return url
        } catch {
            return nil
        }
    }
}
