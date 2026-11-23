// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreLocation
import Foundation
import ImageIO
import Photos
import PhotosModel
import UniformTypeIdentifiers

/// Which resource of an asset is uploaded (SPEC §7.18.3 `resourceKind`).
public enum BackupResourceKind: String, Codable, Sendable, CaseIterable {
    case photo, edited, raw, video, editedVideo, pairedVideo
}

/// One resource to back up.
public struct BackupResource: Sendable, Hashable, Codable {
    public var localIdentifier: String
    public var kind: BackupResourceKind
    public var mediaKind: MediaKind
    public var originalName: String
    public var createdAt: Date
    public var modifiedAt: Date?
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var latitude: Double?
    public var longitude: Double?
    /// Size of the resource's data, when PhotoKit knows it.
    public var byteSize: Int64?

    var rendition: LocalResource.Rendition {
        switch kind {
        case .edited, .editedVideo: .edited
        case .raw: .raw
        case .photo, .video, .pairedVideo: .original
        }
    }

    var isEdit: Bool { rendition == .edited }

    /// What is remembered about the uploaded data, to tell a new edit from a metadata-only change of the asset.
    var sizeFingerprint: String? { byteSize.map { "size:\($0)" } }

    var local: LocalResource {
        LocalResource(
            localIdentifier: localIdentifier, kind: mediaKind, createdAt: createdAt, originalName: originalName, byteSize: byteSize,
            pixelWidth: pixelWidth > 0 ? pixelWidth : nil, pixelHeight: pixelHeight > 0 ? pixelHeight : nil, rendition: rendition)
    }
}

/// Reads the device photo library (SPEC §7.18).
public struct PhotoLibrarySource: Sendable, BackupLibrary {
    public init() {}

    var isAuthorized: Bool { Self.authorization == .authorized || Self.authorization == .limited }

    public static var authorization: PHAuthorizationStatus { PHPhotoLibrary.authorizationStatus(for: .readWrite) }

