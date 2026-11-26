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

/// What PhotoKit says about an asset, as far as the choice of its resources needs it. A value, so that the choice can be
/// tested without a photo library.
struct BackupAssetInfo: Sendable {
    var localIdentifier: String
    var isVideo = false
    var isLivePhoto = false
    var createdAt: Date
    var modifiedAt: Date?
    var pixelWidth = 0
    var pixelHeight = 0
    var latitude: Double?
    var longitude: Double?

    /// One `PHAssetResource`.
    struct Resource: Sendable {
        var type: PHAssetResourceType
        var name: String
        var uniformTypeIdentifier = ""
        var byteSize: Int64?
    }
}

/// Reads the device photo library (SPEC §7.18).
public struct PhotoLibrarySource: Sendable, BackupLibrary {
    public init() {}

    var isAuthorized: Bool { Self.authorization == .authorized || Self.authorization == .limited }

    /// The user gave access to selected photos only: everything else is invisible to the backup.
    var isLimited: Bool { Self.authorization == .limited }

    public static var authorization: PHAuthorizationStatus { PHPhotoLibrary.authorizationStatus(for: .readWrite) }

    public static func requestAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    /// Where exported resources are written, each in a directory of its own. The engine removes what is left there
    /// (`BackupEngine.sweepExports`).
    public static var exportDirectory: URL { FileManager.default.temporaryDirectory.appending(path: "Backup") }