    public static func requestAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    /// Assets selected by the settings, oldest first.
    public func assets(_ settings: BackupSettings) -> [PHAsset] {
        let options = PHFetchOptions()
        var predicates: [NSPredicate] = []
        var types: [Int] = []
        if settings.photos { types.append(PHAssetMediaType.image.rawValue) }
        if settings.videos { types.append(PHAssetMediaType.video.rawValue) }
        predicates.append(NSPredicate(format: "mediaType IN %@", types))
        if let since = settings.since { predicates.append(NSPredicate(format: "creationDate >= %@", since as NSDate)) }
        options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared]
        var result: [PHAsset] = []
        var seen = Set<String>()
        if settings.albumIdentifiers.isEmpty {
            PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in result.append(asset) }
        } else {
            let collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: settings.albumIdentifiers, options: nil)
            collections.enumerateObjects { collection, _, _ in
                PHAsset.fetchAssets(in: collection, options: options).enumerateObjects { asset, _, _ in
                    if seen.insert(asset.localIdentifier).inserted { result.append(asset) }
                }
            }
            result.sort { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
        }
        return result
    }

    /// Resources of the selected assets, oldest first; `needsScan` saves reading the resources of assets that are done.
    func scan(_ settings: BackupSettings, needsScan: (String, Date?) -> Bool) -> [BackupResource] {
        var result: [BackupResource] = []
        for asset in assets(settings) where needsScan(asset.localIdentifier, asset.modificationDate) {
            result.append(contentsOf: resources(of: asset, settings: settings).map(\.0))
        }
        return result
    }

    /// Resources of an asset to upload, according to the settings.
    public func resources(of asset: PHAsset, settings: BackupSettings) -> [(BackupResource, PHAssetResource)] {
        let all = PHAssetResource.assetResources(for: asset)
        func find(_ types: [PHAssetResourceType]) -> PHAssetResource? {
            for type in types { if let resource = all.first(where: { $0.type == type }) { return resource } }
            return nil
        }
        let created = asset.creationDate ?? Date()
        let originalName = find([.photo, .video])?.originalFilename ?? "\(asset.localIdentifier.prefix(8)).bin"
        func make(_ kind: BackupResourceKind, _ resource: PHAssetResource, name: String) -> (BackupResource, PHAssetResource) {
            (
                BackupResource(
                    localIdentifier: asset.localIdentifier, kind: kind,
                    mediaKind: [.video, .editedVideo, .pairedVideo].contains(kind) ? .video : .image, originalName: name,
                    createdAt: created,
                    modifiedAt: asset.modificationDate, pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight,
                    latitude: asset.location?.coordinate.latitude, longitude: asset.location?.coordinate.longitude,
                    byteSize: Self.byteSize(of: resource)),
                resource
            )
        }
        var result: [(BackupResource, PHAssetResource)] = []
        let edited = asset.mediaType == .video ? find([.fullSizeVideo]) : find([.fullSizePhoto])
        let wantOriginal = settings.edits != .editedOnly || edited == nil
        let wantEdited = settings.edits != .originalOnly && edited != nil
        switch asset.mediaType {
        case .video:
            if wantOriginal, let video = find([.video]) { result.append(make(.video, video, name: video.originalFilename)) }
            if wantEdited, let edited {
                result.append(make(.editedVideo, edited, name: Self.editedName(originalName, ext: edited.originalFilename)))
            }
        default:
            if wantOriginal, let photo = find([.photo]) { result.append(make(.photo, photo, name: photo.originalFilename)) }
            if wantEdited, let edited {
                result.append(make(.edited, edited, name: Self.editedName(originalName, ext: edited.originalFilename)))
            }
            if let raw = find([.alternatePhoto]), UTType(raw.uniformTypeIdentifier)?.conforms(to: .rawImage) == true {
                result.append(make(.raw, raw, name: raw.originalFilename))
            }
            if settings.livePhotos, asset.mediaSubtypes.contains(.photoLive) {
                let paired = settings.edits == .editedOnly ? find([.fullSizePairedVideo, .pairedVideo]) : find([.pairedVideo])
                if let paired {
                    result.append(make(.pairedVideo, paired, name: (originalName as NSString).deletingPathExtension + ".MOV"))
                }
            }
        }
        return result
    }

    /// Apple names edited renditions `IMG_E1234`; the web app stacks them with `IMG_1234`.
    static func editedName(_ original: String, ext editedFile: String) -> String {
        let base = (original as NSString).deletingPathExtension
        let ext =
            (editedFile as NSString).pathExtension.isEmpty ? (original as NSString).pathExtension : (editedFile as NSString).pathExtension
        if let match = base.wholeMatch(of: /([A-Z]{3})_(\d+)/) { return "\(match.1)_E\(match.2).\(ext)" }
        return "\(base)\(BackupNaming.editedSuffix).\(ext)"
    }

    /// The size of a resource's data (`PHAssetResource.dataSize`, public since the 27 SDKs, so no key-value coding of the
    /// private `fileSize`). PhotoKit may not know it; "unknown" lets the matcher fall back to names and dimensions.
    static func byteSize(of resource: PHAssetResource) -> Int64? {
        validSize(resource.dataSize)
    }

    /// Only a positive number is a size.
    static func validSize(_ size: Int?) -> Int64? {
        guard let size, size > 0 else { return nil }
        return Int64(size)
    }

    /// Writes a backup resource to a temporary file, resolving its PhotoKit resource again (those aren't Sendable).
    public func export(_ backup: BackupResource, settings: BackupSettings) async throws -> URL {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [backup.localIdentifier], options: nil).firstObject,
            let resource = resources(of: asset, settings: settings).first(where: { $0.0.kind == backup.kind })?.1
        else { throw CocoaError(.fileNoSuchFile) }
        return try await export(resource, allowNetwork: settings.downloadFromICloud)
    }

    /// Writes a resource to a temporary file (downloads from iCloud when allowed).
    public func export(_ resource: PHAssetResource, allowNetwork: Bool) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "Backup/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: resource.originalFilename)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = allowNetwork
        try await PHAssetResourceManager.default().writeData(for: resource, toFile: file, options: options)
        return file
    }

    /// Converts HEIC/HEIF photos to JPEG, keeping metadata ("Most compatible" format).
    public static func convertToJPEG(_ file: URL) throws -> URL {
        guard let type = UTType(filenameExtension: file.pathExtension), type.conforms(to: .heic) || type.conforms(to: .heif),
            let source = CGImageSourceCreateWithURL(file as CFURL, nil)
        else { return file }
        let target = file.deletingPathExtension().appendingPathExtension("jpg")
        guard let destination = CGImageDestinationCreateWithURL(target as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            return file
        }
        CGImageDestinationAddImageFromSource(destination, source, 0, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return file }
        try? FileManager.default.removeItem(at: file)
        return target
    }
}