    /// Assets selected by the settings, oldest first.
    ///
    /// Only the user's own library: photos of iCloud Shared Albums belong to somebody else's library (and are reduced
    /// copies), and what was synced from a computer is on that computer. Hidden photos only when the user asks for them.
    ///
    /// - Parameter only: only these assets (those that changed); nil: all of them.
    public func assets(_ settings: BackupSettings, only identifiers: Set<String>? = nil) -> [PHAsset] {
        let options = PHFetchOptions()
        var predicates: [NSPredicate] = []
        if let identifiers {
            guard !identifiers.isEmpty else { return [] }
            predicates.append(NSPredicate(format: "localIdentifier IN %@", Array(identifiers)))
        }
        var types: [Int] = []
        if settings.photos { types.append(PHAssetMediaType.image.rawValue) }
        if settings.videos { types.append(PHAssetMediaType.video.rawValue) }
        predicates.append(NSPredicate(format: "mediaType IN %@", types))
        if let since = settings.since { predicates.append(NSPredicate(format: "creationDate >= %@", since as NSDate)) }
        options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.includeAssetSourceTypes = [.typeUserLibrary]
        options.includeHiddenAssets = settings.includeHidden
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
    func scan(_ settings: BackupSettings, assets identifiers: Set<String>?, needsScan: (String, Date?) -> Bool) -> [BackupResource] {
        var result: [BackupResource] = []
        for asset in assets(settings, only: identifiers) where needsScan(asset.localIdentifier, asset.modificationDate) {
            result.append(contentsOf: resources(of: asset, settings: settings).map(\.0))
        }
        return result
    }

    // MARK: Changes (SPEC §7.18.3)

    /// More changed assets than this are looked at like the whole library: one fetch of everything is cheaper than a
    /// predicate with that many identifiers.
    static let maxChangedAssets = 10_000

    var changeToken: Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: PHPhotoLibrary.shared().currentChangeToken, requiringSecureCoding: true)
    }

    /// Assets inserted, updated or deleted since the token, from the library's persistent change history. Nil when the
    /// token is unreadable or older than the history, when the history has no details, when there are very many, and
    /// when one of the albums the backup is limited to changed (an asset added to an album is a change of the album).
    func changedAssets(since data: Data, settings: BackupSettings) -> Set<String>? {
        guard let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: data) else { return nil }
        let albums = Set(settings.albumIdentifiers)
        var assets = Set<String>()
        do {
            let changes = try PHPhotoLibrary.shared().fetchPersistentChanges(since: token)
            for change in changes {
                let details = try change.changeDetails(for: .asset)
                assets.formUnion(details.insertedLocalIdentifiers)
                assets.formUnion(details.updatedLocalIdentifiers)
                assets.formUnion(details.deletedLocalIdentifiers)
                if !albums.isEmpty {
                    let collections = try change.changeDetails(for: .assetCollection)
                    let touched = collections.insertedLocalIdentifiers.union(collections.updatedLocalIdentifiers)
                        .union(collections.deletedLocalIdentifiers)
                    if !touched.isDisjoint(with: albums) { return nil }
                }
                if assets.count > Self.maxChangedAssets { return nil }
            }
        } catch {
            // `persistentChangeTokenExpired`, `persistentChangeDetailsUnavailable`, or another failure: everything is looked at.
            return nil
        }
        return assets
    }

    /// Resources of an asset to upload, according to the settings.
    public func resources(of asset: PHAsset, settings: BackupSettings) -> [(BackupResource, PHAssetResource)] {
        let all = PHAssetResource.assetResources(for: asset)
        let info = BackupAssetInfo(
            localIdentifier: asset.localIdentifier, isVideo: asset.mediaType == .video,
            isLivePhoto: asset.mediaSubtypes.contains(.photoLive), createdAt: asset.creationDate ?? Date(),
            modifiedAt: asset.modificationDate, pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight,
            latitude: asset.location?.coordinate.latitude, longitude: asset.location?.coordinate.longitude)
        let resources = all.map { resource in
            BackupAssetInfo.Resource(
                type: resource.type, name: Self.fileName(of: resource), uniformTypeIdentifier: resource.uniformTypeIdentifier,
                byteSize: Self.byteSize(of: resource))
        }
        return Self.select(info, resources: resources, settings: settings).map { ($0.resource, all[$0.index]) }
    }

    /// Which resources of an asset are uploaded, and as what (SPEC §7.18.2 "Edited photos", "Live Photos"). `index`
    /// points into `resources`.
    ///
    /// - original and edited version according to `settings.edits`; without an edit the original is always taken;
    /// - the RAW file next to a JPEG/HEIC always;
    /// - the motion part of a Live Photo with `settings.livePhotos`: the edited one only with "Edited only".
    static func select(_ asset: BackupAssetInfo, resources all: [BackupAssetInfo.Resource], settings: BackupSettings)
        -> [(resource: BackupResource, index: Int)]
    {
        func find(_ types: [PHAssetResourceType]) -> Int? {
            for type in types { if let index = all.firstIndex(where: { $0.type == type }) { return index } }
            return nil
        }
        let originalName = find([.photo, .video]).map { all[$0].name } ?? "\(asset.localIdentifier.prefix(8)).bin"
        func make(_ kind: BackupResourceKind, _ index: Int, name: String) -> (resource: BackupResource, index: Int) {
            (
                BackupResource(
                    localIdentifier: asset.localIdentifier, kind: kind,
                    mediaKind: [.video, .editedVideo, .pairedVideo].contains(kind) ? .video : .image, originalName: name,
                    createdAt: asset.createdAt,
                    modifiedAt: asset.modifiedAt, pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight,
                    latitude: asset.latitude, longitude: asset.longitude,
                    byteSize: all[index].byteSize),
                index
            )
        }
        var result: [(resource: BackupResource, index: Int)] = []
        let edited = asset.isVideo ? find([.fullSizeVideo]) : find([.fullSizePhoto])
        let wantOriginal = settings.edits != .editedOnly || edited == nil
        let wantEdited = settings.edits != .originalOnly && edited != nil
        if asset.isVideo {
            if wantOriginal, let video = find([.video]) { result.append(make(.video, video, name: all[video].name)) }
            if wantEdited, let edited {
                result.append(make(.editedVideo, edited, name: Self.editedName(originalName, ext: all[edited].name)))
            }
        } else {
            if wantOriginal, let photo = find([.photo]) { result.append(make(.photo, photo, name: all[photo].name)) }
            if wantEdited, let edited {
                result.append(make(.edited, edited, name: Self.editedName(originalName, ext: all[edited].name)))
            }
            if let raw = find([.alternatePhoto]), UTType(all[raw].uniformTypeIdentifier)?.conforms(to: .rawImage) == true {
                result.append(make(.raw, raw, name: all[raw].name))
            }
            if settings.livePhotos, asset.isLivePhoto {
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

    /// The resource's file name (`PHAssetResource.filename`, which replaced `originalFilename` in the 27 SDKs and may be
    /// nil): without one, a name made of the asset's identifier and the type's extension, so that every file has a name.
    static func fileName(of resource: PHAssetResource) -> String {
        fileName(resource.filename, assetIdentifier: resource.assetLocalIdentifier, type: resource.contentType)
    }

    static func fileName(_ name: String?, assetIdentifier: String, type: UTType) -> String {
        if let name, !name.isEmpty { return name }
        // "4E5F…/L0/001": the part before the first slash is unique per asset and safe in a file name.
        let base = assetIdentifier.split(separator: "/").first.map(String.init) ?? "Asset"
        guard let ext = type.preferredFilenameExtension else { return base }
        return base + "." + ext
    }

    /// Only a positive number is a size.
    static func validSize(_ size: Int?) -> Int64? {
        guard let size, size > 0 else { return nil }
        return Int64(size)
    }

    /// Writes a backup resource to a temporary file, resolving its PhotoKit resource again (those aren't Sendable).
    ///
    /// - Parameter allowNetwork: download the data from iCloud when it is not on this device. Without it such a resource
    ///   throws `BackupDeviceError.needsICloudDownload`.
    func export(_ backup: BackupResource, settings: BackupSettings, allowNetwork: Bool) async throws -> URL {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [backup.localIdentifier], options: nil).firstObject,
            let resource = resources(of: asset, settings: settings).first(where: { $0.0.kind == backup.kind })?.1
        else { throw CocoaError(.fileNoSuchFile) }
        return try await export(resource, allowNetwork: allowNetwork)
    }

    /// Writes a resource to a temporary file (downloads from iCloud when allowed). Nothing is left behind when it fails.
    public func export(_ resource: PHAssetResource, allowNetwork: Bool) async throws -> URL {
        let directory = Self.exportDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: Self.fileName(of: resource))
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = allowNetwork
        do {
            try await PHAssetResourceManager.default().writeData(for: resource, toFile: file, options: options)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw Self.deviceError(for: error, allowNetwork: allowNetwork)
        }
        return file
    }

    /// PhotoKit's "the data is in iCloud and the network was not allowed" as the error the engine knows.
    static func deviceError(for error: any Error, allowNetwork: Bool) -> any Error {
        if !allowNetwork, let error = error as? PHPhotosError, error.code == .networkAccessRequired {
            return BackupDeviceError.needsICloudDownload
        }
        return error
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
